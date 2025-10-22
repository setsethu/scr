#!/bin/bash
set -e
REGION="us-east-1"

echo "===================================================="
echo " 🟢 RDS / Aurora Cross-Account Snapshot - DESTINATION SIDE"
echo " Region: $REGION"
echo "===================================================="
echo ""

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "Running in destination account: $AWS_ACCOUNT_ID"
echo ""

# Step 1: Select shared snapshot
echo "=== STEP 1: Select shared snapshot ==="
echo ""

CLUSTER_SNAPS=($(aws rds describe-db-cluster-snapshots --include-shared --region $REGION --query "DBClusterSnapshots[*].DBClusterSnapshotIdentifier" --output text))
INSTANCE_SNAPS=($(aws rds describe-db-snapshots --include-shared --region $REGION --query "DBSnapshots[*].DBSnapshotIdentifier" --output text))

i=1
echo "Shared Cluster Snapshots:"
for s in "${CLUSTER_SNAPS[@]}"; do
    echo "  [$i] $s"
    ((i++))
done
CLUSTER_COUNT=$((i-1))

echo ""
echo "Shared Instance Snapshots:"
for s in "${INSTANCE_SNAPS[@]}"; do
    echo "  [$i] $s"
    ((i++))
done

read -p "Enter the number of snapshot to use: " SNAP_NUM
if [ "$SNAP_NUM" -le "$CLUSTER_COUNT" ]; then
    DB_TYPE="cluster"
    SHARED_SNAP="${CLUSTER_SNAPS[$((SNAP_NUM-1))]}"
else
    DB_TYPE="instance"
    INDEX=$((SNAP_NUM - CLUSTER_COUNT - 1))
    SHARED_SNAP="${INSTANCE_SNAPS[$INDEX]}"
fi
echo "✅ Selected snapshot: $SHARED_SNAP"
echo ""

# Step 2: Copy snapshot with default KMS
echo "=== STEP 2: Copying snapshot using default AWS-managed KMS key ==="

# Extract base DB/cluster name from snapshot
BASE_DB_NAME=$(basename "$SHARED_SNAP" | sed -E 's/(-copy|-destination)*$//')

# Replace invalid characters and lowercase
SANITIZED_BASE=$(echo "$BASE_DB_NAME" | tr -cd '[:alnum:]-' | tr '[:upper:]' '[:lower:]')

# Ensure it starts with a letter
if [[ ! "$SANITIZED_BASE" =~ ^[a-z] ]]; then
    SANITIZED_BASE="db-${SANITIZED_BASE}"
fi

# Remove trailing hyphen
SANITIZED_BASE=$(echo "$SANITIZED_BASE" | sed 's/-$//')

