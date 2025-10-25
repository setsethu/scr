#!/bin/bash
set -e

echo "=== Safe Single-Lambda Cross-Account Replication Script ==="

# === USER INPUT ===
read -p "Enter the full ARN of the source Lambda function: " LAMBDA_ARN
read -p "Enter the cross-account role name in the source account (default: CrossAccountAccessRole): " ROLE_NAME
ROLE_NAME=${ROLE_NAME:-CrossAccountAccessRole}

# Extract source account, region, function name
SRC_ACCOUNT=$(echo "$LAMBDA_ARN" | awk -F: '{print $5}')
SRC_REGION=$(echo "$LAMBDA_ARN" | awk -F: '{print $4}')
LAMBDA_NAME=$(echo "$LAMBDA_ARN" | awk -F: '{print $7}')

echo "Source Account : $SRC_ACCOUNT"
echo "Source Region  : $SRC_REGION"
echo "Lambda Name    : $LAMBDA_NAME"

# Destination account info
DEST_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
DEST_USER=$(aws sts get-caller-identity --query 'Arn' --output text)
echo "Destination Account: $DEST_ACCOUNT_ID ($DEST_USER)"

read -p "Proceed to replicate Lambda? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && { echo "Operation cancelled."; exit 0; }

# === STEP 1: Assume role in source account ===
echo "Assuming role $ROLE_NAME in source account..."
ASSUME_OUTPUT=$(aws sts assume-role \
    --role-arn arn:aws:iam::$SRC_ACCOUNT:role/$ROLE_NAME \
    --role-session-name LambdaReplicationSession)

export AWS_ACCESS_KEY_ID=$(echo "$ASSUME_OUTPUT" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$ASSUME_OUTPUT" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "$ASSUME_OUTPUT" | jq -r '.Credentials.SessionToken')

# === STEP 2: Get Lambda configuration and code ===
CONFIG=$(aws lambda get-function-configuration --function-name "$LAMBDA_NAME" --region "$SRC_REGION")
SRC_ROLE_ARN=$(echo "$CONFIG" | jq -r '.Role')
SRC_ROLE_NAME=$(basename "$SRC_ROLE_ARN")

ENV_VARS=$(echo "$CONFIG" | jq -r '.Environment | if .Variables then .Variables else {} end')
LAYERS=$(echo "$CONFIG" | jq -r '.Layers | if . != null then map(.Arn) else [] end')
VPC_SUBNETS=$(echo "$CONFIG" | jq -r '.VpcConfig.SubnetIds | if . != null then join(",") else "" end')
VPC_SGS=$(echo "$CONFIG" | jq -r '.VpcConfig.SecurityGroupIds | if . != null then join(",") else "" end')

CODE_URL=$(aws lambda get-function --function-name "$LAMBDA_NAME" --region "$SRC_REGION" --query 'Code.Location' --output text)
curl -s -o function.zip "$CODE_URL"

# Reset to destination account
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# === STEP 3: Create/reuse IAM role in destination ===
ROLE_EXISTS=$(aws iam get-role --role-name "$SRC_ROLE_NAME" --query 'Role.RoleName' --output text 2>/dev/null || true)
if [ -z "$ROLE_EXISTS" ]; then
    echo "IAM role '$SRC_ROLE_NAME' not found in destination. Creating role..."

    # Try to get trust policy from source account
    TRUST_POLICY=$(aws iam get-role --role-name "$SRC_ROLE_NAME" --region "$SRC_REGION" --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null | jq -c '.' || true)

    if [ -z "$TRUST_POLICY" ] || [ "$TRUST_POLICY" == "{}" ]; then
        echo "⚠️ Source role not found or invalid. Using default Lambda trust policy."
        TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    fi

    aws iam create-role \
        --role-name "$SRC_ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY"
    sleep 10
else
    echo "Reusing existing role: $SRC_ROLE_NAME"
fi

DEST_ROLE_ARN=$(aws iam get-role --role-name "$SRC_ROLE_NAME" --query 'Role.Arn' --output text)

# === STEP 4: Attach managed policies ===
echo "Attaching standard Lambda managed policies..."
aws iam attach-role-policy --role-name "$SRC_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null
if [ -n "$VPC_SUBNETS" ]; then
    aws iam attach-role-policy --role-name "$SRC_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole >/dev/null
fi

# === STEP 5: Create/update Lambda in destination ===
ENV_JSON=$(echo "$ENV_VARS" | jq -c '{Variables:.}')
LAYER_ARNS=$(echo "$LAYERS" | jq -r '. | join(" ")')
VPC_ARGS=""
if [ -n "$VPC_SUBNETS" ] && [ "$VPC_SUBNETS" != "null" ]; then
    VPC_ARGS="--vpc-config SubnetIds=[$VPC_SUBNETS],SecurityGroupIds=[$VPC_SGS]"
fi

EXISTS=$(aws lambda get-function --function-name "$LAMBDA_NAME" --region "$SRC_REGION" --query 'Configuration.FunctionName' --output text 2>/dev/null || true)
if [ -n "$EXISTS" ]; then
    echo "Lambda exists — updating code/configuration..."
    aws lambda update-function-code --function-name "$LAMBDA_NAME" --zip-file fileb://function.zip --region "$SRC_REGION"
    aws lambda update-function-configuration --function-name "$LAMBDA_NAME" --role "$DEST_ROLE_ARN" --runtime $(echo $CONFIG | jq -r '.Runtime') --handler $(echo $CONFIG | jq -r '.Handler') --description "$(echo $CONFIG | jq -r '.Description')" --timeout $(echo $CONFIG | jq -r '.Timeout') --memory-size $(echo $CONFIG | jq -r '.MemorySize') --environment "$ENV_JSON" $VPC_ARGS --region "$SRC_REGION"
else
    CMD="aws lambda create-function --function-name \"$LAMBDA_NAME\" --runtime $(echo $CONFIG | jq -r '.Runtime') --role \"$DEST_ROLE_ARN\" --handler $(echo $CONFIG | jq -r '.Handler') --zip-file fileb://function.zip --description \"$(echo $CONFIG | jq -r '.Description')\" --timeout $(echo $CONFIG | jq -r '.Timeout') --memory-size $(echo $CONFIG | jq -r '.MemorySize') --environment '$ENV_JSON' --region \"$SRC_REGION\""
    if [ "$LAYER_ARNS" != "null" ] && [ -n "$LAYER_ARNS" ]; then
        CMD="$CMD --layers $LAYER_ARNS"
    fi
    if [ -n "$VPC_ARGS" ]; then
        CMD="$CMD $VPC_ARGS"
    fi
    eval $CMD
fi

echo "✅ Lambda '$LAMBDA_NAME' replicated successfully!"
echo "Destination Role ARN: $DEST_ROLE_ARN"
