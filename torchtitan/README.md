# torchtitan on AWS

[torchtitan](https://github.com/pytorch/torchtitan)은 Meta/PyTorch 팀이 개발한 PyTorch 네이티브 대규모 언어 모델 사전 학습 플랫폼입니다. 이 디렉토리는 AWS 환경(EC2, HyperPod)에서 torchtitan을 실행하는 방법을 다룹니다.

## 개요

torchtitan은 다음 특징을 가집니다:

- **PyTorch 네이티브**: FSDP2, Tensor Parallel, Pipeline Parallel 등 PyTorch 내장 분산 학습 기능 활용
- **다양한 모델 지원**: Llama 3/4, Qwen3, DeepSeek-V3, GPT, Flux 등
- **확장 가능한 구조**: `torchtitan/models/`에 새 모델 추가 용이, `torchtitan/experiments/`에서 실험적 기능 제공
- **AWS 최적화**: EFA(Elastic Fabric Adapter), NCCL 설정 등 AWS 인프라에 맞게 구성

### 지원 모델

| 모듈 (`--module`) | 설정 예시 (`--config`) |
|---|---|
| `llama3` | `llama3_debugmodel`, `llama3_8b`, `llama3_70b`, `llama3_405b` |
| `llama4` | `llama4_debugmodel`, `llama4_17bx128e`, `llama4_17bx16e` |
| `qwen3` | `qwen3_debugmodel`, `qwen3_0_6b`, `qwen3_14b`, `qwen3_32b`, `qwen3_235b_a22b` |
| `deepseek_v3` | `deepseek_v3_debugmodel`, `deepseek_v3_16b`, `deepseek_v3_671b` |
| `gpt_oss` | `gpt_oss_debugmodel`, `gpt_oss_20b`, `gpt_oss_120b` |
| `flux` | `flux_debugmodel`, `flux_dev`, `flux_schnell` |

### 실험적 모듈

| 모듈 | 설명 |
|---|---|
| `rl` | GRPO 강화학습 (`rl_grpo_qwen3_0_6b` 등) |
| `vlm` | 비전-언어 모델 학습 |
| `autoparallel.llama3` | 자동 병렬화 실험 |
| `ft.llama3` | TorchFT 기반 Fault Tolerant 학습 |
| `graph_trainer` | torch.compile 기반 GraphTrainer |

## Getting Started

### 환경 요구사항

- Python 3.10+
- PyTorch 2.x (`torch==2.11.0` 이상 권장)
- CUDA 지원 GPU (A100, H100, H200 등)
- `torchtitan==0.2.2`, `torchao` 설치 필요

### 설치

```bash
# torchtitan 패키지 설치 (pip)
pip install torchtitan
```

### 토크나이저 준비

Llama3 계열 모델의 경우 HuggingFace에서 토크나이저를 다운로드해야 합니다:

```bash
# Llama 3.1 8B 토크나이저/체크포인트 다운로드
python scripts/download_hf_assets.py --repo_id meta-llama/Llama-3.1-8B --save_dir ./assets/hf/Llama-3.1-8B

# config_registry의 hf_assets_path와 경로가 일치해야 함
# llama3_8b config는 ./assets/hf/Llama-3.1-8B 참조
```

`debugmodel` 설정은 별도 다운로드 없이 `./tests/assets/tokenizer`를 사용하므로 즉시 실행 가능합니다.

## run_train.sh 사용법

`run_train.sh`는 로컬 단일 노드 학습을 위한 스크립트입니다. `torchrun`을 사용하여 다중 GPU 학습을 실행합니다.

### 기본 사용법

```bash
# 기본 실행 (llama3 debugmodel, 8 GPU)
./run_train.sh

# 모델과 설정을 지정하여 실행
MODULE=llama3 CONFIG=llama3_8b ./run_train.sh

# GPU 수 조정
NGPU=4 MODULE=qwen3 CONFIG=qwen3_0_6b ./run_train.sh
```

### 환경변수 옵션

| 변수 | 기본값 | 설명 |
|---|---|---|
| `NGPU` | `8` | 사용할 GPU 수 |
| `MODULE` | `llama3` | 모델 모듈 이름 |
| `CONFIG` | `llama3_debugmodel` | 학습 설정 이름 |
| `LOG_RANK` | `0` | 로그를 출력할 rank (쉼표로 복수 지정 가능) |
| `COMM_MODE` | `""` | 디버그용 통신 모드 (`fake_backend`, `local_tensor`) |
| `TORCHFT_LIGHTHOUSE` | `http://localhost:29510` | TorchFT lighthouse 주소 |

### 추가 인자 전달

`run_train.sh` 뒤에 `torchtitan.train`에 전달할 추가 인자를 넣을 수 있습니다:

```bash
# 학습 스텝 수 오버라이드
./run_train.sh --training.steps 500

# 체크포인트 저장 경로 지정
MODULE=llama3 CONFIG=llama3_8b ./run_train.sh --checkpoint.folder /fsx/checkpoints/llama3-8b

# 체크포인트 저장 주기 및 경로 함께 지정
MODULE=llama3 CONFIG=llama3_8b ./run_train.sh \
    --checkpoint.folder /fsx/checkpoints/llama3-8b \
    --checkpoint.interval 500
```

### 디버그 모드 (COMM_MODE)

실제 GPU 실행 없이 설정만 검증하거나 단일 GPU로 분산 로직을 테스트할 수 있습니다:

```bash
# fake_backend: GPU 없이 설정 유효성 검증 (dry-run)
# 실제 NCCL 통신 없이 설정과 모델 구조만 확인, 1 step만 실행
NGPU=32 COMM_MODE="fake_backend" MODULE=llama3 CONFIG=llama3_70b ./run_train.sh

# local_tensor: 단일 GPU에서 분산 학습 로직 시뮬레이션
# 실제 분산 통신 없이 전체 학습 워크플로우 디버깅, 1 step만 실행
NGPU=32 COMM_MODE="local_tensor" MODULE=llama3 CONFIG=llama3_8b ./run_train.sh
```

### 로그 필터링

```bash
# rank 0과 1의 로그만 출력
LOG_RANK=0,1 NGPU=8 ./run_train.sh
```

## Slurm으로 실행하기 (train.sbatch)

`train.sbatch`는 AWS HyperPod 또는 Slurm 클러스터에서 단일/다중 노드 학습을 실행하는 sbatch 스크립트입니다.

### 기본 사용법

```bash
# 단일 노드 (기본값: llama3_8b)
sbatch --nodes=1 train.sbatch

# 다중 노드
sbatch --nodes=4 train.sbatch
```

노드 수에 따라 torchrun 인자가 자동으로 구성됩니다:
- **1 노드**: `--standalone` 모드 사용
- **복수 노드**: `--rdzv_backend=c10d`, 헤드 노드를 rendezvous endpoint로 사용

### 모델/설정 오버라이드

```bash
# Llama3 70B, 2 노드
MODULE=llama3 CONFIG=llama3_70b sbatch --nodes=2 train.sbatch

# Qwen3 8B, 1 노드
MODULE=qwen3 CONFIG=qwen3_8b sbatch --nodes=1 train.sbatch

# Llama4 Scout, 4 노드
MODULE=llama4 CONFIG=llama4_scout sbatch --nodes=4 train.sbatch

# DeepSeek-V3 671B, 8 노드
MODULE=deepseek_v3 CONFIG=deepseek_v3_671b sbatch --nodes=8 train.sbatch
```

### sbatch 주요 옵션

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `--nodes` | `1` | 노드 수 |
| `--job-name` | `torchtitan` | Slurm 작업 이름 |
| `--exclusive` | 설정됨 | 노드 전용 사용 (다른 작업과 공유 안 함) |

### AWS HyperPod 자동 재시작

스크립트는 HyperPod 클러스터(`/opt/sagemaker_cluster` 존재 여부)를 자동 감지하여 `--auto-resume=1`을 활성화합니다. 노드 장애 시 학습을 자동으로 재시작합니다.

```bash
# HyperPod에서는 동일하게 실행하면 자동 재시작 포함
sbatch --nodes=4 train.sbatch
```

### 환경변수 (AWS 최적화)

`train.sbatch` 내부에 AWS 환경에 최적화된 환경변수들이 미리 설정되어 있습니다:

| 변수 | 값 | 설명 |
|---|---|---|
| `FI_PROVIDER` | `efa` | AWS EFA 네트워크 어댑터 사용 |
| `FI_EFA_SET_CUDA_SYNC_MEMOPS` | `0` | FSDP 처리량 향상 (CUDA sync memops 비활성화) |
| `NCCL_BUFFSIZE` | `2097152` | NCCL 버퍼 크기 (2MB) |
| `NCCL_DEBUG` | `WARN` | NCCL 로그 레벨 |
| `HF_HUB_ETAG_TIMEOUT` | `60` | 대규모 클러스터용 HF 메타데이터 타임아웃 (초) |

### 작업 상태 확인

```bash
# 작업 목록 확인
squeue -u $USER

# 특정 작업 로그 확인
tail -f slurm-<JOB_ID>.out

# 작업 취소
scancel <JOB_ID>
```

## 체크포인트 관리

```bash
# 체크포인트를 저장하며 학습
MODULE=llama3 CONFIG=llama3_8b ./run_train.sh \
    --checkpoint.folder /fsx/checkpoints/llama3-8b \
    --checkpoint.interval 500

# 체크포인트에서 재시작
MODULE=llama3 CONFIG=llama3_8b ./run_train.sh \
    --checkpoint.folder /fsx/checkpoints/llama3-8b \
    --checkpoint.load_step 500
```

Slurm에서도 동일하게 추가 인자를 붙일 수 있습니다:

```bash
MODULE=llama3 CONFIG=llama3_8b sbatch --nodes=2 train.sbatch \
    -- --checkpoint.folder /fsx/checkpoints/llama3-8b --checkpoint.interval 500
```

## 디렉토리 구조

```
torchtitan/
├── run_train.sh              # 로컬 단일 노드 학습 실행 스크립트
├── train.sbatch              # Slurm 멀티노드 학습 스크립트
├── multinode_trainer.slurm   # 레거시 멀티노드 Slurm 스크립트
├── torchtitan/
│   ├── train.py              # 학습 진입점
│   ├── trainer.py            # Trainer 클래스
│   ├── models/               # 모델 정의 (llama3, llama4, qwen3, deepseek_v3, ...)
│   ├── experiments/          # 실험적 기능 (rl, vlm, autoparallel, ft, ...)
│   ├── components/           # 공통 컴포넌트 (checkpoint, optimizer, metrics, ...)
│   ├── config/               # 설정 데이터클래스
│   └── distributed/          # 분산 학습 유틸리티
├── scripts/
│   ├── download_hf_assets.py # HuggingFace 모델/토크나이저 다운로드
│   ├── checkpoint_conversion/ # 체크포인트 변환 도구
│   └── generate/             # 생성(inference) 스크립트
├── benchmarks/               # 커뮤니티 벤치마크 결과
└── assets/                   # 이미지 등 정적 자산
```

## 참고 자료

- [torchtitan GitHub](https://github.com/pytorch/torchtitan)
- [AWS HyperPod 문서](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod.html)
- [PyTorch FSDP2 문서](https://pytorch.org/docs/stable/fsdp.html)
