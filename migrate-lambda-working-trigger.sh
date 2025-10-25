#!/bin/bash
set -e

echo "=== Lambda Replication with Full API Gateway Automation ==="

# === USER INPUT ===
read -p "Enter the full ARN of the source Lambda function: " LAMBDA_ARN
read -p "Enter the cross-account role name in the source account (default: CrossAccountAccessRole): " ROLE_NAME
ROLE_NAME=${ROLE_NAME:-CrossAccountAccessRole}

SRC_ACCOUNT=$(echo "$LAMBDA_ARN" | awk -F: '{print $5}')
SRC_REGION=$(echo "$LAMBDA_ARN" | awk -F: '{print $4}')
LAMBDA_NAME=$(echo "$LAMBDA_ARN" | awk -F: '{print $7}')

DEST_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
DEST_USER=$(aws sts get-caller-identity --query 'Arn' --output text)

echo "Source Account : $SRC_ACCOUNT"
echo "Source Region  : $SRC_REGION"
echo "Lambda Name    : $LAMBDA_NAME"
echo "Destination Account: $DEST_ACCOUNT_ID ($DEST_USER)"

read -p "Proceed to replicate Lambda? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Operation cancelled."
    exit 0
fi

# === STEP 1: Assume role in source account ===
echo "Assuming role $ROLE_NAME in source account..."
ASSUME_OUTPUT=$(aws sts assume-role \
    --role-arn arn:aws:iam::$SRC_ACCOUNT:role/$ROLE_NAME \
    --role-session-name LambdaReplicationSession)

