#!/bin/bash

# Set AWS profile (default: default)
PROFILE=${1:-default}

# Get AWS region
AWS_REGION=$(aws configure get region --profile $PROFILE)

# Get current AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --profile $PROFILE)

# Generate random suffix and create new bucket
RANDOM_SUFFIX=$(openssl rand -hex 4)
S3_BUCKET="hyperpod-inference-${RANDOM_SUFFIX}-${AWS_REGION}"

echo "🆕 Creating new S3 bucket: $S3_BUCKET"
aws s3 mb s3://$S3_BUCKET --region $AWS_REGION --profile $PROFILE

if [ $? -eq 0 ]; then
    echo "✅ S3 bucket created successfully: $S3_BUCKET"
    
    # Save to file for other scripts
    echo "export S3_BUCKET=$S3_BUCKET" > .s3_bucket_env
    
    COPY_MODEL=true
else
    echo "❌ Failed to create S3 bucket"
    exit 1
fi

# Copy model if needed
if [ "$COPY_MODEL" = true ]; then
    echo ""
    echo "📦 Copying model to S3 bucket..."
    
    aws s3 sync s3://jumpstart-cache-prod-us-east-2/deepseek-llm/deepseek-llm-r1-distill-qwen-7b/artifacts/inference/v2.0.0/ \
      s3://$S3_BUCKET/deepseek7b/ --region $AWS_REGION --profile $PROFILE
    
    if [ $? -eq 0 ]; then
        echo "✅ Model copied successfully"
        echo ""
        echo "📍 S3 Bucket: $S3_BUCKET"
        echo "📍 Model Path: s3://$S3_BUCKET/deepseek7b/"
        echo ""
        echo "➡️  Next step: ./2.setup_s3_csi.sh"
    else
        echo "❌ Failed to copy model"
        exit 1
    fi
fi
