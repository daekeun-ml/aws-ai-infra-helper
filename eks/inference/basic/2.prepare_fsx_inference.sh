#!/bin/bash

# Set AWS profile (default: default)
PROFILE=${1:-default}

echo "🚀 Starting FSX Inference Deployment..."

# Auto-detect FSX filesystem ID if not set
if [ -z "$FSX_FILESYSTEM_ID" ]; then
    echo "🔍 Auto-detecting FSX filesystem ID..."
    FSX_FILESYSTEM_ID=$(kubectl get pv fsx-pv -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null)
    if [ -n "$FSX_FILESYSTEM_ID" ]; then
        echo "✅ Auto-detected FSX ID: $FSX_FILESYSTEM_ID"
        export FSX_FILESYSTEM_ID
    fi
fi

# Step 1: Update environment variables for FSX copy job
echo "📝 Step 1: Setting up FSX copy job..."

# Extract AWS credentials from the named profile.
# The copy job runs as a plain pod (no IRSA), so it needs static keys injected.
AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id --profile "$PROFILE" 2>/dev/null)
AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key --profile "$PROFILE" 2>/dev/null)
# Temporary (STS) credentials — access keys starting with "ASIA", as used by
# Workshop Studio / assumed roles — are INVALID without the session token.
AWS_SESSION_TOKEN=$(aws configure get aws_session_token --profile "$PROFILE" 2>/dev/null)
AWS_DEFAULT_REGION=$(aws configure get region --profile "$PROFILE" 2>/dev/null)

# Fail fast if the profile has no static credentials. Otherwise empty values
# get baked into the YAML and the copy job fails later with an opaque error.
# (e.g. SageMaker/IAM-role environments have no 'default' credentials profile.)
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "❌ [ERROR] Could not read static credentials from AWS profile '$PROFILE'."
    echo "   The FSX copy job needs an access key + secret key baked into the YAML."
    echo "   Options:"
    echo "     • Pass a profile that has static keys:  ./2.prepare_fsx_inference.sh <profile-name>"
    echo "     • Or create one:                        aws configure --profile <profile-name>"
    echo "   (IAM-role-only environments such as SageMaker have no static-key profile.)"
    exit 1
fi

# Temporary credentials (ASIA...) are useless without a session token.
if [[ "$AWS_ACCESS_KEY_ID" == ASIA* ]] && [ -z "$AWS_SESSION_TOKEN" ]; then
    echo "❌ [ERROR] Profile '$PROFILE' has TEMPORARY credentials (key starts with ASIA)"
    echo "   but no aws_session_token. The copy job would fail with 'InvalidAccessKeyId'."
    echo "   Use a profile whose aws_session_token is set, or refresh the credentials."
    exit 1
fi

# Region: fall back to the active env/config region if the profile has none.
if [ -z "$AWS_DEFAULT_REGION" ]; then
    AWS_DEFAULT_REGION=$(aws configure get region 2>/dev/null)
    [ -z "$AWS_DEFAULT_REGION" ] && AWS_DEFAULT_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
fi
if [ -z "$AWS_DEFAULT_REGION" ]; then
    echo "❌ [ERROR] Could not determine AWS region (profile '$PROFILE' has none, and"
    echo "   neither AWS_REGION nor a default config region is set)."
    echo "   Set it, e.g.:  export AWS_REGION=us-west-2"
    exit 1
fi

# Create FSX copy job configuration
echo "🔧 Creating FSX copy job configuration..."
cp template/copy_to_fsx_lustre_template.yaml copy_to_fsx_lustre.yaml

# sed in-place helper that works on both GNU (Linux) and BSD (macOS) sed.
sed_inplace() {
    if [[ "$OSTYPE" == "darwin"* ]]; then sed -i '' "$@"; else sed -i "$@"; fi
}

# Session token can contain '/', '+', '=' (base64) but never '|', so use '|'
# as the sed delimiter. Handle the token line specially: keep+fill it for
# temporary creds, or delete it entirely for permanent (AKIA) keys.
if [ -n "$AWS_SESSION_TOKEN" ]; then
    sed_inplace "s|<YOUR_SESSION_TOKEN>|$AWS_SESSION_TOKEN|g" copy_to_fsx_lustre.yaml
else
    # Remove the AWS_SESSION_TOKEN env entry (its name line + the value line).
    sed_inplace "/name: AWS_SESSION_TOKEN/{N;d;}" copy_to_fsx_lustre.yaml
fi

sed_inplace "s|<YOUR_ACCESS_KEY_ID>|$AWS_ACCESS_KEY_ID|g" copy_to_fsx_lustre.yaml
sed_inplace "s|<YOUR_SECRET_ACCESS_KEY>|$AWS_SECRET_ACCESS_KEY|g" copy_to_fsx_lustre.yaml
sed_inplace "s|<YOUR_AWS_REGION>|$AWS_DEFAULT_REGION|g" copy_to_fsx_lustre.yaml

echo "✅ FSX copy job configuration created: copy_to_fsx_lustre.yaml"