export AWS_ACCESS_KEY_ID=$(echo "$ASSUME_OUTPUT" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$ASSUME_OUTPUT" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "$ASSUME_OUTPUT" | jq -r '.Credentials.SessionToken')

# === STEP 2: Fetch Lambda configuration and code ===
CONFIG=$(aws lambda get-function-configuration --function-name "$LAMBDA_NAME" --region "$SRC_REGION")
SRC_ROLE_ARN=$(echo "$CONFIG" | jq -r '.Role')
SRC_ROLE_NAME=$(basename "$SRC_ROLE_ARN")
ENV_VARS=$(echo "$CONFIG" | jq -r '.Environment | if .Variables then .Variables else {} end')
LAYERS=$(echo "$CONFIG" | jq -r '.Layers | if . != null then map(.Arn) else [] end')

CODE_URL=$(aws lambda get-function --function-name "$LAMBDA_NAME" --region "$SRC_REGION" --query 'Code.Location' --output text)
curl -s -o function.zip "$CODE_URL"

# Prompt for VPC configuration
read -p "Enter destination subnet IDs (comma separated, leave empty to skip VPC): " DEST_SUBNETS
read -p "Enter destination security group IDs (comma separated, leave empty to skip VPC): " DEST_SGS
VPC_ARGS=""
if [ -n "$DEST_SUBNETS" ] && [ -n "$DEST_SGS" ]; then
    VPC_ARGS="--vpc-config SubnetIds=[$DEST_SUBNETS],SecurityGroupIds=[$DEST_SGS]"
fi

# Reset to destination account
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# === STEP 3: Create/reuse IAM role ===
ROLE_EXISTS=$(aws iam get-role --role-name "$SRC_ROLE_NAME" --query 'Role.RoleName' --output text 2>/dev/null || true)
if [ -z "$ROLE_EXISTS" ]; then
    echo "IAM role '$SRC_ROLE_NAME' not found. Creating role..."
    TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    aws iam create-role --role-name "$SRC_ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY"
    sleep 10
else
    echo "Reusing existing role: $SRC_ROLE_NAME"
fi
DEST_ROLE_ARN=$(aws iam get-role --role-name "$SRC_ROLE_NAME" --query 'Role.Arn' --output text)

# Attach managed policies
aws iam attach-role-policy --role-name "$SRC_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null
if [ -n "$DEST_SUBNETS" ] && [ -n "$DEST_SGS" ]; then
    aws iam attach-role-policy --role-name "$SRC_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole >/dev/null
fi
echo "⏳ Waiting 15 seconds for IAM policy propagation..."
sleep 15

# === STEP 4: Create/update Lambda ===
ENV_JSON=$(echo "$ENV_VARS" | jq -c '{Variables:.}')
LAYER_ARNS=$(echo "$LAYERS" | jq -r '. | join(" ")')

EXISTS=$(aws lambda get-function --function-name "$LAMBDA_NAME" --region "$SRC_REGION" --query 'Configuration.FunctionName' --output text 2>/dev/null || true)
if [ -n "$EXISTS" ]; then
    echo "Updating existing Lambda..."
    aws lambda update-function-code --function-name "$LAMBDA_NAME" --zip-file fileb://function.zip --region "$SRC_REGION"
    aws lambda update-function-configuration --function-name "$LAMBDA_NAME" \
        --role "$DEST_ROLE_ARN" \
        --runtime $(echo $CONFIG | jq -r '.Runtime') \
        --handler $(echo $CONFIG | jq -r '.Handler') \
        --description "$(echo $CONFIG | jq -r '.Description')" \
        --timeout $(echo $CONFIG | jq -r '.Timeout') \
        --memory-size $(echo $CONFIG | jq -r '.MemorySize') \
        --environment "$ENV_JSON" $VPC_ARGS \
        --region "$SRC_REGION"
else
    CMD="aws lambda create-function --function-name \"$LAMBDA_NAME\" \
        --runtime $(echo $CONFIG | jq -r '.Runtime') \
        --role \"$DEST_ROLE_ARN\" \
        --handler $(echo $CONFIG | jq -r '.Handler') \
        --zip-file fileb://function.zip \
        --description \"$(echo $CONFIG | jq -r '.Description')\" \
        --timeout $(echo $CONFIG | jq -r '.Timeout') \
        --memory-size $(echo $CONFIG | jq -r '.MemorySize') \
        --environment '$ENV_JSON' \
        --region \"$SRC_REGION\""
    if [ "$LAYER_ARNS" != "null" ] && [ -n "$LAYER_ARNS" ]; then
        CMD="$CMD --layers $LAYER_ARNS"
    fi
    if [ -n "$VPC_ARGS" ]; then
        CMD="$CMD $VPC_ARGS"
    fi
    eval $CMD
fi

DEST_LAMBDA_ARN=$(aws lambda get-function --function-name "$LAMBDA_NAME" --query 'Configuration.FunctionArn' --output text)

# === STEP 5: Replicate Event Source Mappings (SQS, Kinesis, DynamoDB) ===
echo "Fetching event source mappings from source Lambda..."
ASSUME_OUTPUT=$(aws sts assume-role --role-arn arn:aws:iam::$SRC_ACCOUNT:role/$ROLE_NAME --role-session-name LambdaReplicationSession)
export AWS_ACCESS_KEY_ID=$(echo "$ASSUME_OUTPUT" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$ASSUME_OUTPUT" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "$ASSUME_OUTPUT" | jq -r '.Credentials.SessionToken')

EVENT_SOURCES=$(aws lambda list-event-source-mappings --function-name "$LAMBDA_NAME" --region "$SRC_REGION" --query 'EventSourceMappings')
for row in $(echo "${EVENT_SOURCES}" | jq -c '.[]'); do
    SRC_ARN=$(echo $row | jq -r '.EventSourceArn')
    BATCH_SIZE=$(echo $row | jq -r '.BatchSize')
    ENABLED=$(echo $row | jq -r '.State')
    echo "Replicating event source: $SRC_ARN"
    read -p "Enter destination ARN for this source (leave empty to skip): " DEST_ARN
    if [ -n "$DEST_ARN" ]; then
        aws lambda create-event-source-mapping --function-name "$LAMBDA_NAME" --event-source-arn "$DEST_ARN" --batch-size "$BATCH_SIZE" --enabled true --region "$SRC_REGION"
    fi
done

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# === STEP 6: Fully replicate API Gateway trigger ===
echo "Checking for API Gateway trigger..."
ASSUME_OUTPUT=$(aws sts assume-role --role-arn arn:aws:iam::$SRC_ACCOUNT:role/$ROLE_NAME --role-session-name LambdaReplicationSession)
export AWS_ACCESS_KEY_ID=$(echo "$ASSUME_OUTPUT" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$ASSUME_OUTPUT" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "$ASSUME_OUTPUT" | jq -r '.Credentials.SessionToken')

# Find API Gateway REST API linked to Lambda
API_ID=$(aws apigateway get-rest-apis --query "items[?contains(name,'$LAMBDA_NAME')].id | [0]" --output text)
if [ "$API_ID" != "None" ]; then
    echo "Source API Gateway found: $API_ID"
    DEST_API_NAME=$(aws apigateway get-rest-apis --query "items[?name=='$LAMBDA_NAME'].name | [0]" --output text)
    if [ -z "$DEST_API_NAME" ]; then
        echo "Creating destination API Gateway..."
        DEST_API_ID=$(aws apigateway create-rest-api --name "$LAMBDA_NAME" --query 'id' --output text)
    else
        DEST_API_ID=$(aws apigateway get-rest-apis --query "items[?name=='$LAMBDA_NAME'].id | [0]" --output text)
    fi

    # Replicate resources and methods
    SRC_RESOURCES=$(aws apigateway get-resources --rest-api-id $API_ID --query 'items[*]')
    for RES in $(echo $SRC_RESOURCES | jq -c '.[]'); do
        PATH_PART=$(echo $RES | jq -r '.pathPart // ""')
        PARENT_ID=$(echo $RES | jq -r '.parentId')
        # Create resource if it doesn't exist
        DEST_RES_ID=$(aws apigateway get-resources --rest-api-id $DEST_API_ID --query "items[?path=='$PATH_PART'].id | [0]" --output text)
        if [ "$DEST_RES_ID" == "None" ] || [ -z "$DEST_RES_ID" ]; then
            DEST_RES_ID=$(aws apigateway create-resource --rest-api-id $DEST_API_ID --parent-id $(aws apigateway get-resources --rest-api-id $DEST_API_ID --query "items[?path=='/'].id" --output text) --path-part "$PATH_PART" --query 'id' --output text)
        fi
        # Copy methods
        METHODS=$(echo $RES | jq -r '.resourceMethods | keys[]?')
        for METH in $METHODS; do
            aws apigateway put-method --rest-api-id $DEST_API_ID --resource-id $DEST_RES_ID --http-method $METH --authorization-type NONE
            aws apigateway put-integration \
                --rest-api-id $DEST_API_ID \
                --resource-id $DEST_RES_ID \
                --http-method $METH \
                --type AWS_PROXY \
                --integration-http-method POST \
                --uri "arn:aws:apigateway:$SRC_REGION:lambda:path/2015-03-31/functions/$DEST_LAMBDA_ARN/invocations"
            STATEMENT_ID="APIGatewayInvoke$(date +%s)"
            aws lambda add-permission \
                --function-name "$LAMBDA_NAME" \
                --statement-id "$STATEMENT_ID" \
                --action lambda:InvokeFunction \
                --principal apigateway.amazonaws.com \
                --source-arn "arn:aws:execute-api:$SRC_REGION:$DEST_ACCOUNT_ID:$DEST_API_ID/*/$METH/*"
        done
    done

    # Deploy API
    aws apigateway create-deployment --rest-api-id $DEST_API_ID --stage-name prod
    echo "✅ API Gateway fully replicated to destination account"
else
    echo "No API Gateway trigger detected for Lambda '$LAMBDA_NAME'"
fi

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

echo "✅ Lambda '$LAMBDA_NAME' replication with API Gateway completed successfully!"
echo "Destination Role ARN: $DEST_ROLE_ARN"
