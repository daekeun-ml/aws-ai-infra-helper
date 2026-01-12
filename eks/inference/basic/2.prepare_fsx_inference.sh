#!/bin/bash

# Set AWS profile (default: default)
PROFILE=${1:-default}

echo "🚀 Starting FSX Inference Deployment..."

# Step 1: Update environment variables for FSX copy job
echo "📝 Step 1: Setting up FSX copy job..."

# Extract AWS credentials
AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id --profile $PROFILE)
AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key --profile $PROFILE)
AWS_DEFAULT_REGION=$(aws configure get region --profile $PROFILE)

# Create FSX copy job configuration
echo "🔧 Creating FSX copy job configuration..."
cp template/copy_to_fsx_lustre_template.yaml copy_to_fsx_lustre.yaml

# Replace placeholders in copy job
# Detect OS and use appropriate sed syntax
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    sed -i '' "s|<YOUR_ACCESS_KEY_ID>|$AWS_ACCESS_KEY_ID|g" copy_to_fsx_lustre.yaml
    sed -i '' "s|<YOUR_SECRET_ACCESS_KEY>|$AWS_SECRET_ACCESS_KEY|g" copy_to_fsx_lustre.yaml
    sed -i '' "s|<YOUR_AWS_REGION>|$AWS_DEFAULT_REGION|g" copy_to_fsx_lustre.yaml
else
    # Linux
    sed -i "s|<YOUR_ACCESS_KEY_ID>|$AWS_ACCESS_KEY_ID|g" copy_to_fsx_lustre.yaml
    sed -i "s|<YOUR_SECRET_ACCESS_KEY>|$AWS_SECRET_ACCESS_KEY|g" copy_to_fsx_lustre.yaml
    sed -i "s|<YOUR_AWS_REGION>|$AWS_DEFAULT_REGION|g" copy_to_fsx_lustre.yaml
fi

echo "✅ FSX copy job configuration created: copy_to_fsx_lustre.yaml"

# Step 2: Create inference deployment
echo "📝 Step 2: Setting up inference deployment..."

# Auto-detect instance type from EKS cluster
echo "🔍 Auto-detecting instance type from EKS cluster..."
INSTANCE_TYPE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null)

# Auto-detect FSX filesystem ID from PV
echo "🔍 Auto-detecting FSX filesystem ID from PV..."
FSX_FILESYSTEM=$(kubectl get pv fsx-pv -o yaml 2>/dev/null | grep -A5 "csi:" | grep "volumeHandle:" | awk '{print $2}')

# Check if we got the instance type
if [ -z "$INSTANCE_TYPE" ]; then
    echo "⚠️  Warning: Could not auto-detect instance type from EKS cluster"
    INSTANCE_TYPE="ml.g5.2xlarge"
    echo "Using default instance type: $INSTANCE_TYPE"
fi

# Check if we got the FSX filesystem ID
if [ -z "$FSX_FILESYSTEM" ]; then
    echo "❌ Error: Could not auto-detect FSX filesystem ID from PV 'fsx-pv'"
    echo "Please check if PV 'fsx-pv' exists: kubectl get pv fsx-pv"
    exit 1
fi

# Create inference deployment configuration
echo "🔧 Creating inference deployment configuration..."
cp template/deploy_fsx_lustre_inference_operator_template.yaml deploy_fsx_lustre_inference_operator.yaml

# Replace placeholders in inference deployment
# Detect OS and use appropriate sed syntax
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    sed -i '' "s|<YOUR_INSTANCE_TYPE>|$INSTANCE_TYPE|g" deploy_fsx_lustre_inference_operator.yaml
    sed -i '' "s|<YOUR_FSX_FILESYSTEM>|$FSX_FILESYSTEM|g" deploy_fsx_lustre_inference_operator.yaml
else
    # Linux
    sed -i "s|<YOUR_INSTANCE_TYPE>|$INSTANCE_TYPE|g" deploy_fsx_lustre_inference_operator.yaml
    sed -i "s|<YOUR_FSX_FILESYSTEM>|$FSX_FILESYSTEM|g" deploy_fsx_lustre_inference_operator.yaml
fi

echo "✅ Inference deployment configuration created: deploy_fsx_lustre_inference_operator.yaml"

# Step 3: Deployment instructions
echo ""
echo "🎯 Deployment Summary:"
echo "📍 AWS Profile: $PROFILE"
echo "📍 AWS Region: $AWS_DEFAULT_REGION"
echo "📍 Instance Type: $INSTANCE_TYPE"
echo "📍 FSX Filesystem: $FSX_FILESYSTEM"
echo ""
echo "📋 Next Steps:"
echo "1. Copy model to FSX (if not done already):"
echo "   kubectl apply -f copy_to_fsx_lustre.yaml"
echo ""
echo "2. Wait for copy job to complete:"
echo "   kubectl get jobs -w"
echo ""
echo "3. Deploy inference service:"
echo "   kubectl apply -f deploy_fsx_lustre_inference_operator.yaml"
echo ""
echo "4. Check deployment status:"
echo "   kubectl get pods -w"
echo ""
echo "✅ All configuration files ready!"
