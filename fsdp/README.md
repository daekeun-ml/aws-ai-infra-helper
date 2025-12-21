# FSDP (Fully Sharded Data Parallel) on AWS HyperPod 한국어 가이드

## 개요

FSDP(Fully Sharded Data Parallel)는 PyTorch에서 제공하는 분산 학습 전략으로, 대규모 모델의 파라미터, 그래디언트, 옵티마이저 상태를 여러 GPU에 걸쳐 샤딩하여 메모리 효율적인 학습을 가능하게 합니다. 이 가이드는 AWS SageMaker HyperPod의 Slurm 클러스터 환경에서 FSDP를 사용하여 LLaMA 모델을 학습하는 방법을 설명합니다.

## 주요 특징

### FSDP의 장점

- **메모리 효율성**: 모델 파라미터를 여러 GPU에 분산하여 개별 GPU의 메모리 요구사항 감소
- **확장성**: 수백 개의 GPU로 쉽게 확장 가능
- **PyTorch 네이티브**: PyTorch의 표준 API와 원활하게 통합
- **유연한 샤딩 전략**: FULL_SHARD, SHARD_GRAD_OP, NO_SHARD 등 다양한 전략 지원
- **체크포인트 호환성**: HuggingFace와 호환되는 체크포인트 포맷

### 샤딩 전략

- **FULL_SHARD**: 파라미터, 그래디언트, 옵티마이저 상태 모두 샤딩 (가장 메모리 효율적)
- **SHARD_GRAD_OP**: 그래디언트와 옵티마이저 상태만 샤딩
- **NO_SHARD**: 샤딩 없이 DDP와 유사하게 동작
- **HYBRID_SHARD**: 노드 내에서만 샤딩 (노드 간 통신 최소화)

## 사전 요구사항

### 인프라 구성

1. **Slurm 클러스터**: AWS ParallelCluster 또는 SageMaker HyperPod로 구성된 Slurm 클러스터
2. **공유 파일시스템**: FSx for Lustre 또는 EFS
3. **Python 환경**: Python 3.8 이상
4. **PyTorch**: PyTorch 2.0 이상 (FSDP2는 PyTorch 2.1 이상 권장)

### 필수 패키지 설치

```bash
# UV 설치
curl -LsSf https://astral.sh/uv/install.sh | sh

# 프로젝트 의존성 동기화
uv sync
```

## 환경 준비

### 환경 변수 설정

AWS EFA(Elastic Fabric Adapter) 및 NCCL 최적화를 위한 환경 변수:

```bash
# EFA 설정
export FI_PROVIDER=efa
export FI_EFA_USE_HUGE_PAGE=0    # 메모리 부족 시 0으로 설정

# NCCL 설정
export NCCL_DEBUG=INFO
export NCCL_SOCKET_IFNAME=^docker,lo,veth,eth

# CUDA 동기화 최적화
export FI_EFA_SET_CUDA_SYNC_MEMOPS=0

# NCCL 라이브러리 경로 (CUDA 버전에 맞게 조정)
export LD_PRELOAD=/usr/local/cuda-12.8/lib/libnccl.so

# HuggingFace 타임아웃 (대규모 클러스터)
export HF_HUB_ETAG_TIMEOUT=60
```

## 단일 GPU 학습

작은 모델이나 테스트를 위해 단일 GPU에서 학습하는 경우 `train-fsdp-singlegpu.sbatch` 스크립트를 사용합니다.

### 실행 방법

```bash
sbatch train-fsdp-singlegpu.sbatch
```

### 주요 설정

- **노드 수**: 1
- **GPU 수**: 1
- **모델 크기**: 작은 LLaMA 변형 (1024 hidden, 8 layers)
- **시퀀스 길이**: 2048
- **배치 크기**: 1

이 스크립트는 UV를 사용한 환경 관리를 지원하며, 다음과 같이 환경을 자동으로 감지합니다:

```bash
# .venv가 있으면 활성화
if [ -f "$(pwd)/.venv/pyvenv.cfg" ]; then
    source $(pwd)/.venv/bin/activate
# pyproject.toml이 있으면 uv run 사용
elif [ -f "$(pwd)/pyproject.toml" ]; then
    export UV_RUN=1
fi
```

## 멀티노드 분산 학습

대규모 모델 학습을 위해 여러 노드에 걸쳐 FSDP를 사용하는 경우 `train-fsdp.sbatch` 스크립트를 사용합니다.

