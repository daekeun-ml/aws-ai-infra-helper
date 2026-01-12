#!/bin/bash

set -e

# Define AWS Region
if [ -z ${AWS_REGION} ]; then
    echo "[WARNING] AWS_REGION environment variable is not set, automatically set depending on aws cli default region."
    export AWS_REGION=$(aws configure get region)
fi
echo "[INFO] AWS_REGION = ${AWS_REGION}"

# Get HyperPod cluster name if not set
if [ -z "${HYPERPOD_CLUSTER_NAME}" ]; then
    echo "[INFO] HYPERPOD_CLUSTER_NAME not set, searching for HyperPod clusters..."
    CLUSTERS=($(aws sagemaker list-clusters --region ${AWS_REGION} --query 'ClusterSummaries[].ClusterName' --output text 2>/dev/null))
    
    if [ ${#CLUSTERS[@]} -eq 0 ]; then
        echo "[ERROR] No HyperPod clusters found"
        exit 1
    fi
    
    echo "[INFO] Found HyperPod clusters:"
    for i in "${!CLUSTERS[@]}"; do
        echo "$((i+1))) ${CLUSTERS[i]}"
    done
    
    while true; do
        read -p "Enter choice (1-${#CLUSTERS[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#CLUSTERS[@]} ]; then
            export HYPERPOD_CLUSTER_NAME="${CLUSTERS[$((choice-1))]}"
            echo "[INFO] Selected HYPERPOD_CLUSTER_NAME = ${HYPERPOD_CLUSTER_NAME}"
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done
fi

# Get HyperPod cluster ARN
echo "[INFO] Getting cluster ARN for ${HYPERPOD_CLUSTER_NAME}..."
CLUSTER_ARN=$(aws sagemaker list-clusters --region $AWS_REGION --query "ClusterSummaries[?ClusterName=='${HYPERPOD_CLUSTER_NAME}'].ClusterArn | [0]" --output text 2>/dev/null | head -1)

if [ "$CLUSTER_ARN" == "None" ] || [ -z "$CLUSTER_ARN" ]; then
    echo "[ERROR] Could not find cluster ARN for ${HYPERPOD_CLUSTER_NAME}"
    exit 1
fi

echo "[INFO] Found cluster ARN: $CLUSTER_ARN"

# Instance type selection
echo ""
echo "Select instance type for compute allocation:"
echo "1) ml.g5.8xlarge"
echo "2) ml.g5.12xlarge"
read -p "Enter choice (1 or 2): " choice

case $choice in
    1)
        INSTANCE_TYPE="ml.g5.8xlarge"
        TEAM_A_CONFIG="ComputeQuotaResources=[{InstanceType=ml.g5.8xlarge,Accelerators=1}]"
        TEAM_B_CONFIG="ComputeQuotaResources=[{InstanceType=ml.g5.8xlarge,Count=2}]"
        ;;
    2)
        INSTANCE_TYPE="ml.g5.12xlarge"
        TEAM_A_CONFIG="ComputeQuotaResources=[{InstanceType=ml.g5.12xlarge,Accelerators=2}]"
        TEAM_B_CONFIG="ComputeQuotaResources=[{InstanceType=ml.g5.12xlarge,Count=2}]"
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

echo "Selected instance type: $INSTANCE_TYPE"

# Create cluster scheduler config
echo ""
echo "Creating cluster scheduler config..."

# Check if scheduler config already exists
EXISTING_CONFIG=$(aws sagemaker list-cluster-scheduler-configs --region $AWS_REGION --query "ClusterSchedulerConfigSummaries[?Name=='example-cluster-scheduler-config'].Name | [0]" --output text 2>/dev/null)

if [ "$EXISTING_CONFIG" != "None" ] && [ ! -z "$EXISTING_CONFIG" ]; then
    echo "✅ Cluster scheduler config 'example-cluster-scheduler-config' already exists."
else
    if aws sagemaker \
        --region $AWS_REGION \
        create-cluster-scheduler-config \
        --name "example-cluster-scheduler-config" \
        --cluster-arn "$CLUSTER_ARN" \
        --scheduler-config "PriorityClasses=[{Name=inference,Weight=90},{Name=experimentation,Weight=80},{Name=fine-tuning,Weight=50},{Name=training,Weight=70}],FairShare=Enabled" >/dev/null 2>&1; then
        echo "✅ Cluster scheduler config created successfully."
    else
        echo "❌ Failed to create cluster scheduler config."
        exit 1
    fi
fi

# Create Team A compute quota
echo ""
echo "Creating Team A compute quota..."

# Check if Team A quota already exists
EXISTING_QUOTA_A=$(aws sagemaker list-compute-quotas --region $AWS_REGION --query "ComputeQuotaSummaries[?ComputeQuotaName=='Team-A-Quota-Allocation'].ComputeQuotaName | [0]" --output text 2>/dev/null)

if [ "$EXISTING_QUOTA_A" != "None" ] && [ ! -z "$EXISTING_QUOTA_A" ]; then
    echo "✅ Team A compute quota already exists."
else
    if aws sagemaker \
        --region $AWS_REGION \
        create-compute-quota \
        --name "Team-A-Quota-Allocation" \
        --cluster-arn "$CLUSTER_ARN" \
        --compute-quota-config "${TEAM_A_CONFIG},ResourceSharingConfig={Strategy=LendAndBorrow,BorrowLimit=100},PreemptTeamTasks=LowerPriority" \
        --activation-state "Enabled" \
        --compute-quota-target "TeamName=team-a,FairShareWeight=100" >/dev/null 2>&1; then
        echo "✅ Team A compute quota created successfully."
    else
        echo "❌ Failed to create Team A compute quota."
        exit 1
    fi
fi

# Create Team B compute quota
echo ""
echo "Creating Team B compute quota..."

# Check if Team B quota already exists
EXISTING_QUOTA_B=$(aws sagemaker list-compute-quotas --region $AWS_REGION --query "ComputeQuotaSummaries[?ComputeQuotaName=='Team-B-Quota-Allocation'].ComputeQuotaName | [0]" --output text 2>/dev/null)

if [ "$EXISTING_QUOTA_B" != "None" ] && [ ! -z "$EXISTING_QUOTA_B" ]; then
    echo "✅ Team B compute quota already exists."
else
    if aws sagemaker \
        --region $AWS_REGION \
        create-compute-quota \
        --name "Team-B-Quota-Allocation" \
        --cluster-arn "$CLUSTER_ARN" \
        --compute-quota-config "${TEAM_B_CONFIG},ResourceSharingConfig={Strategy=LendAndBorrow,BorrowLimit=100},PreemptTeamTasks=LowerPriority" \
        --activation-state "Enabled" \
        --compute-quota-target "TeamName=team-b,FairShareWeight=100" >/dev/null 2>&1; then
        echo "✅ Team B compute quota created successfully."
    else
        echo "❌ Failed to create Team B compute quota."
        exit 1
    fi
fi

echo ""
echo "🎉 Task Governance setup completed successfully!"
