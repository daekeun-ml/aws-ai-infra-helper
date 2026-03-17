#!/bin/bash

# HyperPod Cluster Connection Script 🚀
# Connects to SageMaker HyperPod cluster login node via SSM

show_usage() {
    echo "🔗 HyperPod Cluster Connection Tool via SSM"
    echo ""
    echo "Usage: $0 <region> <cluster-name> [login-group-name]"
    echo ""
    echo "Arguments:"
    echo "  region            AWS region where the cluster is located (e.g., us-west-2)"
    echo "  cluster-name      Name of the HyperPod cluster"
    echo "  login-group-name  (Optional) Specific login instance group name"
    echo ""
    echo "Examples:"
    echo "  $0 us-west-2 my-hyperpod-cluster"
    echo "  $0 ap-northeast-1 training-cluster my-login-group"
    echo ""
    echo "How it works:"
    echo "  - Automatically finds instance groups containing 'login' in the name"
    echo "  - If multiple login groups exist, uses the first one found"
    echo "  - If no login group found, specify the exact group name as 3rd argument"
    echo ""
    echo "Requirements:"
    echo "  - AWS CLI configured with appropriate permissions"
    echo "  - jq (will be auto-installed if missing)"
    echo "  - SSM plugin for AWS CLI"
}

# Check and install jq if needed
check_and_install_jq() {
    if ! command -v jq &> /dev/null; then
        echo "📦 jq not found. Installing..."
        
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS
            if [[ $(uname -m) == "arm64" ]]; then
                echo "🍎 Detected Apple Silicon Mac"
            else
                echo "🍎 Detected Intel Mac"
            fi
            
            if command -v brew &> /dev/null; then
                brew install jq
            else
                echo "❌ Homebrew not found. Please install Homebrew first:"
                echo '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
                exit 1
            fi
        elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
            # Linux
            echo "🐧 Detected Linux"
            if command -v apt-get &> /dev/null; then
                sudo apt-get update && sudo apt-get install -y jq
            elif command -v yum &> /dev/null; then
                sudo yum install -y jq
            elif command -v dnf &> /dev/null; then
                sudo dnf install -y jq
            else
                echo "❌ Package manager not found. Please install jq manually."
                exit 1
            fi
        else
            echo "❌ Unsupported OS. Please install jq manually."
            exit 1
        fi
        
        echo "✅ jq installed successfully."
    fi
}

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    show_usage
    exit 1
fi

# Check and install jq
check_and_install_jq

REGION=$1
CLUSTER_NAME=$2
SPECIFIC_LOGIN_GROUP=$3

echo "🔍 Retrieving cluster information..."

# Get cluster ID
CLUSTER_ARN=$(aws sagemaker describe-cluster --cluster-name "$CLUSTER_NAME" --query 'ClusterArn' --output text --region "$REGION" 2>&1)
if echo "$CLUSTER_ARN" | grep -qi "error\|invalid\|not found"; then
    echo "❌ Failed to describe cluster: $CLUSTER_ARN"
    exit 1
fi
CLUSTER_ID=$(echo "$CLUSTER_ARN" | cut -d'/' -f2)

# Get all cluster nodes and find login node
echo "🔍 Finding login node..."
ALL_NODES=$(aws sagemaker list-cluster-nodes --cluster-name "$CLUSTER_NAME" --region "$REGION" 2>&1)
if echo "$ALL_NODES" | grep -qi "error\|invalid"; then
    echo "❌ Failed to list cluster nodes: $ALL_NODES"
    exit 1
fi

if [ -n "$SPECIFIC_LOGIN_GROUP" ]; then
    # Use specific login group if provided
    LOGIN_INFO=$(echo "$ALL_NODES" | jq -r --arg group "$SPECIFIC_LOGIN_GROUP" '[.ClusterNodeSummaries[] | select(.InstanceGroupName == $group)] | first // empty')
    if [ -z "$LOGIN_INFO" ]; then
        echo "❌ Specified login group '$SPECIFIC_LOGIN_GROUP' not found"
        echo "Available instance groups:"
        echo "$ALL_NODES" | jq -r '[.ClusterNodeSummaries[].InstanceGroupName] | unique[]'
        exit 1
    fi
else
    # Find the first node with "login" in the instance group name (case insensitive)
    LOGIN_INFO=$(echo "$ALL_NODES" | jq -r '[.ClusterNodeSummaries[] | select(.InstanceGroupName | ascii_downcase | contains("login"))] | first // empty')

    if [ -z "$LOGIN_INFO" ]; then
        echo "❌ No login node found in cluster $CLUSTER_NAME"
        echo "Available instance groups:"
        echo "$ALL_NODES" | jq -r '[.ClusterNodeSummaries[].InstanceGroupName] | unique[]'
        echo ""
        echo "💡 Try specifying the login group name:"
        echo "   $0 $REGION $CLUSTER_NAME <login-group-name>"
        exit 1
    fi
fi

NODE_GROUP=$(echo "$LOGIN_INFO" | jq -r '.InstanceGroupName')
INSTANCE_ID=$(echo "$LOGIN_INFO" | jq -r '.InstanceId')

# Output info
echo "📍 Region: $REGION"
echo "🏷️  Cluster Name: $CLUSTER_NAME"
echo "🆔 Cluster ID: $CLUSTER_ID"
echo "👥 Node Group: $NODE_GROUP"
echo "💻 Instance ID: $INSTANCE_ID"
echo ""

# Start SSM session with ubuntu user
TARGET="sagemaker-cluster:${CLUSTER_ID}_${NODE_GROUP}-${INSTANCE_ID}"
echo "🚀 Starting SSM session to: $TARGET (as ubuntu user)"
aws ssm start-session \
  --target "$TARGET" \
  --region "$REGION" \
  --document-name AWS-StartInteractiveCommand \
  --parameters command="sudo su - ubuntu"
