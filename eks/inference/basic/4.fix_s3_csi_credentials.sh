#!/bin/bash

# One-step script to fix S3 CSI Driver credentials issue

set -e

echo "🔧 Fixing S3 CSI Driver credentials issue..."

# Step 0: Check if S3 CSI Driver needs reinstallation
echo "🔍 Checking S3 CSI Driver status..."

# Check if driver pods are running
DRIVER_PODS_READY=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver --no-headers 2>/dev/null | grep -c "Running" || echo "0")
DRIVER_PODS_TOTAL=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver --no-headers 2>/dev/null | wc -l || echo "0")

# Check for CSI driver registration
CSI_DRIVER_EXISTS=$(kubectl get csidriver s3.csi.aws.com 2>/dev/null && echo "1" || echo "0")

# Check for recent mount failures in logs
MOUNT_FAILURES=$(kubectl logs -n mount-s3 --tail=20 -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver 2>/dev/null | grep -c "Failed to create S3 client\|No signing credentials" || echo "0")

if [ "$DRIVER_PODS_READY" -eq "0" ] || [ "$CSI_DRIVER_EXISTS" -eq "0" ] || [ "$MOUNT_FAILURES" -gt "0" ]; then
    echo "⚠️  S3 CSI Driver issues detected. Reinstalling..."
    echo "   - Ready pods: $DRIVER_PODS_READY/$DRIVER_PODS_TOTAL"
    echo "   - CSI driver registered: $CSI_DRIVER_EXISTS"
    echo "   - Mount failures: $MOUNT_FAILURES"
    
    kubectl delete daemonset s3-csi-node -n kube-system 2>/dev/null || echo "DaemonSet not found, skipping..."
    kubectl delete csidriver s3.csi.aws.com 2>/dev/null || echo "CSIDriver not found, skipping..."
    kubectl apply -k "https://github.com/awslabs/mountpoint-s3-csi-driver/deploy/kubernetes/overlays/stable/?ref=main"
    
    echo "⏳ Waiting for S3 CSI Driver to be ready..."
    sleep 10
else
    echo "✅ S3 CSI Driver appears to be running correctly. Skipping reinstall."
fi

# Configuration variables
if [ -n "$CLUSTER_NAME" ]; then
    echo "🔍 Using CLUSTER_NAME environment variable: $CLUSTER_NAME"
elif [ -n "$1" ]; then
    CLUSTER_NAME="$1"
    echo "🔍 Using cluster name from argument: $CLUSTER_NAME"
else
    echo "❌ CLUSTER_NAME not provided!"
    echo ""
    echo "Usage: $0 <cluster-name>"
    echo "Example: $0 sagemaker-hyperpod-cluster-g5-eks-ohio-69ccd5cc-eks"
    echo ""
    echo "Or set environment variable:"
    echo "export CLUSTER_NAME=sagemaker-hyperpod-cluster-g5-eks-ohio-69ccd5cc-eks"
    echo "$0"
    echo ""
    echo "💡 Find your EKS cluster name:"
    echo "   aws eks list-clusters --query 'clusters[]' --output table"
    exit 1
fi

# Auto-detect region from AWS CLI config or kubectl context
REGION=$(aws configure get region 2>/dev/null || kubectl config current-context | grep -o 'us-[a-z]*-[0-9]' || echo "us-east-2")

# Check _NAME environment variable
if [ -z "$S3_BUCKET_NAME" ]; then
    echo "❌ S3_BUCKET_NAME environment variable is not set!"
    echo "Please run 3.copy_to_s3.sh first to set S3_BUCKET_NAME"
    echo "Or set it manually: export S3_BUCKET_NAME=your-bucket-name"
    exit 1
fi

ROLE_NAME="AmazonEKS_S3_CSI_DriverRole"
POLICY_NAME="AmazonS3CSIDriverPolicy"

echo "📍 Region: $REGION"
echo "🪣 Bucket: $S3_BUCKET_NAME"

# 1. Get AWS Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "✅ AWS Account ID: $ACCOUNT_ID"

# 2. Create IAM policy for S3 access
echo "📝 Checking IAM policy..."
if aws iam get-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME} >/dev/null 2>&1; then
    echo "✅ IAM policy already exists: $POLICY_NAME"
