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
INSTANCE_TYPE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null)

if [ -z "$AWS_REGION" ]; then
    echo "❌ AWS_REGION is not set. Set it in ../../setup/env_vars, the AWS profile, or export AWS_REGION."
    exit 1
fi

# Check if we got the instance type
if [ -z "$INSTANCE_TYPE" ]; then
    echo "⚠️  Warning: Could not auto-detect instance type from EKS cluster"
    INSTANCE_TYPE="ml.g5.8xlarge"
    echo "Using default instance type: $INSTANCE_TYPE"
fi

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
