#!/bin/bash

# Load environment variables
if [ ! -f env_vars ]; then
    echo "❌ [ERROR] env_vars file not found. Run create_config.sh first."
    exit 1
fi
source env_vars

# Get current user ARN
echo "🔍 Checking current user..."
USER_ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)
if [ -z "${USER_ARN}" ]; then
    echo "❌ [ERROR] Failed to get current user ARN"
    exit 1
fi

echo "✅ Current user: ${USER_ARN}"

# Convert assumed-role ARN to role ARN for EKS access
if [[ "${USER_ARN}" == *":assumed-role/"* ]]; then
    ROLE_NAME=$(echo "${USER_ARN}" | sed "s/.*:assumed-role\/\([^\/]*\).*/\1/")
    USER_ARN="arn:aws:iam::$(echo "${USER_ARN}" | cut -d: -f5):role/${ROLE_NAME}"
    echo "🔄 Converted to role ARN: ${USER_ARN}"
fi
echo "📦 EKS Cluster: ${EKS_CLUSTER_NAME}"
echo ""

# Create access entry
echo "🔐 Checking EKS access entry..."
if aws eks describe-access-entry --cluster-name ${EKS_CLUSTER_NAME} --principal-arn ${USER_ARN} --region ${AWS_REGION} &>/dev/null; then
    echo "✅ Access entry already exists"
else
    echo "Creating new access entry..."
    aws eks create-access-entry \
      --cluster-name ${EKS_CLUSTER_NAME} \
      --principal-arn ${USER_ARN} \
      --region ${AWS_REGION}
    echo "✅ Access entry created"
fi
echo ""

# Associate admin policy
echo "👑 Checking cluster admin policy..."
if aws eks list-associated-access-policies --cluster-name ${EKS_CLUSTER_NAME} --principal-arn ${USER_ARN} --region ${AWS_REGION} --query 'associatedAccessPolicies[?policyArn==`arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy`]' --output text | grep -q "AmazonEKSClusterAdminPolicy"; then
    echo "✅ Admin policy already associated"
else
    echo "Associating admin policy..."
    aws eks associate-access-policy \
      --cluster-name ${EKS_CLUSTER_NAME} \
      --principal-arn ${USER_ARN} \
      --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
      --access-scope type=cluster \
      --region ${AWS_REGION}
    echo "✅ Admin policy associated"
fi
echo ""

# Update kubeconfig
echo "⚙️  Updating kubeconfig..."
aws eks update-kubeconfig --name ${EKS_CLUSTER_NAME} --region ${AWS_REGION}
echo "✅ Kubeconfig updated"
echo ""

# Check and install kubectl if needed
echo "🔧 Checking kubectl installation..."
if ! command -v kubectl &> /dev/null; then
    echo "⚠️  kubectl not found, installing..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
    if command -v kubectl &> /dev/null; then
        echo "✅ kubectl installed successfully"
    else
        echo "❌ kubectl installation failed"
        exit 1
    fi
else
    echo "✅ kubectl is already installed"
fi
echo ""

# Test kubectl access
echo "🧪 Testing kubectl access..."
if kubectl get nodes &>/dev/null; then
    echo "✅ kubectl access verified!"
    kubectl get nodes
    echo ""
else
    echo "❌ kubectl access test failed"
    exit 1
fi

# Test helm access
echo "⏳ Waiting for EKS permissions to propagate..."
sleep 15
echo "🎡 Testing helm access..."
if helm list -n kube-system &>/dev/null; then
    echo "✅ helm access verified!"
    helm list -n kube-system
    echo ""
else
    echo "❌ helm access test failed"
    exit 1
fi

# Check health monitoring agent
echo "🏥 Checking health monitoring agent..."
kubectl get ds health-monitoring-agent -n aws-hyperpod
echo ""

echo "🎉 EKS access configured successfully!"
