# Megatron-LM on AWS HyperPod EKS 한국어 가이드

## 개요

Megatron-LM은 NVIDIA에서 개발한 대규모 언어 모델(LLM) 학습을 위한 프레임워크입니다. 이 가이드는 AWS SageMaker HyperPod의 EKS(Elastic Kubernetes Service) 클러스터 환경에서 Megatron-LM을 사용하여 GPT 모델을 학습하는 방법을 설명합니다.

## 참고 논문

Megatron-LM의 최적화 옵션을 이해하기 위해 다음 논문들을 참고하세요:

- [Megatron-LM: Training Multi-Billion Parameter Language Models Using Model Parallelism](https://arxiv.org/abs/1909.08053)
- [Efficient Large-Scale Language Model Training on GPU Clusters Using Megatron-LM](https://arxiv.org/abs/2104.04473)
- [Reducing Activation Recomputation in Large Transformer Models](https://arxiv.org/abs/2205.05198)

## 사전 요구사항

### 인프라 구성

1. **EKS 클러스터**: SageMaker HyperPod EKS 또는 일반 EKS 클러스터
2. **GPU 노드 그룹**: g5.48xlarge, p5.48xlarge, p5e.48xlarge 등 GPU 인스턴스
3. **컨테이너 런타임**: Docker (이미지 빌드용)
4. **공유 파일시스템**: 모든 노드에 `/fsx`로 마운트된 FSx for Lustre
5. **필수 Kubernetes 구성요소**:
   - EFA Device Plugin (고속 네트워킹)
   - NVIDIA Device Plugin (GPU 지원)
   - Kubeflow Training Operator (분산 학습)

### Kubeflow Training Operator 설치

EKS 클러스터에 Kubeflow Training Operator가 설치되어 있지 않다면 다음 명령으로 설치:

```bash
kubectl apply -k "github.com/kubeflow/training-operator/manifests/overlays/standalone"
```

설치 확인:

```bash
kubectl get pods -n kubeflow
```

## 1단계: 환경 준비

### 저장소 클론

```bash
git clone https://github.com/aws-samples/awsome-distributed-training/
cd awsome-distributed-training/3.test_cases/megatron/megatron-lm/kubernetes
```

### 환경 변수 설정

인스턴스 유형에 따라 환경 변수를 설정합니다:

```bash
# 공통 설정
export DATA_PATH=/fsx/data  # FSx for Lustre 공유 파일시스템 경로
export NUM_NODES=2           # 학습에 사용할 노드 수
```

**인스턴스 유형별 설정**:

| 인스턴스 유형 | GPU 수 | EFA 장치 수 | 설정 명령 |
|--------------|--------|------------|----------|
| p5.48xlarge | 8 | 32 | `export INSTANCE_TYPE=p5.48xlarge GPU_PER_NODE=8 EFA_PER_NODE=32` |
| p5e.48xlarge | 8 | 32 | `export INSTANCE_TYPE=p5e.48xlarge GPU_PER_NODE=8 EFA_PER_NODE=32` |
| p5en.48xlarge | 8 | 16 | `export INSTANCE_TYPE=p5en.48xlarge GPU_PER_NODE=8 EFA_PER_NODE=16` |
| p6-b200.48xlarge | 8 | 8 | `export INSTANCE_TYPE=p6-b200.48xlarge GPU_PER_NODE=8 EFA_PER_NODE=8` |

예시 (p5.48xlarge 사용 시):

```bash
export INSTANCE_TYPE=p5.48xlarge
export GPU_PER_NODE=8
export EFA_PER_NODE=32
export NUM_NODES=2
```

## 2단계: 컨테이너 빌드

### Docker 이미지 빌드

1. Dockerfile이 있는 위치에서 이미지 빌드:

```bash
docker build -t aws-megatron-lm -f aws-megatron-lm.Dockerfile .
```

2. 빌드된 이미지 확인:

```bash
docker images
# 출력 예시:
# REPOSITORY          TAG       IMAGE ID       CREATED         SIZE
# aws-megatron-lm     latest    abc123def456   2 minutes ago   20.7GB
```

### Amazon ECR에 이미지 푸시

1. 환경 변수 설정:

```bash
export AWS_REGION=us-west-2
export AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export REGISTRY=${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com
export IMAGE=aws-megatron-lm
export TAG=:latest
```

2. ECR 저장소 생성:

```bash
aws ecr create-repository --repository-name ${IMAGE} --region ${AWS_REGION}
```

3. ECR 로그인 및 이미지 푸시:

```bash
# ECR 로그인
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${REGISTRY}

# 이미지 태깅
docker tag ${IMAGE}${TAG} ${REGISTRY}/${IMAGE}${TAG}

# 이미지 푸시
docker push ${REGISTRY}/${IMAGE}${TAG}
```

4. 이미지 URI 환경 변수 설정:

```bash
export IMAGE_URI=${REGISTRY}/${IMAGE}${TAG}
```

## 3단계: GPT 모델 학습

### 데이터 다운로드

1. manifest 파일 생성:

```bash
cd gpt3
envsubst < manifests/getdata-job.yaml-template > manifests/getdata-job.yaml
```

2. 데이터 다운로드 Job 실행:

```bash
kubectl apply -f manifests/getdata-job.yaml
```

3. 진행 상황 모니터링:

```bash
kubectl logs -f job/getdata-job
```

4. 완료 후 Job 정리:

```bash
kubectl delete -f manifests/getdata-job.yaml
```

### 데이터 전처리

1. 전처리 manifest 파일 생성:

```bash
envsubst < manifests/prepdata-job.yaml-template > manifests/prepdata-job.yaml
```

2. 전처리 Job 실행:

```bash
kubectl apply -f manifests/prepdata-job.yaml
```

3. 진행 상황 모니터링:

```bash
kubectl logs -f job/prepdata-job
```

4. 완료 후 Job 정리:

```bash
kubectl delete -f manifests/prepdata-job.yaml
```

### 분산 학습 실행

#### 학습 파라미터 설정

기본 학습 환경 변수 설정:

```bash
# 병렬화 설정
export TENSOR_PARALLEL=8
export PIPELINE_PARALLEL=1

# 모델 구성 (7.5B 기본)
export NUM_LAYERS=36
export HIDDEN_SIZE=4096
export NUM_ATTENTION_HEADS=32
export SEQ_LENGTH=2048
export MAX_POSITION_EMBEDDINGS=2048

# 배치 크기
export MICRO_BATCH_SIZE=1
export GLOBAL_BATCH_SIZE=288
```

#### PyTorchJob 배포

1. PyTorchJob manifest 생성:

```bash
envsubst < manifests/pytorchjob.yaml-template > manifests/pytorchjob.yaml
```

2. 학습 Job 실행:

```bash
kubectl apply -f manifests/pytorchjob.yaml
```

3. Pod 상태 확인:

```bash
kubectl get pods
```

4. 학습 로그 모니터링:

```bash
kubectl logs -f megatron-worker-0
```

5. 학습 중지:

```bash
kubectl delete -f manifests/pytorchjob.yaml
```

### 모델 크기 커스터마이징

환경 변수를 사용하여 다양한 모델 크기 설정:

| 모델 크기 | 설정 명령 |
|----------|----------|
| 1.7B | `export NUM_ATTENTION_HEADS=24 HIDDEN_SIZE=2304 NUM_LAYERS=24` |
| 3.6B | `export NUM_ATTENTION_HEADS=32 HIDDEN_SIZE=3072 NUM_LAYERS=30` |
| 7.5B | `export NUM_ATTENTION_HEADS=32 HIDDEN_SIZE=4096 NUM_LAYERS=36` |
| 18.4B | `export NUM_ATTENTION_HEADS=48 HIDDEN_SIZE=6144 NUM_LAYERS=40` |
| 39.1B | `export NUM_ATTENTION_HEADS=64 HIDDEN_SIZE=8192 NUM_LAYERS=48` |
| 76.1B | `export NUM_ATTENTION_HEADS=80 HIDDEN_SIZE=10240 NUM_LAYERS=60` |
| 145.6B | `export NUM_ATTENTION_HEADS=96 HIDDEN_SIZE=12288 NUM_LAYERS=80` |
| 310.1B | `export NUM_ATTENTION_HEADS=128 HIDDEN_SIZE=16384 NUM_LAYERS=96` |

설정 후 manifest 파일을 재생성하고 배포:

```bash
envsubst < manifests/pytorchjob.yaml-template > manifests/pytorchjob.yaml
kubectl apply -f manifests/pytorchjob.yaml
```

### 주요 학습 파라미터

기본 7.5B 모델의 설정:

- **병렬화 전략**:
  - Tensor Parallel: 8
  - Pipeline Parallel: 1
  - 총 16 GPU (2노드 x 8 GPU)

- **배치 크기**:
  - Micro batch: 1
  - Global batch: 288

- **학습 하이퍼파라미터**:
  - Learning rate: 6.0e-5 (cosine decay)
  - Gradient clipping: 1.0
  - Weight decay: 0.1
  - Optimizer: Adam (β1=0.9, β2=0.95)

- **모델 구성**:
  - Layers: 36
  - Hidden size: 4096
  - Attention heads: 32
  - Sequence length: 2048

### 고급 설정

**벤치마크 모드 (검증/테스트 비활성화)**:

PyTorchJob template에서 다음과 같이 수정:

```bash
# 변경 전
--eval-iters 40 \
--eval-interval 1000 \
--split 98,2,0 \

# 변경 후
--eval-iters 0 \
--split 100,0,0 \
```

**학습 반복 횟수 지정**:

```bash
# 변경 전 (샘플 기반)
--train-samples 146484375 \
--lr-decay-samples 126953125 \
--lr-warmup-samples 183105 \

# 변경 후 (스텝 기반)
--train-iters 50 \
--lr-decay-iters 45 \
--lr-warmup-iters 2 \
```

## 학습 모니터링 및 관리

### Pod 상태 확인

```bash
# 전체 Pod 목록
kubectl get pods

# 특정 Pod 상세 정보
kubectl describe pod megatron-worker-0

# 실시간 로그 확인
kubectl logs -f megatron-worker-0
```

### PyTorchJob 상태 확인

```bash
# PyTorchJob 목록
kubectl get pytorchjob

# 상세 상태 확인
kubectl describe pytorchjob megatron
```

## 추가 리소스

- [Megatron-LM GitHub](https://github.com/NVIDIA/Megatron-LM)
- [AWS 분산 학습 예제](https://github.com/aws-samples/awsome-distributed-training)
- [SageMaker HyperPod 문서](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod.html)
- [FSx for Lustre 문서](https://docs.aws.amazon.com/fsx/latest/LustreGuide/what-is.html)
- [Kubeflow Training Operator](https://github.com/kubeflow/training-operator)

## 참고사항

- 이 가이드는 [aws-samples/awsome-distributed-training](https://github.com/aws-samples/awsome-distributed-training/tree/main/3.test_cases/megatron/megatron-lm/kubernetes) 저장소의 내용을 기반으로 작성되었습니다.
- 최신 업데이트와 추가 예제는 원본 저장소를 참고하세요.
- 실제 프로덕션 환경에서는 데이터셋, 모델 크기, 클러스터 구성에 맞게 파라미터를 조정해야 합니다.