### 실행 방법

```bash
sbatch train-fsdp.sbatch
```

### 주요 설정

#### Slurm 설정

```bash
#SBATCH --nodes=2              # 노드 수
#SBATCH --exclusive            # 전용 노드 사용
#SBATCH --output=logs/%x_%j.out  # 로그 파일 경로
#SBATCH --error=logs/%x_%j.err   # 에러 로그 경로
```

#### GPU 설정

```bash
GPUS_PER_NODE=8  # 노드당 GPU 수
                 # G5.12xlarge: 4
                 # P4d.24xlarge: 8
                 # P5.48xlarge: 8
```

#### Torchrun 설정

```bash
declare -a TORCHRUN_ARGS=(
    --nproc_per_node=$GPUS_PER_NODE    # 노드당 프로세스 수
    --nnodes=$SLURM_JOB_NUM_NODES       # 총 노드 수
    --rdzv_id=$SLURM_JOB_ID             # Rendezvous ID
    --rdzv_backend=c10d                 # Rendezvous 백엔드
    --rdzv_endpoint=$(hostname)         # 마스터 노드 주소
)
```

#### 학습 파라미터 (LLaMA 3.2 1B)

```bash
declare -a TRAINING_ARGS=(
    --max_context_width=8192          # 최대 시퀀스 길이
    --num_key_value_heads=2           # KV 헤드 수
    --intermediate_size=8192          # FFN 중간 차원
    --hidden_width=2048               # 은닉 상태 차원
    --num_layers=16                   # 레이어 수
    --num_heads=32                    # 어텐션 헤드 수
    --model_type=llama_v3             # 모델 타입
    --tokenizer=hf-internal-testing/llama-tokenizer  # 토크나이저
    --checkpoint_freq=50              # 체크포인트 저장 주기
    --validation_freq=100             # 검증 주기
    --max_steps=100                   # 최대 학습 스텝
    --checkpoint_dir=./checkpoints    # 체크포인트 디렉토리
    --dataset=allenai/c4              # 데이터셋
    --dataset_config_name=en          # 데이터셋 설정
    --resume_from_checkpoint=./checkpoints  # 체크포인트에서 재개
    --train_batch_size=1              # 학습 배치 크기
    --val_batch_size=1                # 검증 배치 크기
    --sharding_strategy=full          # FSDP 샤딩 전략
    --offload_activations=1           # Activation offloading
)
```

### 샤딩 전략 선택

모델 크기와 메모리 제약에 따라 적절한 샤딩 전략을 선택:

| 전략 | 사용 시기 | 메모리 효율 | 통신 오버헤드 |
|------|----------|------------|--------------|
| `full` (FULL_SHARD) | 대규모 모델 (>10B) | 최고 | 높음 |
| `shard_grad_op` (SHARD_GRAD_OP) | 중간 모델 (1B-10B) | 중간 | 중간 |
| `no_shard` (NO_SHARD) | 작은 모델 (<1B) | 낮음 | 낮음 |
| `hybrid` (HYBRID_SHARD) | 멀티노드 최적화 | 높음 | 중간 |

스크립트에서 샤딩 전략 변경:

```bash
--sharding_strategy=full  # 또는 shard_grad_op, no_shard, hybrid
```

## 컨테이너 사용 (선택 사항)

Virtual Environment 대신 컨테이너를 사용하려면 다음과 같이 설정:

### 1. 컨테이너 이미지 빌드

```bash
# Dockerfile로 이미지 빌드
docker build -t pytorch-fsdp:latest .

# Enroot squash 파일 생성
enroot import -o pytorch-fsdp.sqsh dockerd://pytorch-fsdp:latest
```

### 2. sbatch 스크립트에서 컨테이너 설정

```bash
# 컨테이너 이미지 경로
export CONTAINER_IMAGE=$(pwd)/pytorch-fsdp.sqsh

# 마운트 설정
export DATA_PATH=/fsx/ubuntu
export FSX_MOUNT=$(pwd):$DATA_PATH
```

스크립트는 `CONTAINER_IMAGE` 변수가 설정되어 있으면 자동으로 컨테이너 모드로 실행됩니다:

```bash
if [ ! -z $CONTAINER_IMAGE ]; then
    declare -a ARGS=(
        --container-image $CONTAINER_IMAGE
        --container-mounts $FSX_MOUNT
    )
fi
```

## HyperPod 자동 재시작

