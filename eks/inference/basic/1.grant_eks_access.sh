#!/bin/bash

# EKS cluster access permission grant script
# Usage: ./grant-eks-access.sh <cluster-name> [region]

if [ $# -lt 1 ]; then
    echo "Usage: $0 <cluster-name> [region]"
    echo "Example: $0 my-cluster us-east-2"
    exit 1
fi

CLUSTER_NAME=$1
REGION=${2:-us-east-2}  # Default: us-east-2

# Automatically get current user's ARN
echo "Checking current user ARN..."
USER_ARN=$(aws sts get-caller-identity --query Arn --output text)

if [ $? -ne 0 ] || [ -z "$USER_ARN" ]; then
    echo "❌ Cannot retrieve current user ARN. Please check AWS credentials."
    exit 1
fi

echo "Granting EKS cluster access permission..."
echo "Cluster: $CLUSTER_NAME"
echo "User ARN: $USER_ARN"
echo "Region: $REGION"
echo

export CLUSTER_NAME=$CLUSTER_NAME

# First check access permission
echo "Checking current access permission..."
kubectl get nodes --request-timeout=5s > /dev/null 2>&1

if [ $? -eq 0 ]; then
    echo "✅ Already have cluster access permission."
    echo "kubectl get nodes command works normally."
    exit 0
fi

echo "❌ No cluster access permission. Granting permission..."
echo

# 1. Create Access Entry
echo "1. Creating Access Entry..."
aws eks create-access-entry \
    --cluster-name "$CLUSTER_NAME" \
    --region "$REGION" \
    --principal-arn "$USER_ARN"

if [ $? -eq 0 ]; then
    echo "✅ Access Entry creation completed"
else
    echo "❌ Access Entry creation failed (may already exist)"
fi

echo

# 2. Associate admin policy
echo "2. Associating cluster admin policy..."
aws eks associate-access-policy \
    --cluster-name "$CLUSTER_NAME" \
    --region "$REGION" \
    --principal-arn "$USER_ARN" \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
    --access-scope type=cluster

if [ $? -eq 0 ]; then
    echo "✅ Admin policy association completed"
else
    echo "❌ Admin policy association failed"
    exit 1
fi

echo

# 3. Update kubeconfig
echo "3. Updating kubeconfig..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"

if [ $? -eq 0 ]; then
    echo "✅ kubeconfig update completed"
else
    echo "❌ kubeconfig update failed"
    exit 1
fi

echo
echo "🎉 EKS cluster access permission grant completed!"
echo "Verify with the following command: kubectl get nodes"