# Truncate for snapshot copy
MAX_LENGTH=63
SUFFIX="-destination"
TRUNCATED_BASE=${SANITIZED_BASE:0:$((MAX_LENGTH - ${#SUFFIX}))}

COPY_NAME="${TRUNCATED_BASE}${SUFFIX}"

KMS_KEY="alias/aws/rds"

echo "📦 Copying snapshot as: $COPY_NAME ... please wait"
if [[ "$DB_TYPE" == "cluster" ]]; then
    aws rds copy-db-cluster-snapshot \
        --source-db-cluster-snapshot-identifier $SHARED_SNAP \
        --target-db-cluster-snapshot-identifier $COPY_NAME \
        --kms-key-id $KMS_KEY \
        --region $REGION >/dev/null
    aws rds wait db-cluster-snapshot-available --db-cluster-snapshot-identifier $COPY_NAME --region $REGION
else
    aws rds copy-db-snapshot \
        --source-db-snapshot-identifier $SHARED_SNAP \
        --target-db-snapshot-identifier $COPY_NAME \
        --kms-key-id $KMS_KEY \
        --region $REGION >/dev/null
    aws rds wait db-snapshot-available --db-snapshot-identifier $COPY_NAME --region $REGION
fi
echo "✅ Snapshot copy completed: $COPY_NAME"
echo ""

# Step 3: Network config
echo "=== STEP 3: Select VPC, Subnet & Security Group ==="
aws ec2 describe-vpcs --region $REGION --query "Vpcs[*].{VPC:VpcId,CIDR:CidrBlock}" --output table

echo ""
SUBNETS=($(aws rds describe-db-subnet-groups --region $REGION --query "DBSubnetGroups[*].DBSubnetGroupName" --output text))
i=1
for s in "${SUBNETS[@]}"; do
    echo "  [$i] $s"
    ((i++))
done
read -p "Select Subnet Group number: " SUB_NUM
SUB_GROUP="${SUBNETS[$((SUB_NUM-1))]}"

echo ""
SG_IDS=($(aws ec2 describe-security-groups --region $REGION --query "SecurityGroups[*].GroupId" --output text))
SG_NAMES=($(aws ec2 describe-security-groups --region $REGION --query "SecurityGroups[*].GroupName" --output text))
i=1
for idx in "${!SG_IDS[@]}"; do
    echo "  [$i] ${SG_NAMES[$idx]} (${SG_IDS[$idx]})"
    ((i++))
done
read -p "Select Security Group numbers (comma-separated): " SG_SELECTION
IFS=',' read -ra SG_LIST <<< "$SG_SELECTION"
SG_ARRAY=()
for s in "${SG_LIST[@]}"; do
    SG_ARRAY+=("${SG_IDS[$((s-1))]}")
done
SG_IDS_STR=$(IFS=,; echo "${SG_ARRAY[*]}")

# Step 4: Restore
echo ""
echo "=== STEP 4: Restore snapshot to DB ==="
echo "⚠️ For T-class instances, ensure the class exists in this region (include previous generation if needed)."

# Prompt exact DB identifier to match source
read -p "Enter DB identifier (same as source, max 63 chars): " DB_NEW
read -p "Enter DB instance class (same as source, e.g., db.t3.micro): " INSTANCE_CLASS

if [[ "$DB_TYPE" == "cluster" ]]; then
    echo "Restoring Aurora cluster..."
    aws rds restore-db-cluster-from-snapshot \
        --db-cluster-identifier $DB_NEW \
        --snapshot-identifier $COPY_NAME \
        --engine aurora-mysql \
        --db-subnet-group-name $SUB_GROUP \
        --vpc-security-group-ids $SG_IDS_STR \
        --region $REGION >/dev/null

    # Create 2 instances in separate AZs for multi-AZ
    AZS=($(aws ec2 describe-subnets --subnet-ids $(aws rds describe-db-subnet-groups --db-subnet-group-name $SUB_GROUP --query "DBSubnetGroups[0].Subnets[*].SubnetIdentifier" --output text) --region $REGION --query "Subnets[*].AvailabilityZone" --output text))
    aws rds create-db-instance \
        --db-instance-identifier "${DB_NEW}-instance-1" \
        --db-cluster-identifier $DB_NEW \
        --engine aurora-mysql \
        --db-instance-class $INSTANCE_CLASS \
        --availability-zone ${AZS[0]} \
        --region $REGION >/dev/null
    aws rds create-db-instance \
        --db-instance-identifier "${DB_NEW}-instance-2" \
        --db-cluster-identifier $DB_NEW \
        --engine aurora-mysql \
        --db-instance-class $INSTANCE_CLASS \
        --availability-zone ${AZS[1]} \
        --region $REGION >/dev/null

else
    echo "Restoring RDS instance (multi-AZ)..."
    aws rds restore-db-instance-from-db-snapshot \
        --db-instance-identifier $DB_NEW \
        --db-snapshot-identifier $COPY_NAME \
        --db-subnet-group-name $SUB_GROUP \
        --vpc-security-group-ids $SG_IDS_STR \
        --db-instance-class $INSTANCE_CLASS \
        --multi-az \
        --region $REGION
fi

echo "✅ DB restored successfully with multi-AZ and source DB identifier."
echo ""
echo "🎉 DESTINATION SIDE COMPLETE."