# Step 2: Create inference deployment
echo "📝 Step 2: Setting up inference deployment..."

# Auto-detect instance type from EKS cluster
echo "🔍 Auto-detecting instance type from EKS cluster..."
INSTANCE_TYPE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null)

# Auto-detect FSX filesystem ID from environment variable (already set at script start)
echo "🔍 Auto-detecting FSX filesystem ID from PV..."
FSX_FILESYSTEM="$FSX_FILESYSTEM_ID"

if [ -n "$FSX_FILESYSTEM" ]; then
    echo "✅ FSX Filesystem ID: $FSX_FILESYSTEM"
fi

# Check if we got the instance type
if [ -z "$INSTANCE_TYPE" ]; then
    echo "⚠️  Warning: Could not auto-detect instance type from EKS cluster"
    INSTANCE_TYPE="ml.g5.8xlarge"
    echo "Using default instance type: $INSTANCE_TYPE"
fi

# Check if we got the FSX filesystem ID
if [ -z "$FSX_FILESYSTEM" ]; then
    echo "❌ Error: Could not auto-detect FSX filesystem ID from PV 'fsx-pv'"
    echo "Please check if PV 'fsx-pv' exists: kubectl get pv fsx-pv"
    echo "Or set the FSX_FILESYSTEM_ID environment variable and run again."
    exit 1
fi

# Size the pod's cpu/memory request to the node's instance type. The template
# is GPU-bound (1 GPU), but if the cpu/memory request exceeds what the node has
# the pod stays Pending forever (e.g. 30 vCPU / 100Gi does NOT fit g5.2xlarge).
# Values are ~75% of the instance's vCPU/RAM, leaving headroom for daemonsets.
echo "🔍 Sizing cpu/memory request for $INSTANCE_TYPE..."
case "$INSTANCE_TYPE" in
    ml.g5.2xlarge|ml.g6.2xlarge|ml.g6e.2xlarge)   CPU_REQUEST="6000m";   MEMORY_REQUEST="24Gi"  ;;
    ml.g5.4xlarge|ml.g6.4xlarge|ml.g6e.4xlarge)   CPU_REQUEST="12000m";  MEMORY_REQUEST="52Gi"  ;;
    ml.g5.8xlarge|ml.g6.8xlarge|ml.g6e.8xlarge)   CPU_REQUEST="24000m";  MEMORY_REQUEST="100Gi" ;;
    ml.g5.12xlarge|ml.g6.12xlarge|ml.g6e.12xlarge) CPU_REQUEST="36000m"; MEMORY_REQUEST="150Gi" ;;
    ml.g5.16xlarge|ml.g6.16xlarge|ml.g6e.16xlarge) CPU_REQUEST="48000m"; MEMORY_REQUEST="200Gi" ;;
    ml.g5.48xlarge|ml.g6.48xlarge|ml.g6e.48xlarge) CPU_REQUEST="180000m"; MEMORY_REQUEST="680Gi" ;;
    ml.p4d.24xlarge|ml.p5.48xlarge)               CPU_REQUEST="90000m";  MEMORY_REQUEST="900Gi" ;;
    *)
        # Unknown type: query allocatable from the node and take ~75%, so the
        # pod always fits whatever the cluster actually provides.
        echo "  ⚠️  Unknown instance type '$INSTANCE_TYPE' — deriving from node allocatable"
        ALLOC_CPU=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null)
        ALLOC_MEM_KI=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null | sed 's/Ki$//')
        # cpu may be like "7910m" or "8"; normalize to millicores.
        case "$ALLOC_CPU" in
            *m) CPU_MILLI="${ALLOC_CPU%m}" ;;
            *)  CPU_MILLI=$(( ${ALLOC_CPU:-8} * 1000 )) ;;
        esac
        CPU_REQUEST="$(( CPU_MILLI * 75 / 100 ))m"
        MEMORY_REQUEST="$(( ${ALLOC_MEM_KI:-8388608} * 75 / 100 / 1024 / 1024 ))Gi"
        ;;
esac
echo "✅ Resource request: cpu=$CPU_REQUEST memory=$MEMORY_REQUEST (gpu=1)"

# Create inference deployment configuration
echo "🔧 Creating inference deployment configuration..."
cp template/deploy_fsx_lustre_inference_operator_template.yaml deploy_fsx_lustre_inference_operator.yaml

# Replace placeholders in inference deployment (sed_inplace defined above).
sed_inplace "s|<YOUR_INSTANCE_TYPE>|$INSTANCE_TYPE|g" deploy_fsx_lustre_inference_operator.yaml
sed_inplace "s|<YOUR_FSX_FILESYSTEM>|$FSX_FILESYSTEM|g" deploy_fsx_lustre_inference_operator.yaml
sed_inplace "s|<YOUR_CPU_REQUEST>|$CPU_REQUEST|g" deploy_fsx_lustre_inference_operator.yaml
sed_inplace "s|<YOUR_MEMORY_REQUEST>|$MEMORY_REQUEST|g" deploy_fsx_lustre_inference_operator.yaml

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
