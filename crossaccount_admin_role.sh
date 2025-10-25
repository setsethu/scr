#!/bin/bash
# ================================================================
# Create or Update IAM Role with Cross-Account Trust & Admin Access
# ================================================================

set -e

echo "=== Create or Update Cross-Account IAM Role ==="

# Step 1: Select role type
echo ""
echo "Select where you are creating this role:"
echo "1) Source Account"
echo "2) Destination Account"
read -p "Enter choice (1 or 2): " CHOICE

if [ "$CHOICE" == "1" ]; then
  ROLE_NAME="rl-crossaccount-admin-source"
elif [ "$CHOICE" == "2" ]; then
  ROLE_NAME="rl-crossaccount-admin-destination"
else
  echo "❌ Invalid selection. Choose 1 or 2."
  exit 1
fi

# Step 2: Ask for account IDs
read -p "Enter Source Account ID: " SOURCE_ACCOUNT
read -p "Enter Destination Account ID: " DEST_ACCOUNT

echo ""
echo "Role Name: $ROLE_NAME"
echo "Source Account: $SOURCE_ACCOUNT"
echo "Destination Account: $DEST_ACCOUNT"
echo ""

# Step 3: Create trust policy JSON
cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": [
          "arn:aws:iam::${SOURCE_ACCOUNT}:root",
          "arn:aws:iam::${DEST_ACCOUNT}:root"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Step 4: Check if role exists
ROLE_EXISTS=$(aws iam get-role --role-name "$ROLE_NAME" --query "Role.RoleName" --output text 2>/dev/null || true)

if [ "$ROLE_EXISTS" == "$ROLE_NAME" ]; then
  echo "⚠️ Role '$ROLE_NAME' already exists."
  read -p "Do you want to update the trust policy? (y/n): " UPDATE_CHOICE
  if [[ "$UPDATE_CHOICE" =~ ^[Yy]$ ]]; then
    echo "Updating trust policy ..."
    aws iam update-assume-role-policy \
      --role-name "$ROLE_NAME" \
      --policy-document file://trust-policy.json
  else
    echo "Skipping trust policy update."
  fi
else
  echo "Creating IAM role: $ROLE_NAME ..."
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document file://trust-policy.json \
    --description "Cross-account administrator role trusted by $SOURCE_ACCOUNT and $DEST_ACCOUNT"
fi

# Step 5: Attach AdministratorAccess policy (if not already attached)
ATTACHED=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query "AttachedPolicies[].PolicyArn" --output text)
if [[ "$ATTACHED" != *"AdministratorAccess"* ]]; then
  echo "Attaching AdministratorAccess policy ..."
  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
else
  echo "AdministratorAccess policy already attached."
fi

# Step 6: Show final role details
echo ""
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query "Role.Arn" --output text)
echo "✅ Role created/updated successfully!"
echo "🔹 Role ARN: $ROLE_ARN"
echo ""
echo "Current trust policy:"
aws iam get-role --role-name "$ROLE_NAME" --query "Role.AssumeRolePolicyDocument" --output json

# Cleanup
rm -f trust-policy.json
