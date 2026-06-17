# HyperPod Inference Endpoint 배포 및 테스트 가이드

## 🚀 빠른 시작 (자동화 스크립트)

### 1. 클러스터 접근 설정 (../../setup/1.create-config.sh 실행 후 생성되는 env_var의 환경 변수를 로드합니다.)
```bash
./1.grant_eks_access.sh
```

### 2. 배포 방법 선택

#### FSx 기반 배포 (AWS 계정)
```bash
# FSx 환경 준비
./2.prepare_fsx_inference.sh

# FSx로 모델 복사
kubectl apply -f copy_to_fsx_lustre.yaml

# 추론 엔드포인트 배포
kubectl apply -f deploy_fsx_lustre_inference_operator.yaml
```

#### S3 기반 배포 (AWS 계정)
```bash
# S3 환경 준비
./3.copy_to_s3.sh
./4.fix_s3_csi_credentials.sh
./5a.prepare_s3_inference_operator.sh

# 추론 엔드포인트 배포
kubectl apply -f deploy_S3_inference_operator.yaml
```

#### S3 기반 배포 (AWS 워크샵 임시 계정)
```bash
# S3 환경 준비
./3.copy_to_s3.sh
./5b.prepare_s3_direct_deploy.sh

# 추론 엔드포인트 배포
kubectl apply -f deploy_S3_direct.yaml
```

### ⚠️ 리소스 부족 문제 해결

`ml.g5.2xlarge` 등 작은 인스턴스를 사용하거나 노드에 Pod가 많아서 배포가 실패하는 경우:

```bash
kubectl get pods -w

# NAME                          READY   STATUS    RESTARTS   AGE
# deepseek15b-59586756d-h7vsx   0/1     Pending   0          30s
```

```bash
# 문제 해결 스크립트 실행 (노드 maxPods 상향으로 슬롯 확보)
cd ../../setup
./4.ensure-workshop-capacity.sh
cd -

# 기존 배포 삭제 후 재배포
kubectl delete deployment deepseek15b
kubectl apply -f deploy_S3_direct.yaml
```

## 📊 테스트 

### AWS 워크샵 임시 계정

```bash
# Pod 상태 확인
kubectl get pods -w

# 로그 확인 (모델 로딩 진행 상황)
kubectl logs -l app=deepseek15b -f

# Service 확인
kubectl get svc deepseek15b

# 간단한 테스트
kubectl exec -it deployment/deepseek15b -- curl -X POST http://localhost:8080/invocations \
  -H 'Content-Type: application/json' \
  -d '{"inputs": "Explain machine learning in simple terms.", "parameters": {"max_new_tokens": 200, "temperature": 0.7, "repetition_penalty": 1.5}}'

# 테스트 (테스트용 Pod 띄우고 실행)
kubectl run test-curl --rm -i --restart=Never --image=curlimages/curl -- \
  curl -X POST http://deepseek15b:8080/invocations \
  -H 'Content-Type: application/json' \
  -d '{"inputs": "Explain machine learning in simple terms.", "parameters": {"max_new_tokens": 200, "temperature": 0.7, "repetition_penalty": 1.5}}'
```

### AWS 계정
배포 완료 후 추론 엔드포인트를 테스트할 수 있습니다:

```bash
# 기본 추론 테스트 (invoke.py에서 ENDPOINT_NAME 수정 필요)
python invoke.py
```

> **참고**: `invoke.py` 파일에서 `ENDPOINT_NAME`을 배포한 엔드포인트 이름으로 수정하세요.
> - FSx 배포: `'deepseek15b-fsx'`
> - S3 배포: `'deepseek15b'` (또는 사용자 정의 이름)

---

## 📖 상세 가이드 (수동 Step-by-Step)

자동화 스크립트 대신 각 단계를 수동으로 이해하고 실행하려면 아래 가이드를 따르세요.

