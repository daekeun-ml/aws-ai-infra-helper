#!/bin/bash

# Disable AWS CLI pager completely
export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off
# Get AWS Account ID with fallback
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
if [ -z "$AWS_ACCOUNT_ID" ] || [ "$AWS_ACCOUNT_ID" = "None" ]; then
    AWS_ACCOUNT_ID="handson$(shuf -i 100000-999999 -n 1)"
    echo "⚠️  Could not retrieve AWS Account ID, using fallback: $AWS_ACCOUNT_ID"
fi
export AWS_ACCOUNT_ID

# Get HyperPod cluster name as input
if [ -z "$1" ]; then
    echo "Usage: $0 <hyperpod-cluster-name>"
    echo "Example: $0 hyperpod-cluster-p5-ohio"
    exit 1
fi

CLUSTER_NAME="$1"

# Convert hyperpod cluster name to CloudFormation stack name pattern
if [[ $CLUSTER_NAME == hyperpod-* ]]; then
    STACK_PATTERN="sagemaker-$CLUSTER_NAME"
else
    STACK_PATTERN="$CLUSTER_NAME"
fi

# Find main stack starting with pattern (exclude nested stacks)
STACK_NAME=$(aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --query "StackSummaries[?starts_with(StackName, '$STACK_PATTERN') && !contains(StackName, '-')].StackName" --output text)

if [ -z "$STACK_NAME" ]; then
    # If no main stack found, select the shortest named stack
    STACK_NAME=$(aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --query "StackSummaries[?starts_with(StackName, '$STACK_PATTERN')]" --output json | jq -r 'sort_by(.StackName | length) | .[0].StackName')
fi

if [ -z "$STACK_NAME" ] || [ "$STACK_NAME" = "null" ]; then
    echo "Error: Could not find CloudFormation stack starting with '$STACK_PATTERN'."
    exit 1
fi

echo "Found stack: $STACK_NAME"

# Get AWS region from stack ARN
STACK_ARN=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query 'Stacks[0].StackId' --output text)
export AWS_REGION=$(echo $STACK_ARN | cut -d':' -f4)

# Get nested stack names
VPC_STACK=$(aws cloudformation describe-stack-resources --stack-name $STACK_NAME --logical-resource-id "VPCStack" --query 'StackResources[0].PhysicalResourceId' --output text)
SECURITY_GROUP_STACK=$(aws cloudformation describe-stack-resources --stack-name $STACK_NAME --logical-resource-id "SecurityGroupStack" --query 'StackResources[0].PhysicalResourceId' --output text)
FSX_STACK=$(aws cloudformation describe-stack-resources --stack-name $STACK_NAME --logical-resource-id "FsxStack" --query 'StackResources[0].PhysicalResourceId' --output text)

# Get VPC and subnets from VPC stack
export VPC_ID=$(aws cloudformation describe-stack-resources --stack-name $VPC_STACK --query 'StackResources[?ResourceType==`AWS::EC2::VPC`].PhysicalResourceId' --output text)
SUBNETS=$(aws cloudformation describe-stack-resources --stack-name $VPC_STACK --query 'StackResources[?ResourceType==`AWS::EC2::Subnet`].PhysicalResourceId' --output text)
export PUBLIC_SUBNET_ID=$(echo $SUBNETS | cut -d' ' -f1)
export PRIVATE_SUBNET_ID=$(echo $SUBNETS | cut -d' ' -f2)

# Get security group from security group stack
export SECURITY_GROUP_ID=$(aws cloudformation describe-stack-resources --stack-name $SECURITY_GROUP_STACK --query 'StackResources[?ResourceType==`AWS::EC2::SecurityGroup`].PhysicalResourceId' --output text)

# Get file system from FSx stack
export FSX_LUSTRE_ID=$(aws cloudformation describe-stack-resources --stack-name $FSX_STACK --query 'StackResources[?ResourceType==`AWS::FSx::FileSystem`].PhysicalResourceId' --output text)

# Get FSx details
if [ ! -z "$FSX_LUSTRE_ID" ]; then
    FSX_INFO=$(aws fsx describe-file-systems --file-system-ids $FSX_LUSTRE_ID --output json)
    export FSX_LUSTRE_MOUNT_NAME=$(echo $FSX_INFO | jq -r '.FileSystems[0].LustreConfiguration.MountName // empty')
    export FSX_LUSTRE_DNS=$(echo $FSX_INFO | jq -r '.FileSystems[0].DNSName // empty')
fi

