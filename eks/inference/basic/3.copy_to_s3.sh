#!/bin/bash

# Load environment variables
if [ -f "../../setup/env_vars" ]; then
    source ../../setup/env_vars
    echo "✅ Loaded environment variables from ../../setup/env_vars"
fi

# Set AWS profile (default: default)
PROFILE=${1:-default}

# Check if profile exists
PROFILE_OPT=""
if aws configure list-profiles 2>/dev/null | grep -q "^${PROFILE}$"; then
    PROFILE_OPT="--profile $PROFILE"
fi

# Get AWS region (try env var first, then AWS profile)
if [ -z "$AWS_REGION" ]; then
    AWS_REGION=$(aws configure get region $PROFILE_OPT 2>/dev/null)
fi

if [ -z "$AWS_REGION" ]; then
    echo "❌ AWS_REGION is not set. Please set it in ../../setup/env_vars or AWS profile"
    exit 1
fi

echo "🌍 Using AWS Region: $AWS_REGION"

# Check if S3_BUCKET_NAME environment variable is set
if [ -n "$S3_BUCKET_NAME" ]; then
    echo "🔍 Using existing S3_BUCKET_NAME environment variable: $S3_BUCKET_NAME"
    
    # Check if bucket exists
    if aws s3 ls "s3://$S3_BUCKET_NAME" $PROFILE_OPT >/dev/null 2>&1; then
        echo "✅ S3 bucket exists: $S3_BUCKET_NAME"
        
        # Check if model already exists in bucket
        if aws s3 ls "s3://$S3_BUCKET_NAME/deepseek15b/" $PROFILE_OPT >/dev/null 2>&1; then
            echo "✅ Model already exists in S3: s3://$S3_BUCKET_NAME/deepseek15b/"
            echo "📍 S3 Bucket: $S3_BUCKET_NAME"
            echo "📍 Model Path: s3://$S3_BUCKET_NAME/deepseek15b/"
            echo "🚀 Skipping copy - model is already available!"
            exit 0
        else
            echo "📦 Model not found in bucket. Copying model..."
            COPY_MODEL=true
        fi
    else
        echo "❌ S3 bucket does not exist: $S3_BUCKET_NAME"
        echo "Please create the bucket first or unset S3_BUCKET_NAME to create a new one"
        exit 1
    fi
else
    # Generate random suffix and create new bucket
    RANDOM_SUFFIX=$(openssl rand -hex 4)
    S3_BUCKET_NAME="hyperpod-inference-${RANDOM_SUFFIX}-${AWS_REGION}"
    export S3_BUCKET_NAME
    
    echo "🆕 Creating new S3 bucket: $S3_BUCKET_NAME"
    aws s3 mb s3://$S3_BUCKET_NAME --region $AWS_REGION $PROFILE_OPT
    
    if [ $? -eq 0 ]; then
        echo "✅ S3 bucket created successfully: $S3_BUCKET_NAME"
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
      s3://$S3_BUCKET_NAME/deepseek15b/ --region $AWS_REGION $PROFILE_OPT
    
    if [ $? -eq 0 ]; then
        echo "✅ Model copied successfully"
        echo "📍 S3 Bucket: $S3_BUCKET_NAME"
        echo "📍 Model Path: s3://$S3_BUCKET_NAME/deepseek15b/"
    else
        echo "❌ Failed to copy model"
        exit 1
    fi
fi