HyperPod 클러스터는 노드 장애 시 자동으로 학습을 재개하는 기능을 제공합니다. 스크립트는 자동으로 HyperPod 환경을 감지하고 자동 재시작을 활성화합니다:

```bash
AUTO_RESUME=""
if [ -d "/opt/sagemaker_cluster" ]; then
    echo "Detected Hyperpod cluster.. enabling --auto-resume=1"
    AUTO_RESUME="--auto-resume=1"
fi
```

이 기능을 통해:
- 노드 장애 발생 시 마지막 체크포인트에서 자동 재개
- 인프라 유지보수 중 학습 중단 최소화
- 장시간 학습 작업의 안정성 향상

## 학습 모니터링

### Slurm 작업 상태 확인

```bash
# 실행 중인 작업 확인
squeue

# 특정 사용자의 작업 확인
squeue -u $USER

# 작업 상세 정보
scontrol show job <JOB_ID>
```

### 로그 확인

```bash
# 실시간 로그 확인
tail -f logs/llama3_2_1b-FSDP_<JOB_ID>.out

# 에러 로그 확인
tail -f logs/llama3_2_1b-FSDP_<JOB_ID>.err
```

### TensorBoard

학습 스크립트가 TensorBoard 로그를 생성하는 경우:

```bash
# TensorBoard 실행
tensorboard --logdir ./tensorboard_logs --port 6006

# SSH 터널링으로 로컬에서 접속
ssh -L 6006:localhost:6006 user@head-node
```

## 성능 최적화

### 1. Activation Checkpointing

메모리 사용량을 줄이기 위해 activation checkpointing 활성화:

```bash
--offload_activations=1
```

또는 Python 코드에서:

```python
from torch.distributed.fsdp import FullyShardedDataParallel as FSDP
from torch.distributed.algorithms._checkpoint.checkpoint_wrapper import (
    checkpoint_wrapper,
    CheckpointImpl,
    apply_activation_checkpointing,
)

# 특정 레이어에 checkpointing 적용
apply_activation_checkpointing(
    model,
    checkpoint_wrapper_fn=lambda submodule: checkpoint_wrapper(
        submodule, CheckpointImpl.NO_REENTRANT
    ),
    check_fn=lambda submodule: isinstance(submodule, TransformerBlock),
)
```
### 32. CPU Offloading

GPU 메모리가 부족한 경우 파라미터를 CPU로 오프로드:

```python
from torch.distributed.fsdp import CPUOffload

model = FSDP(
    model,
    cpu_offload=CPUOffload(offload_params=True),
)
```

단, CPU offloading은 학습 속도를 크게 저하시킬 수 있으므로 신중히 사용해야 합니다.

### 3. 통신 최적화

```bash
# Gradient as bucket view (메모리 효율)
export TORCH_DISTRIBUTED_DEBUG=DETAIL

# NCCL 최적화
export NCCL_ASYNC_ERROR_HANDLING=1
export NCCL_BUFFSIZE=2097152
```

## 모델 크기별 권장 설정

### 소형 모델 (< 1B)

```bash
# 설정
--sharding_strategy=no_shard
--offload_activations=0
GPUS_PER_NODE=1-4
NODES=1
```

### 중형 모델 (1B - 10B)

```bash
# 설정
--sharding_strategy=shard_grad_op
--offload_activations=1
GPUS_PER_NODE=4-8
NODES=1-2
```

### 대형 모델 (10B - 70B)

```bash
# 설정
--sharding_strategy=full
--offload_activations=1
GPUS_PER_NODE=8
NODES=2-8
```

### 초대형 모델 (> 70B)

```bash
# 설정
--sharding_strategy=full
--offload_activations=1
--cpu_offload=1  # 필요시
GPUS_PER_NODE=8
NODES=8-32
```

## 문제 해결

### 일반적인 문제

#### 1. OOM (Out of Memory)

**증상**: CUDA out of memory 에러

**해결책**:
- Micro batch size 감소: `--train_batch_size=1`
- Activation checkpointing 활성화: `--offload_activations=1`
- 샤딩 전략 변경: `--sharding_strategy=full`
- CPU offloading 활성화 (성능 저하 주의)
- 더 많은 GPU 사용

#### 2. 통신 타임아웃

**증상**: NCCL timeout, watchdog timeout

