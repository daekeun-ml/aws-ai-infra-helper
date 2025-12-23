# FSDP2 (Fully Sharded Data Parallel 2) on AWS HyperPod 한국어 가이드

## 개요

FSDP2는 PyTorch 2.1+에서 제공하는 차세대 분산 학습 전략으로, DTensor를 기반으로 한 더 효율적이고 사용하기 쉬운 분산 학습을 제공합니다. 이 가이드는 AWS SageMaker HyperPod의 Slurm 클러스터 환경에서 FSDP2를 사용하여 Qwen 3 0.6B 모델을 학습하는 방법을 설명합니다.

## 주요 특징

### FSDP2의 장점 (FSDP1 대비)

- **DTensor 기반**: 파라미터가 DTensor로 표현되어 더 직관적인 분산 처리
- **통신 없는 샤딩**: DTensor를 통한 효율적인 상태 딕셔너리 처리
- **간단한 메타 디바이스 초기화**: 메모리 효율적인 모델 초기화
- **향상된 메모리 관리**: `recordStream` 없이 더 안정적인 메모리 관리
- **텐서 서브클래스 확장**: Float8, NF4 등 커스텀 텐서 타입 지원
- **혼합 파라미터 지원**: frozen/non-frozen 파라미터 혼합 사용 가능

### DTensor의 이점

- **자동 분산 처리**: 옵티마이저와 gradient clipping이 DTensor에서 자동으로 작동
- **일관된 API**: 단일 디바이스와 분산 학습에서 동일한 코드 사용
- **효율적인 체크포인트**: 통신 없이 분산 상태 딕셔너리 저장/로딩

## 사전 요구사항

### 인프라 구성

1. **Slurm 클러스터**: AWS ParallelCluster 또는 SageMaker HyperPod로 구성된 Slurm 클러스터
2. **공유 파일시스템**: FSx for Lustre 또는 EFS
3. **Python 환경**: Python 3.8 이상
4. **PyTorch**: PyTorch 2.1 이상 (FSDP2 지원)
5. **Pyxis+Enroot** (선택사항): 컨테이너 기반 학습을 위한 Slurm 플러그인

### 필수 패키지 설치

```bash
# PyTorch 및 관련 패키지 (2.1+ 필수)
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121

# HuggingFace 및 데이터셋
pip install transformers datasets tokenizers accelerate

# 모니터링 및 유틸리티
pip install wandb tensorboard tqdm
```

또는 UV를 사용하는 경우:

```bash
# UV 설치
curl -LsSf https://astral.sh/uv/install.sh | sh

# 프로젝트 의존성 동기화
uv sync
```

### Pyxis+Enroot 환경 설정 (선택사항)

컨테이너 기반 학습을 위한 환경 구성:

```bash
# Docker 이미지 빌드 및 Enroot 변환
./setup-pyxis.sh

# 생성된 이미지 확인
ls -lh fsdp2-training.sqsh
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

# FSDP2 최적화
export TORCH_NCCL_BLOCKING_WAIT=1

# HuggingFace 타임아웃 (대규모 클러스터)
export HF_HUB_ETAG_TIMEOUT=60
```

## FSDP2 모델 초기화

### 기본 사용법

```python
from torch.distributed.fsdp import fully_shard
from transformers import AutoModelForCausalLM

# 모델 생성
model = AutoModelForCausalLM.from_pretrained("Qwen/Qwen3-0.6B")

# 각 transformer layer에 fully_shard 적용
for module in model.modules():
    if hasattr(module, 'self_attn') and hasattr(module, 'mlp'):
        fully_shard(module)

# 루트 모델에 fully_shard 적용
fully_shard(model)

# 옵티마이저 생성 (fully_shard 후에)
optimizer = torch.optim.AdamW(model.parameters(), lr=1e-4)
```

### DTensor 파라미터 확인

```python
from torch.distributed.tensor import DTensor

# 모든 파라미터가 DTensor로 변환됨
for param in model.parameters():
    assert isinstance(param, DTensor)
    assert param.placements == (Shard(0),)  # dim-0에서 샤딩
    print(f"Local shard shape: {param.to_local().shape}")
```

## 단일 노드 학습

### 실행 방법

