# HyperPod Inference Endpoint 배포 및 테스트 가이드

## 사전 준비

### 0. EKS 클러스터 생성

HyperPod에서 EKS 기반 클러스터 생성하는 [가이드라인](https://docs.aws.amazon.com/ko_kr/sagemaker/latest/dg/sagemaker-hyperpod-eks-operate-console-ui-create-cluster.html
)을 참고하여 EKS 클러스터를 생성합니다.

### 1. EKS 클러스터 접속 설정

```bash
# HyperPod EKS 클러스터에 kubeconfig 설정 (Console에서 클러스터 클릭 후 Orchestrator 항목에서 이름 확인 가능)
aws eks update-kubeconfig --name "YOUR_EKS_CLUSTER_NAME" --region us-west-2

# 클러스터 연결 확인
kubectl get nodes
```

### 2. PVC 상태 확인

```bash
kubectl get pvc
```

출력 예시:
```
NAME        STATUS   VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS
fsx-claim   Bound    fsx-pv   1200Gi     RWX            fsx-sc
```

---

## 방법 1: FSX Lustre 기반 Endpoint 배포

### Step 1: 모델을 FSX로 복사

**copy.yaml 파일 생성:**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: copy-model-to-fsx
spec:
  template:
    spec:
      containers:
        - name: aws-cli
          image: amazon/aws-cli:latest
          command: ["/bin/bash"]
          args:
            - -c
            - |
              aws s3 sync s3://jumpstart-cache-prod-us-east-2/deepseek-llm/deepseek-llm-r1-distill-qwen-1-5b/artifacts/inference-prepack/v2.0.0 /fsx/deepseek15b
          volumeMounts:
            - name: fsx-storage
              mountPath: /fsx
          env:
            - name: AWS_DEFAULT_REGION
              value: "us-west-2"
            - name: AWS_REGION
              value: "us-west-2"
            - name: AWS_ACCESS_KEY_ID
              value: "<YOUR_ACCESS_KEY_ID>"
            - name: AWS_SECRET_ACCESS_KEY
              value: "<YOUR_SECRET_ACCESS_KEY>"
            - name: AWS_SESSION_TOKEN
              value: "<YOUR_SESSION_TOKEN>"  # 임시 자격 증명 사용 시
      volumes:
        - name: fsx-storage
          persistentVolumeClaim:
            claimName: fsx-claim
      restartPolicy: Never
  backoffLimit: 3
```

**Job 실행:**
```bash
kubectl apply -f copy_to_fsx_lustre.yaml
```

**복사 상태 확인:**
```bash
# Job 상태 확인
kubectl get jobs

# Pod 로그 확인 (복사 진행률)
kubectl logs -f job/copy-model-to-fsx
```

### Step 2: FSX File System ID 확인

```bash
kubectl get pv fsx-pv -o yaml | grep -A5 "csi:"
```

출력 예시:
```yaml
csi:
  driver: fsx.csi.aws.com
  volumeAttributes:
    dnsname: fs-09d6a597bc983fe33.fsx.us-west-2.amazonaws.com
    mountname: e3pfzb4v
  volumeHandle: fs-09d6a597bc983fe33
```

### Step 3: FSX Endpoint 배포

**deploy_fsx_lustre_inference_operator.yaml 파일에서 fileSystemId 수정:**
```yaml
apiVersion: inference.sagemaker.aws.amazon.com/v1alpha1
kind: InferenceEndpointConfig
metadata:
  name: deepseek15b-fsx
  namespace: default
spec:
  endpointName: deepseek15b-fsx
  instanceType: ml.g5.8xlarge
  invocationEndpoint: invocations
  modelName: deepseek15b
  modelSourceConfig:
    fsxStorage:
      fileSystemId: fs-09d6a597bc983fe33  # 위에서 확인한 FSX ID로 변경
    modelLocation: deepseek15b
    modelSourceType: fsx
  worker:
    environmentVariables:
    - name: HF_MODEL_ID
      value: /opt/ml/model
    - name: SAGEMAKER_PROGRAM
      value: inference.py
    - name: SAGEMAKER_SUBMIT_DIRECTORY
      value: /opt/ml/model/code
    - name: MODEL_CACHE_ROOT
      value: /opt/ml/model
    - name: SAGEMAKER_ENV
      value: '1'
    image: 763104351884.dkr.ecr.us-east-2.amazonaws.com/huggingface-pytorch-tgi-inference:2.4.0-tgi2.3.1-gpu-py311-cu124-ubuntu22.04-v2.0
    modelInvocationPort:
      containerPort: 8080
      name: http
    modelVolumeMount:
      mountPath: /opt/ml/model
      name: model-weights
    resources:
      limits:
        nvidia.com/gpu: 1
      requests:
        cpu: 30000m
        memory: 100Gi
        nvidia.com/gpu: 1
```

**Endpoint 배포:**
```bash
kubectl apply -f deploy_fsx_lustre_inference_operator.yaml
```

**배포 상태 확인:**
```bash
# Pod 상태 확인
kubectl get pods

# 상세 이벤트 확인
kubectl describe pod -l app=deepseek15b-fsx
```

---

## 방법 2: S3 기반 Endpoint 배포

### Step 1: S3 버킷 생성 및 모델 업로드

```bash
# S3 버킷 생성 (클러스터와 같은 리전)
aws s3 mb s3://deepseek-qwen-1-5b-us-west-2 --region us-west-2

# 모델 복사
aws s3 sync s3://jumpstart-cache-prod-us-east-2/deepseek-llm/deepseek-llm-r1-distill-qwen-1-5b/artifacts/inference-prepack/v2.0.0 \
  s3://deepseek-qwen-1-5b-us-west-2/deepseek15b/ --region us-west-2
