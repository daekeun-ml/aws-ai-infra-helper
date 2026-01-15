#!/bin/bash

# EKS cluster access permission grant script
# Usage: ./1.grant_eks_access.sh [cluster-name] [region]

# Function to load environment variables
load_env_vars() {
    local env_file=""

    # Try to find env_vars file in relative locations
    if [ -f "../setup/env_vars" ]; then
        env_file="../setup/env_vars"
    elif [ -f "../../setup/env_vars" ]; then
        env_file="../../setup/env_vars"
    elif [ -f "./env_vars" ]; then
        env_file="./env_vars"
    fi

    if [ -n "$env_file" ]; then
        echo "📁 Loading environment variables from $env_file..."
        source "$env_file"
        echo "✅ Environment variables loaded successfully"
        return 0
    else
        echo "⚠️  env_vars file not found, will use command line arguments or auto-detect"
        return 1
    fi
}

# Function to auto-detect cluster
auto_detect_cluster() {
    local region=${1:-$AWS_REGION}

    echo "🔍 Auto-detecting EKS cluster in region: $region"

    # Get EKS clusters
    local clusters=$(aws eks list-clusters --region "$region" --query 'clusters' --output text 2>/dev/null)

    if [[ -z "$clusters" || "$clusters" == "None" ]]; then
        echo "❌ No EKS clusters found in region $region"
        exit 1
    fi

    # If only one cluster, use it
    local cluster_count=$(echo $clusters | wc -w)
    if [ $cluster_count -eq 1 ]; then
        EKS_CLUSTER_NAME="$clusters"
        AWS_REGION="$region"
        echo "✅ Auto-selected cluster: $EKS_CLUSTER_NAME"
    else
        echo "📋 Multiple clusters found:"
        echo "$clusters"
        echo "Please specify cluster name as first argument:"
        echo "Usage: $0 <cluster-name> [region]"
        exit 1
    fi
}

# Main logic
echo "=========================================="
echo "🚀 EKS Cluster Access Setup"
echo "=========================================="
echo ""

# Set default region from AWS CLI if not set
AWS_REGION=${AWS_REGION:-$(aws configure get region)}

# Try to load environment variables first
if load_env_vars; then
    # env_vars loaded - use EKS_CLUSTER_NAME and AWS_REGION from file
    :
else
    # Fall back to command line arguments or auto-detection
    if [ -z "$1" ]; then
        auto_detect_cluster "$AWS_REGION"
    else
        EKS_CLUSTER_NAME="$1"
        AWS_REGION="${2:-$AWS_REGION}"
    fi
fi

echo ""
echo "📍 Cluster: $EKS_CLUSTER_NAME"
echo "📍 Region: $AWS_REGION"
echo ""

# Automatically get current user's ARN
echo "Step 1: Checking current user ARN..."
USER_ARN=$(aws sts get-caller-identity --query Arn --output text)

if [ $? -ne 0 ] || [ -z "$USER_ARN" ]; then
    echo "❌ Cannot retrieve current user ARN. Please check AWS credentials."
    exit 1
fi

# Convert assumed role ARN to role ARN for EKS Access Entry
if [[ "$USER_ARN" == *"assumed-role"* ]]; then
    ROLE_NAME=$(echo "$USER_ARN" | sed 's|.*assumed-role/\([^/]*\)/.*|\1|')
    ACCOUNT_ID=$(echo "$USER_ARN" | sed 's|.*::\([0-9]*\):.*|\1|')
    PRINCIPAL_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
    echo "🔄 Converted assumed-role ARN to role ARN: $PRINCIPAL_ARN"
else
    PRINCIPAL_ARN="$USER_ARN"
fi

echo "   User ARN: $USER_ARN"
echo "   Principal ARN: $PRINCIPAL_ARN"
echo ""

# Check access permission
echo "Step 2: Checking current access permission..."
if aws eks describe-access-entry \
    --cluster-name "$EKS_CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --principal-arn "$PRINCIPAL_ARN" >/dev/null 2>&1; then

    echo "✅ Already have cluster access permission."

    # Update kubeconfig anyway
    aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME" >/dev/null 2>&1
else
    echo "❌ No cluster access permission. Granting permission..."
    echo ""

    # Create Access Entry
    echo "   Creating Access Entry..."
    if aws eks create-access-entry \
        --cluster-name "$EKS_CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --principal-arn "$PRINCIPAL_ARN" >/dev/null 2>&1; then
        echo "   ✅ Access Entry created successfully"
    else
        echo "   ⚠️  Access Entry creation failed (may already exist)"
    fi

    # Associate cluster admin policy
    echo "   Associating cluster admin policy..."
    if aws eks associate-access-policy \
        --cluster-name "$EKS_CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --principal-arn "$PRINCIPAL_ARN" \
        --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
        --access-scope type=cluster >/dev/null 2>&1; then
        echo "   ✅ Admin policy associated successfully"
    else
        echo "   ⚠️  Admin policy association failed"
    fi

    # Update kubeconfig
    echo "   Updating kubeconfig..."
    aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME"
fi

echo ""
echo "Step 3: Verifying cluster connection..."
kubectl get nodes -o wide

echo ""
echo "Step 4: Checking GPU nodes..."
kubectl get nodes -o custom-columns="NAME:.metadata.name,INSTANCE-TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,GPU:.status.capacity.nvidia\.com/gpu"

echo ""
echo "Step 5: Checking required components..."
echo ""
echo "[Kubeflow Training Operator]"
kubectl get pods -n kubeflow 2>/dev/null || echo "⚠️  Warning: kubeflow namespace not found"

echo ""
echo "[NVIDIA Device Plugin]"
kubectl get pods -n kube-system | grep nvidia || echo "⚠️  Warning: NVIDIA device plugin not found"

echo ""
echo "=========================================="
echo "✅ EKS access setup completed!"
echo "=========================================="
echo ""
echo "Next step: ./2.run_training.sh"