```bash
# 단일 노드 스크립트 실행
./train-fsdp2-singlenode.sh

# 특정 노드에서 실행
./train-fsdp2-singlenode.sh ip-10-1-199-129
```

### 주요 설정

```bash
# 모델 설정 (Qwen3-0.6B)
MODEL_TYPE="qwen3_0_6b"
TOKENIZER="Qwen/Qwen3-0.6B"

# 학습 설정
MAX_STEPS=100
CHECKPOINT_FREQ=50
TRAIN_BATCH_SIZE=1
VAL_BATCH_SIZE=1

# 모델 아키텍처 (config.json에서 가져온 정확한 값)
MAX_CONTEXT_WIDTH=8192
NUM_KEY_VALUE_HEADS=8
INTERMEDIATE_SIZE=3072
HIDDEN_WIDTH=1024
NUM_LAYERS=28
NUM_HEADS=16
```

## 멀티노드 분산 학습

### 로컬 환경 실행

```bash
sbatch train-fsdp2.sbatch
```

### Pyxis+Enroot 컨테이너 실행

```bash
sbatch train-pyxis.sbatch
```

### 주요 설정

#### Slurm 설정

```bash
#SBATCH --nodes=2              # 노드 수
#SBATCH --job-name=qwen3_0_6b-FSDP2  # 작업 이름
#SBATCH --exclusive            # 전용 노드 사용
#SBATCH --output=logs/%x_%j.out  # 로그 파일 경로
#SBATCH --error=logs/%x_%j.err   # 에러 로그 경로
```

#### 학습 파라미터 (Qwen3-0.6B)

```bash
# 모델 설정
MODEL_TYPE="qwen3_0_6b"
TOKENIZER="Qwen/Qwen3-0.6B"

# 데이터셋 설정
DATASET="/fsx/data/wikitext-2"
LOCAL_DATASET=true

# 학습 설정
MAX_STEPS=100
EPOCHS=1
LOGGING_FREQ=10
VALIDATION_FREQ=100
CHECKPOINT_FREQ=50

# 모델 아키텍처 (Qwen3-0.6B config.json 기준)
MAX_CONTEXT_WIDTH=8192
NUM_KEY_VALUE_HEADS=8
INTERMEDIATE_SIZE=3072
HIDDEN_WIDTH=1024
NUM_LAYERS=28
NUM_HEADS=16
```

## FSDP2 체크포인트 관리

### DTensor 기반 체크포인트

FSDP2는 DTensor를 사용하여 더 효율적인 체크포인트를 제공합니다:

```python
from torch.distributed.checkpoint.state_dict import (
    get_model_state_dict, 
    set_model_state_dict,
    StateDictOptions
)

# 저장
model_state_dict = get_model_state_dict(
    model=model,
    options=StateDictOptions(
        full_state_dict=True,
        cpu_offload=True,
    )
)

if rank == 0:
    torch.save(model_state_dict, "checkpoint.pt")

# 로딩
checkpoint = torch.load("checkpoint.pt", map_location='cpu')
set_model_state_dict(
    model=model,
    model_state_dict=checkpoint,
    options=StateDictOptions(
        full_state_dict=True,
        broadcast_from_rank0=True,
    ),
)
```

### 모델별 체크포인트 관리

각 모델별로 독립적인 체크포인트 추적:

```bash
# 모델별 latest 파일
checkpoints/
├── qwen3_0_6b-50steps/
├── qwen3_0_6b-100steps/
├── qwen3_0_6b-latest          # qwen3_0_6b 모델의 최신 체크포인트
└── llama-latest               # llama 모델의 최신 체크포인트
```

## 성능 최적화

### 1. 혼합 정밀도

FSDP2는 더 유연한 혼합 정밀도 정책을 제공합니다:

```python
from torch.distributed.fsdp import MixedPrecisionPolicy

# BF16 혼합 정밀도
mp_policy = MixedPrecisionPolicy(
    param_dtype=torch.bfloat16,
    reduce_dtype=torch.float32,  # 그래디언트 리듀스는 FP32
)

# 각 레이어에 적용
for module in model.modules():
    if hasattr(module, 'self_attn'):
        fully_shard(module, mp_policy=mp_policy)

fully_shard(model, mp_policy=mp_policy)
```

### 2. Prefetching 최적화

FSDP2는 implicit와 explicit prefetching을 모두 지원합니다:

