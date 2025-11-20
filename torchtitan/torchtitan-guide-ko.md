# TorchTitan on AWS HyperPod/ParallelCluster 한국어 가이드

## 개요

TorchTitan은 Meta(PyTorch 팀)에서 개발한 대규모 생성형 AI 모델 학습을 위한 PyTorch 네이티브 플랫폼입니다. 빠른 실험과 대규모 분산 학습을 위해 설계되었으며, 깔끔한 코드베이스와 쉬운 확장성을 제공합니다.

## 주요 특징

### 다차원 병렬화 지원

- **FSDP2 (Fully Sharded Data Parallel v2)**: 파라미터별 샤딩 지원
- **Tensor Parallel**: 비동기 변형 포함
- **Pipeline Parallel**: Zero-bubble 최적화 지원
- **Context Parallel**: 긴 시퀀스 학습을 위한 병렬화

### 학습 인프라

- **Meta Device 초기화**: 메모리 효율적인 모델 초기화
- **Activation Checkpointing**: 선택적 또는 전체 체크포인팅
- **분산 체크포인팅**: 비동기 저장 지원
- **torch.compile 통합**: 컴파일 최적화
- **Float8 양자화**: 메모리 및 연산 효율 향상

### 모니터링 및 디버깅

- TensorBoard 및 Weights & Biases 통합
- 성능 메트릭 (처리량, TFLOPs, MFU)
- TOML 기반 설정 파일
- CPU/GPU 프로파일링 도구

### 체크포인트 호환성

TorchTune과 상호 운용 가능한 체크포인트 포맷을 지원하여, TorchTitan으로 사전 학습한 모델을 TorchTune으로 파인튜닝할 수 있습니다.

## 설치

### 방법 1: 소스에서 설치 (권장)

```bash
git clone https://github.com/pytorch/torchtitan
cd torchtitan
pip install -r requirements.txt
pip install -e .
```

PyTorch nightly 빌드가 필요합니다.

### 방법 2: pip 설치

**Nightly 버전:**
```bash
pip install --pre torchtitan --index-url https://download.pytorch.org/whl/nightly/cu126
```

**안정 버전:**
```bash
pip install torchtitan
```

### 방법 3: conda 설치

```bash
conda install conda-forge::torchtitan
```

## AWS HyperPod에서 멀티노드 학습

### 사전 요구사항

1. **HyperPod Slurm 클러스터**: 구성된 SageMaker HyperPod 클러스터
2. **공유 파일시스템**: FSx for Lustre 또는 EFS
3. **TorchTitan 설치**: 모든 노드에 TorchTitan 및 종속성 설치
4. **토크나이저**: LLaMA 모델의 토크나이저 파일

### 토크나이저 다운로드

```bash
# Hugging Face 토큰 필요
python scripts/download_hf_assets.py \
    --repo_id meta-llama/Llama-3.1-8B \
    --assets tokenizer \
    --hf_token=<your-hf-token>
```

### 멀티노드 학습 스크립트

이 저장소의 `torchtitan_multinode.sbatch` 스크립트는 AWS HyperPod 환경에 최적화되어 있습니다.

#### 주요 설정

**Slurm 설정:**
```bash
#SBATCH --job-name=torchtitan_multi_node
#SBATCH --nodes=2              # 노드 수
#SBATCH --exclusive            # 전용 노드 사용
```

**GPU 설정:**
```bash
GPUS_PER_NODE=8                # 노드당 GPU 수
```

**네트워크 최적화 (AWS EFA):**
```bash
export FI_PROVIDER=efa                    # EFA 사용
export FI_EFA_USE_HUGE_PAGE=0            # Huge page 비활성화
export FI_EFA_SET_CUDA_SYNC_MEMOPS=0     # CUDA 메모리 동기화 최적화
export NCCL_SOCKET_IFNAME=^docker,lo,veth # 네트워크 인터페이스 설정
export NCCL_BUFFSIZE=2097152             # NCCL 버퍼 크기
```

**HuggingFace 설정:**
```bash
export HF_HUB_ETAG_TIMEOUT=60  # 대규모 클러스터에서 메타데이터 타임아웃 증가
```

**라이브러리 경로:**
```bash
export LD_LIBRARY_PATH=/opt/amazon/efa/lib:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=/usr/local/lib/:$LD_LIBRARY_PATH
```

### 학습 실행

#### 기본 실행

```bash
sbatch torchtitan_multinode.sbatch
```

#### 커스텀 설정 파일 사용