**해결책**:
```bash
# NCCL 타임아웃 증가
export NCCL_TIMEOUT=3600

# 디버그 모드 활성화
export NCCL_DEBUG=INFO
export NCCL_DEBUG_SUBSYS=INIT,GRAPH,ENV

# EFA 설정 확인
fi_info -p efa
```

#### 3. 학습 불안정

**증상**: Loss가 NaN이 되거나 발산

**해결책**:
- Learning rate 감소
- Gradient clipping 적용
- Warmup steps 증가
- 혼합 정밀도 설정 확인 (BF16 권장)

#### 4. 느린 학습 속도

**증상**: 예상보다 낮은 throughput

**해결책**:
- 배치 크기 증가 (gradient accumulation)
- Activation checkpointing 비활성화 (메모리 충분 시)
- torch.compile 사용 (PyTorch 2.0+)
- 프로파일링으로 병목 지점 파악

### HyperPod 특화 문제

#### 1. 자동 재시작 실패

**증상**: 노드 교체 후 학습이 재개되지 않음

**해결책**:
- `/opt/sagemaker_cluster` 디렉토리 존재 확인
- `--auto-resume=1` 플래그 확인
- 체크포인트가 공유 파일시스템에 저장되는지 확인
- 체크포인트 저장 권한 확인

#### 2. EFA 통신 문제

**증상**: 멀티노드 학습 시 통신 에러

**해결책**:
```bash
# EFA 드라이버 확인
fi_info -p efa

# 네트워크 인터페이스 확인
ifconfig

# 보안 그룹 설정 확인 (모든 트래픽 허용)
# NCCL 소켓 인터페이스 설정
export NCCL_SOCKET_IFNAME=^docker,lo,veth,eth
```

## 디버깅

### NCCL 디버깅

```bash
# 상세 로그
export NCCL_DEBUG=INFO
export NCCL_DEBUG_SUBSYS=ALL

# 통신 프로파일링
export NCCL_DEBUG_FILE=nccl_debug_%h_%p.txt
```

### PyTorch 디버깅

```bash
# Distributed 디버깅
export TORCH_DISTRIBUTED_DEBUG=DETAIL

# Fault handler
export PYTHONFAULTHANDLER=1

# Traceback
export TORCH_SHOW_CPP_STACKTRACES=1
```

### 프로파일링

```python
from torch.profiler import profile, ProfilerActivity

with profile(
    activities=[ProfilerActivity.CPU, ProfilerActivity.CUDA],
    record_shapes=True,
    profile_memory=True,
    with_stack=True,
) as prof:
    # 학습 코드
    pass

# 결과 저장
prof.export_chrome_trace("trace.json")
```

## 추가 리소스

- **PyTorch FSDP 문서**: https://pytorch.org/docs/stable/fsdp.html
- **PyTorch 분산 학습 튜토리얼**: https://pytorch.org/tutorials/intermediate/FSDP_tutorial.html
- **AWS HyperPod 문서**: https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod.html
- **FSDP 논문**: https://arxiv.org/abs/2304.11277
- **HuggingFace Accelerate**: https://huggingface.co/docs/accelerate/

## 참고사항

- FSDP는 PyTorch 1.11부터 지원되며, PyTorch 2.0 이상에서 안정적입니다
- FSDP2는 PyTorch 2.1 이상에서 사용 가능하며, 더 나은 성능과 기능을 제공합니다
- HyperPod의 자동 재시작 기능을 활용하면 장시간 학습의 안정성이 크게 향상됩니다
- 대규모 학습 시 체크포인트 저장 주기를 적절히 설정하여 복구 시간을 최소화하세요
- EFA를 통한 멀티노드 통신은 InfiniBand와 유사한 성능을 제공합니다

## 예제 워크플로우

### 1. 환경 설정

```bash
# 가상환경 생성 (UV 사용)
uv sync
```

### 2. 단일 GPU 테스트

```bash
# 로그 디렉토리 생성
mkdir -p logs

# 단일 GPU 학습 제출
sbatch train-fsdp-singlegpu.sbatch

# 로그 확인
tail -f logs/llama3_2_1b-FSDP_*.out
```

### 3. 멀티노드 학습

```bash
# 멀티노드 학습 제출
sbatch train-fsdp.sbatch

# 작업 상태 확인
squeue -u $USER

# 로그 확인
tail -f logs/llama3_2_1b-FSDP_*.out
```

## 라이센스

이 가이드의 예제 스크립트는 MIT-0 라이센스를 따릅니다. 자유롭게 수정하고 사용하실 수 있습니다.
