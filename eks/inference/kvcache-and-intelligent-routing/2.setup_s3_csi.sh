#!/bin/bash

# Setup S3 CSI Driver credentials for HyperPod Inference
# This is a required step before deploying the endpoint

set -e

echo "🔧 Setting up S3 CSI Driver credentials..."

# Load S3_BUCKET from file if exists
if [ -f ".s3_bucket_env" ]; then
    source .s3_bucket_env
fi

# Get cluster info
CLUSTER_NAME=$(kubectl config current-context | cut -d'/' -f2)
REGION=$(aws configure get region 2>/dev/null || echo "us-east-2")
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "📍 Cluster: $CLUSTER_NAME"
echo "📍 Region: $REGION"
echo "📍 Account: $ACCOUNT_ID"

# Check S3_BUCKET
if [ -z "$S3_BUCKET" ]; then
    echo "❌ S3_BUCKET environment variable not set!"
    echo "💡 Set it: export S3_BUCKET=your-bucket-name"
    exit 1
fi

POLICY_NAME="S3MountpointAccessPolicy-${CLUSTER_NAME}"
ROLE_NAME="S3CSIRole-${CLUSTER_NAME}"

echo "🪣 Bucket: $S3_BUCKET"

# 1. Create S3 access policy
echo "📝 Creating S3 access policy..."
cat > /tmp/s3-csi-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:GetBucketLocation"
            ],
            "Resource": [
                "arn:aws:s3:::${S3_BUCKET}",
                "arn:aws:s3:::${S3_BUCKET}/*"
            ]
        }
    ]
}
EOF

aws iam create-policy \
    --policy-name $POLICY_NAME \
    --policy-document file:///tmp/s3-csi-policy.json \
    --region $REGION 2>/dev/null || echo "ℹ️  Policy already exists"

# 2. Get policy ARN
POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn" --output text)
echo "📋 Policy ARN: $POLICY_ARN"

# 3. Create IAM service account using eksctl (AWS recommended way)
echo "👤 Creating IAM service account..."
eksctl create iamserviceaccount \
    --name s3-csi-driver-sa \
    --override-existing-serviceaccounts \
    --namespace kube-system \
    --cluster $CLUSTER_NAME \
    --attach-policy-arn $POLICY_ARN \
    --approve \
    --role-name $ROLE_NAME \
    --region $REGION

# Also add inline policy to AmazonEKS_S3_CSI_DriverRole
echo "🔗 Adding inline policy to AmazonEKS_S3_CSI_DriverRole..."
aws iam put-role-policy \
    --role-name AmazonEKS_S3_CSI_DriverRole \
    --policy-name S3BucketAccessInlinePolicy \
    --policy-document file:///tmp/s3-csi-policy.json 2>/dev/null

if [ $? -eq 0 ]; then
    echo "✅ Inline policy added to AmazonEKS_S3_CSI_DriverRole"
else
    echo "⚠️  Warning: Failed to add inline policy (role may not exist)"
fi

# 4. Label service account (required by S3 CSI driver)
echo "🏷️  Labeling service account..."
kubectl label serviceaccount s3-csi-driver-sa \
    app.kubernetes.io/component=csi-driver \
    app.kubernetes.io/instance=aws-mountpoint-s3-csi-driver \
    app.kubernetes.io/managed-by=EKS \
    app.kubernetes.io/name=aws-mountpoint-s3-csi-driver \
    -n kube-system --overwrite

# 5. Restart S3 CSI driver pods
echo "🔄 Restarting S3 CSI driver pods..."
kubectl delete pods -n kube-system -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver
kubectl delete pods -n mount-s3 --all 2>/dev/null || echo "ℹ️  No mount-s3 pods"

# Cleanup
rm -f /tmp/s3-csi-policy.json

echo ""
echo "✅ S3 CSI Driver setup complete!"

# Add S3 permissions to HyperPod IORole
echo ""
echo "🔧 Adding S3 permissions to HyperPod IORole..."

# Find the actual IORole name
HYPERPOD_IO_ROLE=$(aws iam list-roles --query "Roles[?contains(RoleName, '${CLUSTER_NAME}') && contains(RoleName, 'IORole')].RoleName" --output text | head -1)

if [ -z "$HYPERPOD_IO_ROLE" ]; then
    # Fallback: try without -eks suffix
    CLUSTER_ID=$(echo $CLUSTER_NAME | sed 's/-eks$//')
    HYPERPOD_IO_ROLE=$(aws iam list-roles --query "Roles[?contains(RoleName, '${CLUSTER_ID}') && contains(RoleName, 'IORole')].RoleName" --output text | head -1)
fi

if [ -z "$HYPERPOD_IO_ROLE" ]; then
    echo "⚠️  Warning: Could not find HyperPod IORole"
    echo "💡 You may need to add S3 permissions manually"
else
    echo "📍 HyperPod IORole: $HYPERPOD_IO_ROLE"

    cat > /tmp/hyperpod-s3-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:GetBucketLocation"
            ],
            "Resource": [
                "arn:aws:s3:::${S3_BUCKET}",
                "arn:aws:s3:::${S3_BUCKET}/*"
            ]
        }
    ]
}
EOF

    aws iam put-role-policy \
        --role-name $HYPERPOD_IO_ROLE \
        --policy-name HyperPodS3AccessPolicy \
        --policy-document file:///tmp/hyperpod-s3-policy.json

    if [ $? -eq 0 ]; then
        echo "✅ S3 permissions added to HyperPod IORole"
    else
        echo "⚠️  Warning: Failed to add S3 permissions to HyperPod IORole"
    fi

    rm -f /tmp/hyperpod-s3-policy.json
fi

echo ""
echo "✅ Setup complete!"
echo "⏳ Wait 1-2 minutes for pods to restart"
echo ""
echo "🔍 Check status:"
echo "   kubectl get pods -n kube-system | grep s3-csi"
echo ""
echo "➡️  Next step: ./3.prepare.sh"