```

### Step 2: S3 Endpoint 배포

**deploy_S3_inference_operator.yaml:**
```yaml
apiVersion: inference.sagemaker.aws.amazon.com/v1alpha1
kind: InferenceEndpointConfig
metadata:
  name: deepseek15b
  namespace: default
spec:
  modelName: deepseek15b
  endpointName: deepseek15b
  instanceType: ml.g5.8xlarge
  invocationEndpoint: invocations
  modelSourceConfig:
    modelSourceType: s3
    s3Storage:
      bucketName: deepseek-qwen-1-5b-us-west-2  # 생성한 버킷 이름
      region: us-west-2                         # 버킷 리전
    modelLocation: deepseek15b
    prefetchEnabled: true
  worker:
    resources:
      limits:
        nvidia.com/gpu: 1
      requests:
        nvidia.com/gpu: 1
        cpu: 25600m
        memory: 102Gi
    image: 763104351884.dkr.ecr.us-east-2.amazonaws.com/djl-inference:0.32.0-lmi14.0.0-cu124
    modelInvocationPort:
      containerPort: 8080
      name: http
    modelVolumeMount:
      name: model-weights
      mountPath: /opt/ml/model
    environmentVariables:
      - name: OPTION_ROLLING_BATCH
        value: "vllm"
      - name: SERVING_CHUNKED_READ_TIMEOUT
        value: "480"
      - name: DJL_OFFLINE
        value: "true"
      - name: NUM_SHARD
        value: "1"
      - name: SAGEMAKER_PROGRAM
        value: "inference.py"
      - name: SAGEMAKER_SUBMIT_DIRECTORY
        value: "/opt/ml/model/code"
      - name: MODEL_CACHE_ROOT
        value: "/opt/ml/model"
      - name: SAGEMAKER_MODEL_SERVER_WORKERS
        value: "1"
      - name: SAGEMAKER_MODEL_SERVER_TIMEOUT
        value: "3600"
      - name: OPTION_TRUST_REMOTE_CODE
        value: "true"
      - name: OPTION_ENABLE_REASONING
        value: "true"
      - name: OPTION_REASONING_PARSER
        value: "deepseek_r1"
      - name: SAGEMAKER_CONTAINER_LOG_LEVEL
        value: "20"
      - name: SAGEMAKER_ENV
        value: "1"
```

**Endpoint 배포:**
```bash
kubectl apply -f deploy_S3_inference_operator.yaml
```

**배포 상태 확인:**
```bash
kubectl get pods
kubectl get svc
```

---

## Endpoint 테스트

### Step 1: 테스트용 Pod 생성

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-endpoint
spec:
  containers:
  - name: test
    image: python:3.11-slim
    command: ["sleep", "3600"]
  restartPolicy: Never
EOF
```

### Step 2: Pod 상태 확인

```bash
kubectl get pod test-endpoint
```

### Step 3: requests 라이브러리 설치

```bash
kubectl exec test-endpoint -- pip install requests -q
```

### Step 4: Endpoint 정보 확인

```bash
kubectl get endpoints
```

출력 예시:
```
NAME                              ENDPOINTS
deepseek15b-fsx-routing-service   10.1.112.202:8081
deepseek15b-routing-service       10.1.111.162:8081
```

### Step 5: FSX Endpoint 테스트

> **Note:** Service DNS 이름 대신 Endpoint IP를 직접 사용해야 합니다. Step 4에서 확인한 IP를 사용하세요.

```bash
# Endpoint IP 확인 (예: 10.1.112.202:8081)
kubectl get endpoints deepseek15b-fsx-routing-service

# 테스트 실행 (IP를 실제 값으로 변경)
kubectl exec test-endpoint -- python3 -c '
import requests
import json

response = requests.post(
    "http://10.1.112.202:8081/invocations",  # 실제 Endpoint IP로 변경
    headers={"Content-Type": "application/json"},
    json={"inputs": "Hi, what can you help me with?"},
    timeout=120
)
print(f"Status: {response.status_code}")
print(f"Response: {response.text}")
'
```

### Step 6: S3 Endpoint 테스트

```bash
# Endpoint IP 확인 (예: 10.1.111.162:8081)
kubectl get endpoints deepseek15b-routing-service

# 테스트 실행 (IP를 실제 값으로 변경)
kubectl exec test-endpoint -- python3 -c '
import requests
import json

response = requests.post(
    "http://10.1.111.162:8081/invocations",  # 실제 Endpoint IP로 변경
    headers={"Content-Type": "application/json"},
    json={"inputs": "Hi, what can you help me with?"},
    timeout=120
)
print(f"Status: {response.status_code}")
print(f"Response: {response.text}")
'
```

### Step 7: 테스트 Pod 정리

```bash
kubectl delete pod test-endpoint
```

---

## 리소스 정리

### Endpoint 삭제

```bash
# FSX Endpoint 삭제
kubectl delete inferenceendpointconfig deepseek15b-fsx

# S3 Endpoint 삭제
kubectl delete inferenceendpointconfig deepseek15b
```

### 복사 Job 삭제

```bash
kubectl delete job copy-model-to-fsx
```

### S3 버킷 삭제 (선택사항)

```bash
aws s3 rb s3://deepseek-qwen-1-5b-us-west-2 --force --region us-west-2
```

---

## 유용한 명령어

```bash
# 모든 리소스 상태 확인
kubectl get pods,svc,jobs,inferenceendpointconfig

# Pod 로그 확인
kubectl logs <pod-name>

# Pod 상세 정보 (이벤트 포함)
kubectl describe pod <pod-name>

# InferenceEndpointConfig 상세 정보
kubectl describe inferenceendpointconfig <name>
```
