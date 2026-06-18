#!/bin/bash

# Set AWS profile (default: default)
PROFILE=${1:-default}

echo "🚀 Preparing S3 Inference Deployment..."

# Only pass --profile if that profile actually exists; otherwise fall back to
# the ambient credentials (env vars / IAM role), as IAM-role-only environments
# such as SageMaker have no named credentials profile.
PROFILE_OPT=""
if aws configure list-profiles 2>/dev/null | grep -q "^${PROFILE}$"; then
    PROFILE_OPT="--profile $PROFILE"
fi

# Get AWS region and auto-detect instance type
if [ -z "$AWS_REGION" ]; then
    AWS_REGION=$(aws configure get region $PROFILE_OPT 2>/dev/null)
fi
# Auto-detect instance type from a READY, labelled node (env override allowed).
# .items[0] alone is fragile: during node replacement the first node may be
# NotReady/unlabelled and silently yield an empty value.
if [ -z "${INSTANCE_TYPE:-}" ]; then
    INSTANCE_TYPE=$(kubectl get nodes \
        -l node.kubernetes.io/instance-type \
        -o jsonpath='{range .items[*]}{.metadata.labels.node\.kubernetes\.io/instance-type}{"\n"}{end}' 2>/dev/null \
        | grep -v '^$' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
fi

if [ -z "$AWS_REGION" ]; then
    echo "❌ AWS_REGION is not set. Set it in ../../setup/env_vars, the AWS profile, or export AWS_REGION."
    exit 1
fi

# Fail loudly instead of guessing — a wrong instance type yields wrong
# cpu/memory requests and an unschedulable pod.
if [ -z "$INSTANCE_TYPE" ]; then
    echo "❌ [ERROR] Could not auto-detect the node instance type."
    echo "   'kubectl get nodes' returned no labelled node. Common causes:"
    echo "     • AWS credentials expired → kubectl is Unauthorized"
    echo "       (check: kubectl get nodes ; aws sts get-caller-identity)"
    echo "     • nodes are still provisioning / NotReady"
    echo "   Fix the access, or pin the type explicitly:"
    echo "     INSTANCE_TYPE=ml.g5.2xlarge ./5a.prepare_s3_inference_operator.sh"
    exit 1
fi
echo "✅ Instance type: $INSTANCE_TYPE"

# Check if S3_BUCKET_NAME environment variable is set
if [ -z "$S3_BUCKET_NAME" ]; then
    echo "❌ S3_BUCKET_NAME environment variable is not set!"
    echo "Please run 3.copy_to_s3.sh first to create and populate S3 bucket"
    echo "Or set S3_BUCKET_NAME manually: export S3_BUCKET_NAME=your-bucket-name"
    exit 1
fi

echo "🔍 Using S3 bucket: $S3_BUCKET_NAME"

# Verify bucket exists and has model
if ! aws s3 ls "s3://$S3_BUCKET_NAME/deepseek15b/" $PROFILE_OPT >/dev/null 2>&1; then
    echo "❌ Model not found in S3 bucket: s3://$S3_BUCKET_NAME/deepseek15b/"
    echo "Please run 3.copy_to_s3.sh first to copy the model"
    exit 1
fi

echo "✅ Model found in S3 bucket"

# Create deployment file from template
echo "📝 Creating deployment configuration..."
cp template/deploy_S3_inference_operator_template.yaml deploy_S3_inference_operator.yaml

# Replace placeholders
# Detect OS and use appropriate sed syntax
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    sed -i '' "s|<YOUR_INSTANCE_TYPE>|$INSTANCE_TYPE|g" deploy_S3_inference_operator.yaml
    sed -i '' "s|<YOUR_S3_BUCKET_NAME>|$S3_BUCKET_NAME|g" deploy_S3_inference_operator.yaml
    sed -i '' "s|<YOUR_REGION>|$AWS_REGION|g" deploy_S3_inference_operator.yaml
else
    # Linux
    sed -i "s|<YOUR_INSTANCE_TYPE>|$INSTANCE_TYPE|g" deploy_S3_inference_operator.yaml
    sed -i "s|<YOUR_S3_BUCKET_NAME>|$S3_BUCKET_NAME|g" deploy_S3_inference_operator.yaml
    sed -i "s|<YOUR_REGION>|$AWS_REGION|g" deploy_S3_inference_operator.yaml
fi

echo "✅ Deployment file created successfully!"
echo "📍 Instance Type: $INSTANCE_TYPE"
echo "📍 S3 Bucket: $S3_BUCKET_NAME"
echo "📍 Region: $AWS_REGION"
echo "📍 Output file: deploy_S3_inference_operator.yaml"
echo ""
echo "🚀 To deploy: kubectl apply -f deploy_S3_inference_operator.yaml"
