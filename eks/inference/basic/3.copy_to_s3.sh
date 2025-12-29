#!/bin/bash

# Set AWS profile (default: default)
PROFILE=${1:-default}

# Get AWS region
AWS_REGION=$(aws configure get region --profile $PROFILE)

# Check if S3_BUCKET environment variable is set
if [ -n "$S3_BUCKET" ]; then
    echo "🔍 Using existing S3_BUCKET environment variable: $S3_BUCKET"
    
    # Check if bucket exists
    if aws s3 ls "s3://$S3_BUCKET" --profile $PROFILE >/dev/null 2>&1; then
        echo "✅ S3 bucket exists: $S3_BUCKET"
        
        # Check if model already exists in bucket
        if aws s3 ls "s3://$S3_BUCKET/deepseek15b/" --profile $PROFILE >/dev/null 2>&1; then
            echo "✅ Model already exists in S3: s3://$S3_BUCKET/deepseek15b/"
            echo "📍 S3 Bucket: $S3_BUCKET"
            echo "📍 Model Path: s3://$S3_BUCKET/deepseek15b/"
            echo "🚀 Skipping copy - model is already available!"
            exit 0
        else
            echo "📦 Model not found in bucket. Copying model..."
            COPY_MODEL=true
        fi
    else
        echo "❌ S3 bucket does not exist: $S3_BUCKET"
        echo "Please create the bucket first or unset S3_BUCKET to create a new one"
        exit 1
    fi
else
    # Generate random suffix and create new bucket
    RANDOM_SUFFIX=$(openssl rand -hex 4)
    S3_BUCKET="hyperpod-inference-${RANDOM_SUFFIX}-${AWS_REGION}"
    export S3_BUCKET=$S3_BUCKET
    
    echo "🆕 Creating new S3 bucket: $S3_BUCKET"
    aws s3 mb s3://$S3_BUCKET --region $AWS_REGION --profile $PROFILE
    
    if [ $? -eq 0 ]; then
        echo "✅ S3 bucket created successfully: $S3_BUCKET"
        COPY_MODEL=true
    else
        echo "❌ Failed to create S3 bucket"
        exit 1
    fi
fi

# Copy model if needed
if [ "$COPY_MODEL" = true ]; then
    echo "📦 Copying model to S3 bucket..."
    
    aws s3 sync s3://jumpstart-cache-prod-us-east-2/deepseek-llm/deepseek-llm-r1-distill-qwen-1-5b/artifacts/inference-prepack/v2.0.0 \
      s3://$S3_BUCKET/deepseek15b/ --region $AWS_REGION --profile $PROFILE
    
    if [ $? -eq 0 ]; then
        echo "✅ Model copied successfully"
        echo "📍 S3 Bucket: $S3_BUCKET"
        echo "📍 Model Path: s3://$S3_BUCKET/deepseek15b/"
    else
        echo "❌ Failed to copy model"
        exit 1
    fi
fi