```python
# Implicit prefetching (기본값, 자동 최적화)
# 별도 설정 불필요

# Explicit prefetching (고급 사용자용)
from torch.distributed.fsdp import set_modules_to_forward_prefetch

# 2개 레이어 미리 prefetch
for i, layer in enumerate(model.layers[:-2]):
    layers_to_prefetch = [model.layers[i + 1], model.layers[i + 2]]
    layer.set_modules_to_forward_prefetch(layers_to_prefetch)

# 첫 번째 all-gather를 더 일찍 시작
model.unshard()  # 학습 루프 전에 호출
```

### 3. CPU Offloading

```python
from torch.distributed.fsdp import CPUOffloadPolicy

# CPU offload 정책
cpu_offload = CPUOffloadPolicy()

for module in model.modules():
    if hasattr(module, 'self_attn'):
        fully_shard(module, offload_policy=cpu_offload)
```

## 모델 크기별 권장 설정

### 소형 모델 (< 1B) - Qwen3-0.6B

```bash
# 설정
NODES=1
GPUS_PER_NODE=1-4
TRAIN_BATCH_SIZE=2-4
MAX_CONTEXT_WIDTH=8192

# FSDP2 설정
# 기본 설정으로 충분 (자동 최적화)
```

### 중형 모델 (1B - 10B)

```bash
# 설정
NODES=1-2
GPUS_PER_NODE=4-8
TRAIN_BATCH_SIZE=1-2
MAX_CONTEXT_WIDTH=4096-8192

# FSDP2 설정
# Mixed precision 활용
# CPU offload 고려 (필요시)
```

### 대형 모델 (10B - 70B)

```bash
# 설정
NODES=2-8
GPUS_PER_NODE=8
TRAIN_BATCH_SIZE=1
MAX_CONTEXT_WIDTH=2048-4096

# FSDP2 설정
# Mixed precision 필수
# CPU offload 활용
# Explicit prefetching 고려
```

## 학습 모니터링

### 학습 진행 상황

```bash
# 실시간 로그 확인
tail -f logs/qwen3_0_6b-FSDP2_*.out

# 학습 메트릭 확인
grep -E "Loss|Speed|lr" logs/qwen3_0_6b-FSDP2_*.out

# 체크포인트 확인
ls -lh checkpoints/
cat checkpoints/qwen3_0_6b-latest
```

### 성능 메트릭

```bash
# Throughput 확인
grep "samples/sec" logs/*.out

# 메모리 사용량
grep -E "memory|CUDA" logs/*.err

# 통신 패턴 (NCCL 디버그 활성화 시)
grep -E "NCCL|all-gather|reduce-scatter" logs/*.err
```

## 문제 해결

### FSDP2 특화 문제

#### 1. DTensor 관련 오류

**증상**: DTensor 변환 또는 연산 오류

**해결책**:
```python
# DTensor 상태 확인
for param in model.parameters():
    print(f"Is DTensor: {isinstance(param, DTensor)}")
    print(f"Device mesh: {param.device_mesh}")
    print(f"Placements: {param.placements}")

# Local tensor 확인
local_param = param.to_local()
print(f"Local shape: {local_param.shape}")
```

#### 2. 체크포인트 로딩 실패

**증상**: DCP API 체크포인트 로딩 오류

**해결책**:
```bash
# 체크포인트 파일 구조 확인
ls -la checkpoints/qwen3_0_6b-50steps/

# 권한 확인
chmod -R 755 checkpoints/

# 디스크 공간 확인
df -h
```

#### 3. 메타 디바이스 초기화 오류

**증상**: `from_pretrained`에서 메타 디바이스 오류

**해결책**:
```python
# 올바른 초기화 방법
with torch.device("meta"):
    config = AutoConfig.from_pretrained("Qwen/Qwen3-0.6B")
    model = AutoModelForCausalLM.from_config(config)

# 또는 직접 로딩
model = AutoModelForCausalLM.from_pretrained("Qwen/Qwen3-0.6B")
```

### 성능 최적화 문제

#### 1. 느린 체크포인트 저장

**증상**: 체크포인트 저장 시 hang 또는 느린 속도

**해결책**:
- DCP API 사용 확인
- `cpu_offload=True` 설정
- 충분한 디스크 공간 확보
- 네트워크 파일시스템 성능 확인

