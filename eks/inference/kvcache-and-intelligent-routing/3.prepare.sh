#!/bin/bash

# Load S3_BUCKET from file if exists
if [ -f ".s3_bucket_env" ]; then
    source .s3_bucket_env
fi

# Check if S3_BUCKET is set
if [ -z "$S3_BUCKET" ]; then
    echo "❌ S3_BUCKET environment variable is not set."
    echo ""
    echo "💡 Option 1: Run 1.copy_to_s3.sh first"
    echo "   ./1.copy_to_s3.sh"
    echo ""
    echo "💡 Option 2: Set it manually"
    echo "   export S3_BUCKET=hyperpod-inference-xxxxx-us-east-2"
    echo "   ./3.prepare.sh"
    echo ""
    echo "💡 Option 3: Auto-detect from existing buckets"
    
    # Try to auto-detect
    DETECTED_BUCKET=$(aws s3 ls | grep hyperpod-inference | tail -1 | awk '{print $3}')
    
    if [ -n "$DETECTED_BUCKET" ]; then
        echo ""
        echo "🔍 Found bucket: $DETECTED_BUCKET"
        read -p "Use this bucket? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            S3_BUCKET=$DETECTED_BUCKET
            echo "✅ Using bucket: $S3_BUCKET"
        else
            exit 1
        fi
    else
        echo ""
        echo "❌ No hyperpod-inference buckets found"
        echo "   Run ./1.copy_to_s3.sh first"
        exit 1
    fi
fi

export MODEL_NAME="deepseek7b"
export ENDPOINT_NAME="deepseek7b-endpoint"
export INSTANCE_TYPE="ml.g5.24xlarge"
export MODEL_IMAGE="public.ecr.aws/deep-learning-containers/vllm:0.11.1-gpu-py312-cu129-ubuntu22.04-ec2-v1.0"
export S3_MODEL_PATH="deepseek7b"
export AWS_REGION=$(aws configure get region --profile ${PROFILE:-default})
export CERT_S3_URI="s3://${S3_BUCKET}/certs/"
export NAMESPACE="default"
export NAME="demo"

echo "🔧 Configuration:"
echo "   S3 Bucket: $S3_BUCKET"
echo "   Model Path: $S3_MODEL_PATH"
echo "   Region: $AWS_REGION"

cat << YAML_EOF > inference_endpoint_config.yaml
apiVersion: inference.sagemaker.aws.amazon.com/v1
kind: InferenceEndpointConfig
metadata:
  name: ${NAME}
  namespace: ${NAMESPACE}
spec:
  endpointName: ${ENDPOINT_NAME}
  modelName: ${MODEL_NAME}
  instanceType: ${INSTANCE_TYPE}
  invocationEndpoint: v1/chat/completions
  replicas: 1
  modelSourceConfig:
    modelSourceType: s3
    s3Storage:
      bucketName: ${S3_BUCKET}
      region: ${AWS_REGION}
    modelLocation: ${S3_MODEL_PATH}
    prefetchEnabled: false
  kvCacheSpec:
    enableL1Cache: true
    enableL2Cache: true
    l2CacheSpec:
      l2CacheBackend: "tieredstorage"
  intelligentRoutingSpec:
    enabled: true
    routingStrategy: prefixaware
  tlsConfig:
    tlsCertificateOutputS3Uri: ${CERT_S3_URI}
  metrics:
    enabled: true
    modelMetrics:
      port: 8000
  loadBalancer:
    healthCheckPath: /health
  worker:
    resources:
      limits:
        nvidia.com/gpu: "4"
      requests:
        cpu: "6"
        memory: 30Gi
        nvidia.com/gpu: "4"
    image: ${MODEL_IMAGE}
    args:
      - "--model"
      - "/opt/ml/model"
      - "--max-model-len"
      - "20000"
      - "--tensor-parallel-size"
      - "4"
    modelInvocationPort:
      containerPort: 8000
      name: http
    modelVolumeMount:
      name: model-weights
      mountPath: /opt/ml/model
    environmentVariables:
      - name: PYTHONHASHSEED
        value: "123"
      - name: OPTION_ROLLING_BATCH
        value: "vllm"
      - name: SAGEMAKER_SUBMIT_DIRECTORY
        value: "/opt/ml/model/code"
      - name: MODEL_CACHE_ROOT
        value: "/opt/ml/model"
      - name: SAGEMAKER_MODEL_SERVER_WORKERS
        value: "1"
      - name: SAGEMAKER_MODEL_SERVER_TIMEOUT
        value: "3600"
YAML_EOF

echo "✅ inference_endpoint_config.yaml created successfully."
echo "📍 S3 Bucket used: $S3_BUCKET"
echo ""
echo "🚀 Deploy with kubectl:"
echo "   kubectl apply -f inference_endpoint_config.yaml"
echo ""
echo "📊 Check deployment status:"
echo "   kubectl get inferenceendpointconfig ${NAME} -n ${NAMESPACE}"
echo "   kubectl get pods -n ${NAMESPACE}"
echo ""
echo "📝 For detailed status:"
echo "   kubectl describe inferenceendpointconfig ${NAME} -n ${NAMESPACE}"
