#!/bin/bash

# Cleanup script for SageMaker HyperPod inference endpoint
# Usage: ./cleanup.sh

NAMESPACE="default"
NAME="demo"
CONFIG_FILE="inference_endpoint_config.yaml"

echo "🗑️  Deleting SageMaker HyperPod inference endpoint..."

# Delete InferenceEndpointConfig
if kubectl get inferenceendpointconfig $NAME -n $NAMESPACE >/dev/null 2>&1; then
    echo "📝 Deleting InferenceEndpointConfig..."
    kubectl delete inferenceendpointconfig $NAME -n $NAMESPACE
    echo "✅ InferenceEndpointConfig deleted"
elif [ -f "$CONFIG_FILE" ]; then
    echo "📄 Deleting resources via YAML file..."
    kubectl delete -f $CONFIG_FILE 2>/dev/null || echo "ℹ️  Resources already deleted"
else
    echo "ℹ️  InferenceEndpointConfig does not exist"
fi

echo ""
echo "🔍 Status after cleanup:"
kubectl get pods -n $NAMESPACE 2>/dev/null || echo "No pods found"
echo ""
kubectl get inferenceendpointconfig -n $NAMESPACE 2>/dev/null || echo "No inferenceendpointconfig found"

# Delete S3 bucket if S3_BUCKET is set
if [ -n "$S3_BUCKET" ]; then
    echo ""
    echo "🪣 Deleting S3 bucket: $S3_BUCKET"
    REGION=$(aws configure get region 2>/dev/null || echo "us-west-2")
    
    aws s3 rb s3://$S3_BUCKET --force --region $REGION
    
    if [ $? -eq 0 ]; then
        echo "✅ S3 bucket deleted"
    else
        echo "⚠️  Failed to delete S3 bucket (may not exist or insufficient permissions)"
    fi
else
    echo ""
    echo "ℹ️  S3_BUCKET not set, skipping bucket deletion"
    echo "💡 To delete bucket: export S3_BUCKET=your-bucket-name && ./cleanup.sh"
fi

echo ""
echo "✅ Cleanup complete!"