#### 2. 메모리 부족

**증상**: CUDA OOM 에러

**해결책**:
```python
# Mixed precision 활용
mp_policy = MixedPrecisionPolicy(
    param_dtype=torch.bfloat16,
    reduce_dtype=torch.float32,
)

# CPU offload 활용
cpu_offload = CPUOffloadPolicy()

# 배치 크기 감소
TRAIN_BATCH_SIZE=1
```

## FSDP1에서 FSDP2 마이그레이션

### 주요 변경사항

| FSDP1 | FSDP2 | 설명 |
|-------|-------|------|
| `FullyShardedDataParallel` | `fully_shard` | 래핑 방식 변경 |
| `auto_wrap_policy` | 수동 적용 | 각 레이어에 직접 적용 |
| `param_init_fn` | `reset_parameters()` | 초기화 방식 변경 |
| `StateDictType.SHARDED_STATE_DICT` | DCP API | 체크포인트 방식 변경 |
| `MixedPrecision` | `MixedPrecisionPolicy` | 혼합 정밀도 정책 변경 |

### 마이그레이션 예제

```python
# FSDP1 (기존)
from torch.distributed.fsdp import FullyShardedDataParallel as FSDP
from torch.distributed.fsdp.wrap import transformer_auto_wrap_policy

model = FSDP(
    model,
    auto_wrap_policy=transformer_auto_wrap_policy(
        transformer_layer_cls={TransformerBlock}
    )
)

# FSDP2 (신규)
from torch.distributed.fsdp import fully_shard

for module in model.modules():
    if isinstance(module, TransformerBlock):
        fully_shard(module)
fully_shard(model)
```

## 추가 리소스

- **PyTorch FSDP2 튜토리얼**: https://pytorch.org/tutorials/intermediate/FSDP_tutorial.html
- **DTensor 문서**: https://pytorch.org/docs/stable/distributed.tensor.html
- **DCP 문서**: https://pytorch.org/docs/stable/distributed.checkpoint.html
- **AWS HyperPod 문서**: https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod.html
- **Qwen3 모델 카드**: https://huggingface.co/Qwen/Qwen3-0.6B

## 참고사항

- FSDP2는 PyTorch 2.1 이상에서만 사용 가능합니다
- DTensor를 통한 자동 분산 처리로 코드가 더 간단해졌습니다
- 체크포인트는 DCP API를 사용하여 더 효율적으로 처리됩니다
- 모델별 체크포인트 관리로 여러 모델 실험이 용이합니다
- HyperPod의 자동 재시작과 완벽하게 호환됩니다

## 예제 워크플로우

### 1. 환경 설정

```bash
# 작업 디렉토리 생성
mkdir -p ~/fsdp2-training
cd ~/fsdp2-training

# UV 환경 설정
uv init
uv add torch>=2.1 transformers datasets

# 로그 및 체크포인트 디렉토리 생성
mkdir -p logs checkpoints
```

### 2. 단일 노드 테스트

```bash
# 실행 권한 부여
chmod +x train-fsdp2-singlenode.sh

# 단일 노드 학습 실행
./train-fsdp2-singlenode.sh

# 로그 확인
tail -f logs/*.out
```

### 3. 멀티노드 학습

```bash
# 멀티노드 학습 제출
sbatch fsdp-train2.sbatch

# 작업 상태 확인
squeue -u $USER

# 실시간 로그 확인
tail -f logs/qwen3_0_6b-FSDP2_*.out
```

### 4. 체크포인트 관리

```bash
# 체크포인트 확인
ls -lh checkpoints/
cat checkpoints/qwen3_0_6b-latest

# 특정 체크포인트에서 재개
# (스크립트가 자동으로 latest 체크포인트 감지)
```

### 5. 성능 분석

```bash
# 학습 완료 후 성능 메트릭 확인
grep -E "samples/sec|Loss" logs/qwen3_0_6b-FSDP2_*.out

# 체크포인트 저장 시간 확인
grep -E "Saving|Saved" logs/qwen3_0_6b-FSDP2_*.out
```

## 라이센스

이 가이드의 예제 스크립트는 MIT-0 라이센스를 따릅니다. 자유롭게 수정하고 사용하실 수 있습니다.
