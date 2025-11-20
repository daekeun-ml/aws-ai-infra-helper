# Megatron-LM on AWS HyperPod 한국어 가이드

## 개요

Megatron-LM은 NVIDIA에서 개발한 대규모 언어 모델(LLM) 학습을 위한 프레임워크입니다. 이 가이드는 AWS SageMaker HyperPod의 Slurm 클러스터 환경에서 Megatron-LM을 사용하여 GPT 및 LLaMA2 모델을 학습하는 방법을 설명합니다.

## 참고 논문

Megatron-LM의 최적화 옵션을 이해하기 위해 다음 논문들을 참고하세요:

- [Megatron-LM: Training Multi-Billion Parameter Language Models Using Model Parallelism](https://arxiv.org/abs/1909.08053)
- [Efficient Large-Scale Language Model Training on GPU Clusters Using Megatron-LM](https://arxiv.org/abs/2104.04473)
- [Reducing Activation Recomputation in Large Transformer Models](https://arxiv.org/abs/2205.05198)

## 사전 요구사항

### 인프라 구성

1. **Slurm 클러스터**: AWS Parallel Cluster 또는 SageMaker HyperPod로 구성된 Slurm 클러스터
2. **컨테이너 런타임**:
   - Docker (빌드용)
   - Pyxis 및 Enroot (Slurm 컨테이너 실행용)
3. **공유 파일시스템**: 모든 노드에 `/fsx`로 마운트된 FSx for Lustre

### Pyxis/Enroot 설치

HyperPod 클러스터에 Pyxis와 Enroot가 설치되어 있지 않다면, 이 저장소의 스크립트를 사용하세요:

```bash
# Pyxis와 Enroot 설치 (클러스터 노드에서 root 권한으로 실행)
sudo bash scripts/install-pyxis-enroot.sh

# 설치 후 Slurm 데몬 재시작
sudo systemctl restart slurmd

# Slurm 컨트롤러 재설정
sudo scontrol reconfigure

# 설치 확인
bash scripts/check-pyxis-enroot.sh
```

## 1단계: 환경 준비

### 환경 변수 설정

```bash
export DATA_PATH=/fsx/data  # FSx for Lustre 공유 파일시스템 경로
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

### Enroot Squash 파일 생성

Slurm에서 사용할 수 있도록 Docker 이미지를 Enroot 형식으로 변환:

```bash
enroot import -o /fsx/aws-megatron-lm.sqsh dockerd://aws-megatron-lm:latest
```

이 파일은 클러스터의 모든 노드에서 접근 가능한 공유 파일시스템에 저장됩니다.

## 3단계: 모델 학습

### GPT-3 모델 학습

#### 데이터 전처리

1. 학습 데이터 다운로드:

```bash
mkdir -p ${DATA_PATH}/gpt2
cd ${DATA_PATH}/gpt2/

# Oscar 데이터셋 다운로드
wget https://huggingface.co/bigscience/misc-test-data/resolve/main/stas/oscar-1GB.jsonl.xz

# GPT-2 vocab 파일 다운로드
wget https://s3.amazonaws.com/models.huggingface.co/bert/gpt2-vocab.json
wget https://s3.amazonaws.com/models.huggingface.co/bert/gpt2-merges.txt

# 압축 해제
xz -d oscar-1GB.jsonl.xz
```

2. 전처리 작업 제출:

```bash
sbatch 1.data-preprocessing.sbatch
```

3. 작업 진행 상황 모니터링:

```bash
tail -f slurm-<JOB_ID>.out
```

#### 분산 학습 실행

기본 설정(39B 파라미터)으로 학습 시작:

```bash
sbatch 2.distributed-training.sbatch
```

#### 모델 크기 커스터마이징

환경 변수를 사용하여 다양한 모델 크기 설정:

| 모델 크기 | 설정 명령 |
|----------|----------|
| 1.7B | `NUM_ATTENTION_HEADS=24 HIDDEN_SIZE=2304 NUM_LAYERS=24 sbatch 2.distributed-training.sbatch` |
| 3.6B | `NUM_ATTENTION_HEADS=32 HIDDEN_SIZE=3072 NUM_LAYERS=30 sbatch 2.distributed-training.sbatch` |
| 7.5B | `NUM_ATTENTION_HEADS=32 HIDDEN_SIZE=4096 NUM_LAYERS=36 sbatch 2.distributed-training.sbatch` |
| 18.4B | `NUM_ATTENTION_HEADS=48 HIDDEN_SIZE=6144 NUM_LAYERS=40 sbatch 2.distributed-training.sbatch` |
| 39.1B | `NUM_ATTENTION_HEADS=64 HIDDEN_SIZE=8192 NUM_LAYERS=48 sbatch 2.distributed-training.sbatch` |
| 76.1B | `NUM_ATTENTION_HEADS=80 HIDDEN_SIZE=10240 NUM_LAYERS=60 sbatch 2.distributed-training.sbatch` |
| 145.6B | `NUM_ATTENTION_HEADS=96 HIDDEN_SIZE=12288 NUM_LAYERS=80 sbatch 2.distributed-training.sbatch` |
| 310.1B | `NUM_ATTENTION_HEADS=128 HIDDEN_SIZE=16384 NUM_LAYERS=96 sbatch 2.distributed-training.sbatch` |

#### 주요 학습 파라미터

기본 39B 모델의 설정:

- **병렬화 전략**:
  - Tensor Parallel: 4
  - Pipeline Parallel: 2
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

#### 고급 설정

**벤치마크 모드 (검증/테스트 비활성화)**:

`2.distributed-training.sbatch` 파일에서 다음과 같이 수정:

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

### LLaMA2 모델 학습

#### 토크나이저 준비

1. Hugging Face에서 LLaMA2 토크나이저 다운로드:
   - https://huggingface.co/meta-llama/Llama-2-7b-hf 방문
   - 등록 후 `tokenizer.json` 및 `tokenizer.model` 파일 다운로드

2. 작업 디렉토리 생성 및 토크나이저 파일 배치:

```bash
mkdir -p ${DATA_PATH}/llama2
cp tokenizer.json tokenizer.model ${DATA_PATH}/llama2/
```

#### 데이터 전처리

1. 샘플 데이터 다운로드 및 전처리:

```bash
cd ${DATA_PATH}/llama2/

# 샘플 데이터 다운로드
wget https://huggingface.co/bigscience/misc-test-data/resolve/main/stas/oscar-1GB.jsonl.xz
xz -d oscar-1GB.jsonl.xz

# 전처리 작업 제출
sbatch data-preproc-llama2.sbatch
```

#### 분산 학습 실행

`pretrain-llama2.sbatch` 스크립트에는 여러 모델 크기 설정이 포함되어 있습니다. 원하는 모델 크기의 주석을 해제하여 선택:

**사용 가능한 모델 크기**:
- 7B 모델
- 13B 모델
- 70B 모델 (기본 활성화)

학습 시작:

```bash
sbatch pretrain-llama2.sbatch
```

#### 주요 학습 파라미터 (70B 모델)

- **병렬화 전략**:
  - Tensor Parallel: 4
  - Pipeline Parallel: 4
  - Sequence Parallel: 활성화
  - 총 16 GPU (2노드 x 8 GPU)

- **배치 크기**:
  - Micro batch: 1
  - Global batch: 2048

- **학습 하이퍼파라미터**:
  - Learning rate: 6.0e-5 (cosine decay)
  - Gradient clipping: 1.0
  - Weight decay: 0.1
  - Optimizer: AdamW (β1=0.9, β2=0.95)

- **모델 구성**:
  - Layers: 80
  - Hidden size: 8192
  - Attention heads: 64
  - Query groups: 8 (Group-Query Attention)
  - Sequence length: 4096

## 학습 모니터링 및 관리

### 작업 상태 확인

```bash
# 실행 중인 작업 확인
squeue

# 특정 작업의 로그 확인
tail -f slurm-<JOB_ID>.out

# 작업 취소
scancel <JOB_ID>
```

### Weights & Biases 통합

학습 스크립트는 Weights & Biases(wandb)를 통한 실험 추적을 지원합니다. wandb 계정이 있다면 환경 변수를 설정하세요:

```bash
export WANDB_API_KEY=<your-api-key>
```

### 체크포인트 관리

모델 체크포인트는 `${DATA_PATH}/checkpoints` 디렉토리에 자동으로 저장됩니다. HyperPod의 자동 재시작 기능을 통해 장애 발생 시 마지막 체크포인트에서 학습이 자동으로 재개됩니다.

## 성능 최적화 팁

### 1. 배치 크기 조정

GPU 메모리 활용도를 최대화하기 위해 micro batch size와 global batch size를 조정:

```bash
--micro-batch-size 1 \
--global-batch-size 288 \
```

### 2. 병렬화 전략 최적화

모델 크기와 클러스터 구성에 따라 최적의 병렬화 전략을 선택:

- **작은 모델 (< 10B)**: Tensor Parallel만 사용
- **중간 모델 (10B-100B)**: Tensor + Pipeline Parallel
- **대형 모델 (> 100B)**: Tensor + Pipeline + Sequence Parallel

### 3. Activation Recomputation

메모리 사용량을 줄이기 위해 activation recomputation 활성화:

```bash
--recompute-activations \
--recompute-granularity full \
```

### 4. 통신 최적화

```bash
# Tensor parallel 통신 오버랩
--overlap-grad-reduce \

# NCCL 최적화
export NCCL_DEBUG=INFO
export NCCL_ASYNC_ERROR_HANDLING=1
```

## 문제 해결

### 일반적인 문제

1. **OOM (Out of Memory) 에러**:
   - Micro batch size 감소
   - Gradient accumulation steps 증가
   - Activation recomputation 활성화

2. **통신 타임아웃**:
   - NCCL 타임아웃 값 증가
   - 네트워크 대역폭 확인

3. **학습 불안정**:
   - Learning rate 감소
   - Gradient clipping 값 조정
   - Warmup steps 증가

### 디버깅

NCCL 및 통신 디버깅:

```bash
export NCCL_DEBUG=INFO
export NCCL_DEBUG_SUBSYS=ALL
```

## 추가 리소스

- [Megatron-LM GitHub](https://github.com/NVIDIA/Megatron-LM)
- [AWS 분산 학습 예제](https://github.com/aws-samples/awsome-distributed-training)
- [SageMaker HyperPod 문서](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod.html)
- [FSx for Lustre 문서](https://docs.aws.amazon.com/fsx/latest/LustreGuide/what-is.html)

## 참고사항

- 이 가이드는 [aws-samples/awsome-distributed-training](https://github.com/aws-samples/awsome-distributed-training/tree/main/3.test_cases/megatron/megatron-lm) 저장소의 내용을 기반으로 작성되었습니다.
- 최신 업데이트와 추가 예제는 원본 저장소를 참고하세요.
- 실제 프로덕션 환경에서는 데이터셋, 모델 크기, 클러스터 구성에 맞게 파라미터를 조정해야 합니다.