### 사전 준비

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
        # ⚠️ cpu/memory 요청은 노드 인스턴스 크기에 맞춰야 합니다.
        # 아래 값(30 vCPU / 100Gi)은 ml.g5.8xlarge 기준이며, ml.g5.2xlarge
        # (8 vCPU / 32Gi)에서는 절대 스케줄되지 않아 Pod가 영원히 Pending 됩니다.
        # ml.g5.2xlarge면 cpu: 6000m / memory: 24Gi 정도로 낮추세요.
        # (자동화 스크립트 ./2.prepare_fsx_inference.sh 는 인스턴스 타입을
        #  감지해 이 값을 자동으로 맞춰줍니다.)
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

### Step 3: Endpoint(Service) 확인

```bash
kubectl get svc | grep routing-service
kubectl get endpoints | grep routing-service
```

출력 예시:
```
NAME                              TYPE        CLUSTER-IP      PORT(S)
deepseek15b-fsx-routing-service   ClusterIP   172.20.49.99    443/TCP
deepseek15b-routing-service       ClusterIP   172.20.51.10    443/TCP
```

> **호출 주소 핵심:**
> - **Service 이름으로 호출하면 됩니다** (Pod IP를 직접 쓸 필요 없음 — IP는 Pod 재시작 시 바뀜).
>   주소: `<service-name>.<namespace>.svc.cluster.local` (같은 네임스페이스면 `<service-name>`만으로도 가능)
> - Service 포트는 `443`이지만 **프로토콜은 평문 HTTP**입니다. 따라서 `http://...:443` 으로 호출하세요.
>   `https://` 로 호출하면 `SSL: WRONG_VERSION_NUMBER` 에러가 납니다.
> - 경로는 `/invocations` 입니다.

### Step 4: FSX Endpoint 테스트

`python:3.11-slim` 이미지에는 `requests`가 없으므로, 추가 설치가 필요 없는 **표준 라이브러리 `urllib`** 를 사용합니다.

```bash
kubectl exec test-endpoint -- python3 -c '
import urllib.request, json
url = "http://deepseek15b-fsx-routing-service.default.svc.cluster.local:443/invocations"
req = urllib.request.Request(
    url,
    data=json.dumps({"inputs": "Hi, what can you help me with?"}).encode(),
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(req, timeout=120) as r:
    print("Status:", r.status)
    print("Response:", r.read().decode())
'
```

`requests`를 선호하면 먼저 설치 후 사용하세요:
```bash
kubectl exec test-endpoint -- pip install requests -q
kubectl exec test-endpoint -- python3 -c '
import requests
r = requests.post(
    "http://deepseek15b-fsx-routing-service.default.svc.cluster.local:443/invocations",
    headers={"Content-Type": "application/json"},
    json={"inputs": "Hi, what can you help me with?"},
    timeout=120,
)
print("Status:", r.status_code)
print("Response:", r.text)
'
```

### Step 5: S3 Endpoint 테스트

S3 배포의 경우 Service 이름만 다릅니다 (`deepseek15b-routing-service`):

```bash
kubectl exec test-endpoint -- python3 -c '
import urllib.request, json
url = "http://deepseek15b-routing-service.default.svc.cluster.local:443/invocations"
req = urllib.request.Request(
    url,
    data=json.dumps({"inputs": "Hi, what can you help me with?"}).encode(),
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(req, timeout=120) as r:
    print("Status:", r.status)
    print("Response:", r.read().decode())
'
```

### Step 6: 테스트 Pod 정리

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

---

## 트러블슈팅

### 1. `kubectl apply` 시 conversion webhook 에러

```
conversion webhook for inference.sagemaker.aws.amazon.com/... failed:
Post "https://hyperpod-inference-conversion-webhook.../convert...":
no endpoints available for service "hyperpod-inference-conversion-webhook"
```

**원인:** webhook을 서빙하는 `hyperpod-inference-controller-manager` Pod가 없습니다. 보통
`amazon-sagemaker-hyperpod-inference` 애드온이 `CREATE_FAILED` 상태이고, 그 뿌리는 **Kueue가
scale 0으로 죽어 있어** (`kueue-webhook-service` endpoint 없음) 애드온이 controller-manager
Deployment를 만들지 못한 것입니다. (워크샵용 Pod 정리 스크립트가 Kueue를 죽인 부작용)