else
    echo "🆕 Creating IAM policy: $POLICY_NAME"
    cat > s3-csi-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject"
            ],
            "Resource": [
                "arn:aws:s3:::${S3_BUCKET_NAME}",
                "arn:aws:s3:::${S3_BUCKET_NAME}/*"
            ]
        }
    ]
}
EOF

    aws iam create-policy \
        --policy-name $POLICY_NAME \
        --policy-document file://s3-csi-policy.json \
        --region $REGION
    
    if [ $? -eq 0 ]; then
        echo "✅ IAM policy created successfully"
    else
        echo "❌ Failed to create IAM policy"
        exit 1
    fi
fi

# 3. Create trust policy and IAM role
echo "👤 Checking IAM role..."
if aws iam get-role --role-name $ROLE_NAME >/dev/null 2>&1; then
    echo "✅ IAM role already exists: $ROLE_NAME"
else
    echo "🆕 Creating IAM role: $ROLE_NAME"
    
    # Create trust policy for OIDC
    echo "🔐 Creating trust policy..."
    OIDC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query "cluster.identity.oidc.issuer" --output text | cut -d '/' -f 5)

    cat > trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:kube-system:s3-csi-driver-sa",
                    "oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com"
                }
            }
        }
    ]
}
EOF

    aws iam create-role \
        --role-name $ROLE_NAME \
        --assume-role-policy-document file://trust-policy.json \
        --region $REGION
    
    if [ $? -eq 0 ]; then
        echo "✅ IAM role created successfully"
    else
        echo "❌ Failed to create IAM role"
        exit 1
    fi
fi

# 4. Attach policy to role (check if already attached)
echo "🔗 Checking policy attachment..."
if aws iam list-attached-role-policies --role-name $ROLE_NAME --query "AttachedPolicies[?PolicyName=='$POLICY_NAME']" --output text | grep -q "$POLICY_NAME"; then
    echo "✅ Policy already attached to role"
else
    echo "🔗 Attaching policy to role..."
    aws iam attach-role-policy \
        --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME} \
        --role-name $ROLE_NAME \
        --region $REGION
    
    if [ $? -eq 0 ]; then
        echo "✅ Policy attached successfully"
    else
        echo "❌ Failed to attach policy"
        exit 1
    fi
fi

# 5. Check and update ServiceAccount annotation
echo "🏷️  Checking ServiceAccount annotation..."
CURRENT_ROLE_ARN=$(kubectl get serviceaccount s3-csi-driver-sa -n kube-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
EXPECTED_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

if [ "$CURRENT_ROLE_ARN" = "$EXPECTED_ROLE_ARN" ]; then
    echo "✅ ServiceAccount already has correct IAM role annotation"
    NEED_RESTART=false
else
    echo "🔄 Adding IAM role annotation to ServiceAccount..."
    kubectl annotate serviceaccount s3-csi-driver-sa -n kube-system \
        eks.amazonaws.com/role-arn=$EXPECTED_ROLE_ARN \
        --overwrite
    echo "✅ ServiceAccount annotation updated"
    NEED_RESTART=true
fi

# 6. Restart pods only if needed
if [ "$NEED_RESTART" = true ]; then
    echo "🔄 Restarting S3 CSI driver pods to apply changes..."
    kubectl delete pods -n kube-system -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver
    kubectl delete pods -n mount-s3 --all
    echo "✅ Pods restarted"
else
    echo "✅ No pod restart needed"
fi

# 7. Clean up temporary files (only if they exist)
if [ -f "s3-csi-policy.json" ] || [ -f "trust-policy.json" ]; then
    echo "🧹 Cleaning up temporary files..."
    rm -f s3-csi-policy.json trust-policy.json
fi

echo "✅ Done! S3 CSI Driver credentials configuration completed."

if [ "$NEED_RESTART" = true ]; then
    echo "📋 Pods have been restarted. Check status in a few minutes:"
    echo "   kubectl get pods -n kube-system | grep s3-csi"
    echo "   kubectl get pods -n mount-s3"
else
    echo "📋 No changes were needed. Current status:"
    echo "   kubectl get pods -n kube-system | grep s3-csi"
fi