# OpenZFS volume ID (if exists)
export FSX_OPENZFS_ROOT_VOLUME_ID=$(aws cloudformation describe-stack-resources --stack-name $FSX_STACK --query 'StackResources[?ResourceType==`AWS::FSx::Volume`].PhysicalResourceId' --output text)

export S3_BUCKET_NAME=hyperpod-${AWS_ACCOUNT_ID}-${AWS_REGION}

# Display results
echo "VPC_ID: $VPC_ID"
echo "PUBLIC_SUBNET_ID: $PUBLIC_SUBNET_ID"
echo "PRIVATE_SUBNET_ID: $PRIVATE_SUBNET_ID"
echo "SECURITY_GROUP_ID: $SECURITY_GROUP_ID"
echo "FSX_LUSTRE_ID: $FSX_LUSTRE_ID"
echo "FSX_LUSTRE_MOUNT_NAME: $FSX_LUSTRE_MOUNT_NAME"
echo "FSX_LUSTRE_DNS: $FSX_LUSTRE_DNS"
echo "FSX_OPENZFS_ROOT_VOLUME_ID: $FSX_OPENZFS_ROOT_VOLUME_ID"
echo "S3_BUCKET_NAME: $S3_BUCKET_NAME"

# Save environment variables to file
cat > ../stack-env-vars.sh << EOF
export AWS_REGION="$AWS_REGION"
export VPC_ID="$VPC_ID"
export PUBLIC_SUBNET_ID="$PUBLIC_SUBNET_ID"
export PRIVATE_SUBNET_ID="$PRIVATE_SUBNET_ID"
export SECURITY_GROUP_ID="$SECURITY_GROUP_ID"
export FSX_LUSTRE_ID="$FSX_LUSTRE_ID"
export FSX_LUSTRE_MOUNT_NAME="$FSX_LUSTRE_MOUNT_NAME"
export FSX_LUSTRE_DNS="$FSX_LUSTRE_DNS"
export FSX_OPENZFS_ROOT_VOLUME_ID="$FSX_OPENZFS_ROOT_VOLUME_ID"
export S3_BUCKET_NAME="$S3_BUCKET_NAME"
EOF

echo "Environment variables saved to ../stack-env-vars.sh file."
echo "Usage: source ../stack-env-vars.sh"

# Source the environment variables file
echo "Sourcing ../stack-env-vars.sh to load environment variables..."
source ../stack-env-vars.sh

# Check resource status
echo ""
echo "=== Resource Status Check ==="

echo "AWS_REGION: $AWS_REGION"

# VPC Status
if [ ! -z "$VPC_ID" ]; then
    echo ""
    echo "VPC Status:"
    aws ec2 describe-vpcs \
      --vpc-ids $VPC_ID \
      --region $AWS_REGION \
      --query 'Vpcs[0].[VpcId,CidrBlock,State]' \
      --output table \
      --no-paginate
fi

# Subnet Status
if [ ! -z "$PUBLIC_SUBNET_ID" ] || [ ! -z "$PRIVATE_SUBNET_ID" ]; then
    echo ""
    echo "Subnet Status:"
    SUBNET_IDS=""
    [ ! -z "$PUBLIC_SUBNET_ID" ] && SUBNET_IDS="$PUBLIC_SUBNET_ID"
    [ ! -z "$PRIVATE_SUBNET_ID" ] && SUBNET_IDS="$SUBNET_IDS $PRIVATE_SUBNET_ID"
    aws ec2 describe-subnets \
      --subnet-ids $SUBNET_IDS \
      --region $AWS_REGION \
      --query 'Subnets[*].[SubnetId,CidrBlock,State,AvailabilityZone]' \
      --output table \
      --no-paginate
fi

# Security Group Status
if [ ! -z "$SECURITY_GROUP_ID" ]; then
    echo ""
    echo "Security Group Status:"
    aws ec2 describe-security-groups \
      --group-ids $SECURITY_GROUP_ID \
      --region $AWS_REGION \
      --query 'SecurityGroups[0].[GroupId,GroupName,Description]' \
      --output table \
      --no-paginate
fi

# FSx Status
if [ ! -z "$FSX_LUSTRE_ID" ]; then
    echo ""
    echo "FSx Lustre Status:"
    aws fsx describe-file-systems \
      --file-system-ids $FSX_LUSTRE_ID \
      --region $AWS_REGION \
      --query 'FileSystems[0].[FileSystemId,FileSystemType,Lifecycle,StorageCapacity]' \
      --output table \
      --no-paginate
fi