```bash
# 1) 진단
kubectl get endpoints hyperpod-inference-conversion-webhook -n hyperpod-inference-system  # <none> 이면 해당
aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" \
  --addon-name amazon-sagemaker-hyperpod-inference --region "$AWS_REGION" \
  --query 'addon.{Status:status,Health:health.issues}'
kubectl get deploy kueue-controller-manager -n kueue-system   # 0/0 이면 죽은 상태

# 2) Kueue 복구 (webhook endpoint 살아남)
kubectl scale deployment kueue-controller-manager -n kueue-system --replicas=1

# 3) CREATE_FAILED 애드온은 update가 안 되므로, k8s 리소스는 보존(--preserve)하고
#    등록만 지운 뒤 동일 구성으로 재생성 (재생성 시 controller-manager가 정상 생성됨)
aws eks delete-addon --cluster-name "$EKS_CLUSTER_NAME" \
  --addon-name amazon-sagemaker-hyperpod-inference --preserve --region "$AWS_REGION"
# (삭제 완료 후) 기존 configuration-values 로 다시 create-addon
```

### 2. FSx 복사 Job이 `ContainerCreating`에서 멈춤

```
MountVolume.MountDevice failed for volume "fsx-pv":
driver name fsx.csi.aws.com not found in the list of registered CSI drivers
```

**원인:** FSx CSI 드라이버의 `fsx-csi-node` DaemonSet이 없어졌습니다 (`aws-fsx-csi-driver`
애드온이 `DEGRADED`). 역시 워크샵 Pod 정리 스크립트가 슬롯 확보용으로 삭제한 부작용입니다.

```bash
kubectl get ds -n kube-system | grep fsx          # 없으면 해당
aws eks update-addon --cluster-name "$EKS_CLUSTER_NAME" \
  --addon-name aws-fsx-csi-driver --resolve-conflicts OVERWRITE --region "$AWS_REGION"
```

### 3. 추론 Pod가 계속 `Pending`

```
FailedScheduling: Insufficient cpu / Insufficient memory
```

**원인:** deploy YAML의 cpu/memory **요청값이 노드 인스턴스보다 큽니다.** 예: 기본 예시의
`cpu: 30000m / memory: 100Gi`는 `ml.g5.2xlarge`(8 vCPU / 32Gi)에 절대 안 들어갑니다.

```bash
kubectl describe pod -l app=deepseek15b-fsx | sed -n '/Events:/,$p'
# 해결: 요청값을 인스턴스에 맞게 낮춤 (g5.2xlarge → cpu 6000m / memory 24Gi)
# ./2.prepare_fsx_inference.sh 는 인스턴스 타입을 감지해 자동으로 맞춰줍니다.
```

### 4. 노드 슬롯 부족(`Too many pods` / Pending)

`ml.g5.2xlarge` 같은 인스턴스는 HyperPod이 kubelet `maxPods`를 낮게(예: 14) 고정합니다.
`../../setup/4.ensure-workshop-capacity.sh` 로 `maxPods`를 상향해 슬롯을 확보하세요
(자세한 내용은 [`../../setup/SCRIPTS.md`](../../setup/SCRIPTS.md) 참고).

### 5. 엔드포인트 호출 시 에러

| 증상 | 원인 / 해결 |
|---|---|
| `ModuleNotFoundError: No module named 'requests'` | `test-endpoint`(python:3.11-slim) Pod 안에 requests 없음 → `urllib` 사용하거나 `kubectl exec test-endpoint -- pip install requests` |
| `SSL: WRONG_VERSION_NUMBER` | `https://` 로 호출함 → Service 포트는 443이지만 평문 HTTP이므로 `http://...:443` 사용 |
| 연결 거부 / Pod IP 변경됨 | Pod IP 대신 **Service 이름**(`<svc>.<ns>.svc.cluster.local:443`)으로 호출 |