```bash
CONFIG_FILE="./train_configs/custom_config.toml" sbatch torchtitan_multinode.sbatch
```

기본 설정 파일은 `./torchtitan/models/llama3/train_configs/llama3_8b.toml`입니다.

### HyperPod 자동 재시작 지원

스크립트는 HyperPod 클러스터를 자동으로 감지하고 자동 재시작 기능을 활성화합니다:

```bash
if [ -d "/opt/sagemaker_cluster" ]; then
    echo "Detected Hyperpod cluster.. enabling --auto-resume=1"
    AUTO_RESUME="--auto-resume=1"
fi
```

이 기능을 통해 노드 장애 발생 시 마지막 체크포인트에서 자동으로 학습을 재개합니다.

## 설정 파일 (TOML)

TorchTitan은 TOML 형식의 설정 파일을 사용합니다. LLaMA 3 8B 모델의 예시:

### 모델 설정

```toml
[model]
name = "llama3"
flavor = "8B"
norm_type = "rmsnorm"
tokenizer_path = "./tokenizer.model"
```

### 병렬화 설정

```toml
[training]
tensor_parallel_degree = 2
pipeline_parallel_degree = 1
data_parallel_degree = 4  # 자동 계산: total_gpus / (tp * pp)
```

### 배치 크기 및 학습 파라미터

```toml
[training]
micro_batch_size = 1
global_batch_size = 512
max_steps = 10000

[optimizer]
name = "AdamW"
lr = 3e-4
weight_decay = 0.1
```

### 체크포인트 설정

```toml
[checkpoint]
enable_checkpoint = true
checkpoint_dir = "./checkpoints"
checkpoint_interval = 1000
async_save = true  # 비동기 저장으로 학습 중단 최소화
```

## 단일 노드 학습

단일 노드에서 8 GPU로 학습하려면:

```bash
CONFIG_FILE="./torchtitan/models/llama3/train_configs/llama3_8b.toml" ./run_train.sh
```

또는 직접 torchrun 실행:

```bash
torchrun --nproc_per_node=8 \
    -m torchtitan.train \
    --job.config_file ./torchtitan/models/llama3/train_configs/llama3_8b.toml
```

## 성능 최적화

### 1. 병렬화 전략 선택

**모델 크기별 권장 설정:**

| 모델 크기 | Tensor Parallel | Pipeline Parallel | 권장 GPU 수 |
|----------|-----------------|-------------------|------------|
| 8B       | 1-2             | 1                 | 8-16       |
| 70B      | 4-8             | 2-4               | 64-128     |
| 405B     | 8-16            | 4-8               | 256-512    |

### 2. Activation Checkpointing

메모리 사용량을 줄이기 위해 설정 파일에서 활성화:

```toml
[training]
activation_checkpoint = "selective"  # or "full"
```

### 3. Float8 양자화

메모리와 연산 속도를 개선:

```toml
[training]
enable_float8 = true
```

### 4. torch.compile

추가 성능 향상:

```toml
[training]
compile = true
compile_mode = "max-autotune"  # or "default", "reduce-overhead"
```

### 5. Context Parallel

긴 시퀀스 학습 시:

```toml
[training]
context_parallel_degree = 2
sequence_length = 8192
```

## 모니터링

### TensorBoard

```bash
tensorboard --logdir ./outputs/tensorboard
```

### Weights & Biases

설정 파일에서 활성화:

```toml
[metrics]
enable_wandb = true
wandb_project = "torchtitan-training"
wandb_entity = "your-team"
```

### 성능 메트릭

학습 중 다음 메트릭이 자동으로 로깅됩니다:

- **처리량**: tokens/second, samples/second
- **TFLOPs**: 초당 테라플롭스
- **MFU (Model FLOPs Utilization)**: 모델 FLOP 활용도
- **손실 (Loss)**: 학습 손실
- **학습률 (Learning Rate)**: 현재 학습률

## 디버깅

### NCCL 디버깅

통신 문제 해결을 위해:

```bash
export NCCL_DEBUG=INFO
export NCCL_DEBUG_SUBSYS=INIT,GRAPH,ENV
```

### Python 디버깅

```bash
export PYTHONFAULTHANDLER=1
```

### GPU 프로파일링

```bash
# 스크립트에 포함된 DCGM 프로파일링
dcgmi profile --pause   # 학습 시작 전
# ... 학습 실행 ...
dcgmi profile --resume  # 학습 종료 후
```

### PyTorch Profiler

설정 파일에서 활성화:

