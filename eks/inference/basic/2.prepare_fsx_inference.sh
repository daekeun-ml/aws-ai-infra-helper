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

# Extract AWS credentials from the named profile for the copy job.
# The copy job runs as a plain pod (no IRSA), so it needs static keys injected.
# IMPORTANT: store these in COPY_* variables, NOT the standard AWS_ACCESS_KEY_ID
# / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN names. Overwriting those would
# poison this shell's credentials, so the later `kubectl` (which calls
# `aws eks get-token`) would use the profile creds instead of the active ones
# and fail with Unauthorized — breaking instance-type auto-detection below.
COPY_ACCESS_KEY_ID=$(aws configure get aws_access_key_id --profile "$PROFILE" 2>/dev/null)
COPY_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key --profile "$PROFILE" 2>/dev/null)
# Temporary (STS) credentials — access keys starting with "ASIA", as used by
# Workshop Studio / assumed roles — are INVALID without the session token.
COPY_SESSION_TOKEN=$(aws configure get aws_session_token --profile "$PROFILE" 2>/dev/null)
COPY_REGION=$(aws configure get region --profile "$PROFILE" 2>/dev/null)

# Fail fast if the profile has no static credentials. Otherwise empty values
# get baked into the YAML and the copy job fails later with an opaque error.
# (e.g. SageMaker/IAM-role environments have no 'default' credentials profile.)
if [ -z "$COPY_ACCESS_KEY_ID" ] || [ -z "$COPY_SECRET_ACCESS_KEY" ]; then
    echo "❌ [ERROR] Could not read static credentials from AWS profile '$PROFILE'."
    echo "   The FSX copy job needs an access key + secret key baked into the YAML."
    echo "   Options:"
    echo "     • Pass a profile that has static keys:  ./2.prepare_fsx_inference.sh <profile-name>"
    echo "     • Or create one:                        aws configure --profile <profile-name>"
    echo "   (IAM-role-only environments such as SageMaker have no static-key profile.)"
    exit 1
fi

# Temporary credentials (ASIA...) are useless without a session token.
if [[ "$COPY_ACCESS_KEY_ID" == ASIA* ]] && [ -z "$COPY_SESSION_TOKEN" ]; then
    echo "❌ [ERROR] Profile '$PROFILE' has TEMPORARY credentials (key starts with ASIA)"
    echo "   but no aws_session_token. The copy job would fail with 'InvalidAccessKeyId'."
    echo "   Use a profile whose aws_session_token is set, or refresh the credentials."
    exit 1
fi

# Region: fall back to the active env/config region if the profile has none.
if [ -z "$COPY_REGION" ]; then
    COPY_REGION=$(aws configure get region 2>/dev/null)
    [ -z "$COPY_REGION" ] && COPY_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
fi
if [ -z "$COPY_REGION" ]; then
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
if [ -n "$COPY_SESSION_TOKEN" ]; then
    sed_inplace "s|<YOUR_SESSION_TOKEN>|$COPY_SESSION_TOKEN|g" copy_to_fsx_lustre.yaml
else
    # Remove the AWS_SESSION_TOKEN env entry (its name line + the value line).
    sed_inplace "/name: AWS_SESSION_TOKEN/{N;d;}" copy_to_fsx_lustre.yaml
fi

sed_inplace "s|<YOUR_ACCESS_KEY_ID>|$COPY_ACCESS_KEY_ID|g" copy_to_fsx_lustre.yaml
sed_inplace "s|<YOUR_SECRET_ACCESS_KEY>|$COPY_SECRET_ACCESS_KEY|g" copy_to_fsx_lustre.yaml
sed_inplace "s|<YOUR_AWS_REGION>|$COPY_REGION|g" copy_to_fsx_lustre.yaml

echo "✅ FSX copy job configuration created: copy_to_fsx_lustre.yaml"

# Step 2: Create inference deployment
echo "📝 Step 2: Setting up inference deployment..."

# Auto-detect instance type from EKS cluster.
# Allow an explicit override via env (INSTANCE_TYPE=ml.g5.2xlarge ./2...sh).
echo "🔍 Auto-detecting instance type from EKS cluster..."
if [ -z "${INSTANCE_TYPE:-}" ]; then
    # Pick the instance-type label from a READY GPU node. Looking only at
    # .items[0] is fragile: during node replacement the first node may be
    # NotReady or not yet labelled, which silently yields an empty value.
    INSTANCE_TYPE=$(kubectl get nodes \
        -l node.kubernetes.io/instance-type \
        -o jsonpath='{range .items[*]}{.metadata.labels.node\.kubernetes\.io/instance-type}{"\n"}{end}' 2>/dev/null \
        | grep -v '^$' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
fi

# Auto-detect FSX filesystem ID from environment variable (already set at script start)
echo "🔍 Auto-detecting FSX filesystem ID from PV..."
FSX_FILESYSTEM="$FSX_FILESYSTEM_ID"

if [ -n "$FSX_FILESYSTEM" ]; then
    echo "✅ FSX Filesystem ID: $FSX_FILESYSTEM"
fi

# Fail loudly instead of guessing — a wrong instance type produces wrong
# cpu/memory requests (e.g. assuming g5.8xlarge on a g5.2xlarge node makes
# the pod unschedulable). Let the user pin it explicitly.
if [ -z "$INSTANCE_TYPE" ]; then
    echo "❌ [ERROR] Could not auto-detect the node instance type."
    echo "   'kubectl get nodes' returned no labelled node. Common causes:"
    echo "     • AWS credentials expired → kubectl is Unauthorized"
    echo "       (check: kubectl get nodes ; aws sts get-caller-identity)"
    echo "     • nodes are still provisioning / NotReady"
    echo "   Fix the access, or pin the type explicitly:"
    echo "     INSTANCE_TYPE=ml.g5.2xlarge ./2.prepare_fsx_inference.sh"
    exit 1
fi
echo "✅ Instance type: $INSTANCE_TYPE"

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
