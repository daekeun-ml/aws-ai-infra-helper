#!/bin/bash
set -e

echo "🚀 Preparing S3 Direct Deployment"
echo ""

# Load environment variables
if [ ! -f "../../setup/env_vars" ]; then
    echo "❌ Cannot find env_vars file."
    exit 1
fi

source ../../setup/env_vars

echo "📍 Region: $AWS_REGION"
echo "📍 S3 Bucket: $S3_BUCKET_NAME"

# 1. Check if model exists in S3
echo ""
echo "🔍 Checking model in S3 bucket..."
if ! aws s3 ls "s3://$S3_BUCKET_NAME/deepseek15b/" --region $AWS_REGION >/dev/null 2>&1; then
    echo "❌ Model not found in S3. Please run 3.copy_to_s3.sh first."
    exit 1
fi
echo "✅ Model found"

# 2. Add S3 permissions to node IAM role
echo ""
echo "🔧 Adding S3 permissions to node IAM role..."
NODE_ROLE=$(kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' | cut -d'/' -f2 | xargs aws ec2 describe-instances --instance-ids --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text --region $AWS_REGION 2>/dev/null | cut -d'/' -f2)

if [ -z "$NODE_ROLE" ]; then
    # Fallback: Use default HyperPod role
    NODE_ROLE="sagemaker-hyperpod-eks-SMHP-Exec-Role-$AWS_REGION"
fi

echo "📍 Node Role: $NODE_ROLE"
aws iam attach-role-policy --role-name $NODE_ROLE --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess 2>/dev/null || echo "Policy already attached"
echo "✅ S3 permissions added"

# 3. Create S3 CSI StorageClass
echo ""
echo "🔧 Creating S3 CSI StorageClass..."
kubectl apply -f - <<EOF >/dev/null 2>&1
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: s3-csi
provisioner: s3.csi.aws.com
parameters:
  bucketName: $S3_BUCKET
  prefix: deepseek15b/
mountOptions:
  - allow-delete
  - region $AWS_REGION
EOF
echo "✅ StorageClass created"

# 4. Create deploy_S3_direct.yaml from template
echo ""
echo "📝 Creating deploy_S3_direct.yaml..."

cp template/deploy_S3_direct_template.yaml deploy_S3_direct.yaml

# macOS and Linux compatible sed
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    sed -i '' "s|<YOUR_REGION>|$AWS_REGION|g" deploy_S3_direct.yaml
    sed -i '' "s|<YOUR_S3_BUCKET_NAME>|$S3_BUCKET_NAME|g" deploy_S3_direct.yaml
else
    # Linux
    sed -i "s|<YOUR_REGION>|$AWS_REGION|g" deploy_S3_direct.yaml
    sed -i "s|<YOUR_S3_BUCKET_NAME>|$S3_BUCKET_NAME|g" deploy_S3_direct.yaml
fi

echo "✅ deploy_S3_direct.yaml created"

echo ""
echo "🎉 Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Deploy: kubectl apply -f deploy_S3_direct.yaml"
echo "  2. Check status: kubectl get pods -w"
echo "  3. Check pod details: kubectl describe pod -l app=deepseek15b"
echo "  4. Check logs: kubectl logs -l app=deepseek15b -f"
echo "  5. Wait for 'Running' status (1/1 Ready)"
echo ""
echo "Test inference:"
echo "  kubectl exec -it deployment/deepseek15b -- curl -X POST http://localhost:8080/invocations \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"inputs\": \"Explain machine learning in simple terms.\", \"parameters\": {\"max_new_tokens\": 200, \"temperature\": 0.7, \"repetition_penalty\": 1.5}}'"
