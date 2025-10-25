# === Step 1: Get list of Lambda functions from source ===
echo "🔍 Fetching list of Lambda functions from source account..."

ASSUME_OUTPUT=$(aws sts assume-role \
  --role-arn arn:aws:iam::$SRC_ACCOUNT:role/rl-crossaccount-admin-source \
  --role-session-name LambdaListSession)

export AWS_ACCESS_KEY_ID=$(echo "$ASSUME_OUTPUT" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$ASSUME_OUTPUT" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "$ASSUME_OUTPUT" | jq -r '.Credentials.SessionToken')

FUNCTIONS=$(aws lambda list-functions --region "$SRC_REGION" --query 'Functions[*].FunctionName' --output text)
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

if [ -z "$FUNCTIONS" ]; then
  echo "❌ No Lambda functions found in source account!"
  exit 1
fi

echo "Available Lambda functions in source:"
INDEX=1
for f in $FUNCTIONS; do
  echo "$INDEX) $f"
  INDEX=$((INDEX + 1))
done

read -p "Enter the numbers of the functions to replicate (comma separated, e.g. 1,3,5): " SELECTION

# Parse user selection into an array of Lambda names
SELECTED_FUNCS=()
IFS=',' read -ra NUMS <<< "$SELECTION"
INDEX=1
for f in $FUNCTIONS; do
  for num in "${NUMS[@]}"; do
    if [ "$INDEX" -eq "$num" ]; then
      SELECTED_FUNCS+=("$f")
    fi
  done
  INDEX=$((INDEX + 1))
done

echo "Selected functions for replication: ${SELECTED_FUNCS[*]}"