```toml
[profiling]
enable_profiling = true
profile_freq = 10  # 10 스텝마다 프로파일링
```

## 문제 해결

### 일반적인 문제

1. **OOM (Out of Memory)**:
   - Micro batch size 감소
   - Activation checkpointing 활성화
   - Tensor/Pipeline parallel 증가
   - Float8 양자화 사용

2. **통신 타임아웃**:
   - NCCL 타임아웃 증가
   - EFA 드라이버 확인
   - 네트워크 대역폭 모니터링

3. **토크나이저 에러**:
   - 토크나이저 파일 경로 확인
   - Hugging Face 토큰 유효성 검증
   - 파일 권한 확인

4. **체크포인트 로드 실패**:
   - 병렬화 설정이 체크포인트와 일치하는지 확인
   - 디스크 공간 확인
   - 비동기 저장 완료 대기

### HyperPod 특화 문제

1. **노드 교체 후 학습 재개 안 됨**:
   - `--auto-resume=1` 플래그 확인
   - 체크포인트 디렉토리가 공유 파일시스템에 있는지 확인

2. **EFA 통신 문제**:
   - EFA 드라이버 설치 확인: `fi_info -p efa`
   - 보안 그룹 설정 확인
   - 네트워크 인터페이스 이름 확인

## 모델 지원

TorchTitan은 다음 모델들을 기본 지원합니다:

- **LLaMA 3/3.1/3.2**: 1B, 3B, 8B, 70B, 405B
- **LLaMA 2**: 7B, 13B, 70B

각 모델은 `./torchtitan/models/llama*/train_configs/` 디렉토리에 사전 정의된 설정 파일이 있습니다.

## 성능 벤치마크

TorchTitan 논문에 따르면, 512 GPU에서 다음과 같은 성능을 달성했습니다:

- **LLaMA 3 8B**: ~55% MFU
- **LLaMA 3 70B**: ~50% MFU
- **LLaMA 3 405B**: ~42% MFU

AWS HyperPod에서는 EFA를 통해 이와 유사하거나 더 나은 성능을 기대할 수 있습니다.

## 추가 리소스

- **TorchTitan GitHub**: https://github.com/pytorch/torchtitan
- **TorchTitan 논문**: https://arxiv.org/abs/2410.06511 (ICLR 2025)
- **PyTorch 분산 학습 문서**: https://pytorch.org/tutorials/beginner/dist_overview.html
- **AWS HyperPod 문서**: https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod.html
- **TorchTune (파인튜닝)**: https://github.com/pytorch/torchtune

## 참고사항

- TorchTitan은 활발히 개발 중인 프로젝트이므로 최신 버전을 사용하는 것이 좋습니다
- 프로덕션 환경에서는 안정 버전보다 nightly 빌드를 사용하여 최신 최적화를 활용하세요
- 대규모 학습 시 비동기 체크포인팅을 활성화하여 체크포인트 저장 오버헤드를 최소화하세요
- HyperPod의 자동 재시작 기능을 활용하면 장애 복구가 자동으로 이루어집니다

## 예제 워크플로우

### 1. 환경 설정

```bash
# TorchTitan 설치
git clone https://github.com/pytorch/torchtitan
cd torchtitan
pip install -r requirements.txt
pip install -e .

# 토크나이저 다운로드
python scripts/download_hf_assets.py \
    --repo_id meta-llama/Llama-3.1-8B \
    --assets tokenizer \
    --hf_token=$HF_TOKEN
```

### 2. 단일 노드 테스트

```bash
# 8 GPU로 테스트
CONFIG_FILE="./torchtitan/models/llama3/train_configs/llama3_8b.toml" ./run_train.sh
```

### 3. 멀티노드 학습

```bash
# HyperPod에서 2노드 학습
sbatch torchtitan_multinode.sbatch
```

### 4. 모니터링

```bash
# Slurm 작업 상태 확인
squeue

# 로그 확인
tail -f slurm-<JOB_ID>.out

# TensorBoard 실행
tensorboard --logdir ./outputs/tensorboard
```

### 5. 체크포인트에서 재개

설정 파일에서 체크포인트 경로 지정:

```toml
[checkpoint]
enable_checkpoint = true
checkpoint_dir = "./checkpoints"
resume_from_checkpoint = "./checkpoints/step_1000"
```

## 라이센스

TorchTitan은 BSD 라이센스를 따릅니다. 자세한 내용은 프로젝트 저장소의 LICENSE 파일을 참조하세요.
