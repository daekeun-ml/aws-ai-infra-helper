# DeepSpeed Training Setup

이 디렉토리는 DeepSpeed 기반 분산 학습 코드를 포함합니다.

## 파일 구조

```
deepspeed/
├── ds_config.json              # DeepSpeed ZeRO-2 설정 파일
├── train.sbatch                # SLURM 다중 노드 배치 스크립트
├── train-singlenode.sh         # 단일 노드 실행 스크립트
├── src/
│   ├── train_deepspeed.py      # 메인 학습 스크립트
│   ├── requirements.txt        # Python 의존성
│   └── model_utils/            # 유틸리티 모듈
│       ├── __init__.py
│       ├── arguments.py        # 명령행 인수 파서
│       ├── checkpoint.py       # 체크포인트 유틸리티
│       ├── concat_dataset.py   # 데이터셋 유틸리티
│       └── train_utils.py      # 학습 유틸리티
└── README.md                   # 이 파일
```

## 사용법

### 1. 환경 설정
```bash
uv sync
```

### 2. 단일 노드 실행

#### 로컬 실행
```bash
./train-singlenode.sh
```

#### 특정 노드에서 실행
```bash
./train-singlenode.sh ip-10-1-199-129
```

#### CUDA 버전 선택
```bash
CUDA_VERSION=12.9 ./train-singlenode.sh ip-10-1-199-129
```

### 3. 다중 노드 실행 (SLURM)
```bash
sbatch train.sbatch
```

#### CUDA 버전 선택
```bash
CUDA_VERSION=12.9 sbatch train.sbatch
```

## 설정

### DeepSpeed 설정 (ds_config.json)
모든 학습 하이퍼파라미터는 `ds_config.json`에서 중앙 관리됩니다:

```json
{
  "train_micro_batch_size_per_gpu": 1,
  "gradient_accumulation_steps": 1,
  "optimizer": {
    "type": "AdamW",
    "params": {
      "lr": 5e-5,
      "betas": [0.9, 0.95],
      "weight_decay": 0.1
    }
  },
  "scheduler": {
    "type": "WarmupCosineLR",
    "params": {
      "warmup_min_ratio": 0.0,
      "warmup_num_steps": 10,
      "cosine_min_ratio": 0.0
    }
  },
  "zero_optimization": {
    "stage": 2,
    "offload_optimizer": {
      "device": "cpu",
      "pin_memory": true
    }
  },
  "bf16": {
    "enabled": true
  }
}
```

### 스크립트 설정

#### 단일 노드 (train-singlenode.sh)
```bash
# 데이터셋 설정
DATASET="/fsx/data/wikitext-2"          # 로컬 데이터셋
DATASET_CONFIG_NAME="en"                # HuggingFace 데이터셋용
LOCAL_DATASET=true                      # true: 로컬, false: HuggingFace

# HuggingFace 데이터셋 사용 예시
# DATASET="allenai/c4"
# DATASET_CONFIG_NAME="en"
# LOCAL_DATASET=false

# 학습 설정
MAX_STEPS=100
CHECKPOINT_FREQ=50
```

#### 다중 노드 (train.sbatch)
```bash
#SBATCH --nodes=2                       # 노드 수
#SBATCH --job-name=qwen3_0_6b-DeepSpeed

# 동일한 설정 변수들 사용
LOCAL_DATASET=true
MAX_STEPS=1000
```

## 체크포인트 관리

### 자동 재시작
- 스크립트는 `checkpoints/latest` 파일을 확인하여 자동으로 최신 체크포인트에서 재시작
- 수동 재시작: `--resume_from_checkpoint checkpoints/` 매개변수 사용

### 체크포인트 구조
```
checkpoints/
├── latest                              # 최신 체크포인트 이름
├── qwen3_0_6b-500steps/               # 체크포인트 디렉토리
│   ├── mp_rank_00_model_states.pt     # 모델 상태
│   └── bf16_zero_pp_rank_*_optim_states.pt  # 옵티마이저 상태
└── zero_to_fp32.py                    # 체크포인트 변환 스크립트
```

## 모니터링

### 로그 확인
```bash
# SLURM 로그
tail -f logs/qwen3_0_6b-DeepSpeed_*.out

# 실시간 학습 진행 상황
grep -E "(Step|Loss|lr)" logs/qwen3_0_6b-DeepSpeed_*.out
```

### 성능 메트릭
- 학습 손실 및 검증 손실
- 학습률 스케줄링
- 처리량 (tokens/sec)
- GPU 메모리 사용량

## 성능 최적화

### 메모리 최적화
1. **배치 크기 조정**: `train_micro_batch_size_per_gpu` 값 조정
2. **CPU 오프로딩**: 메모리 부족 시 `offload_optimizer` 활성화
3. **그래디언트 누적**: `gradient_accumulation_steps` 증가

### 처리량 최적화
1. **통신 최적화**: `allgather_bucket_size`, `reduce_bucket_size` 조정
2. **데이터 로딩**: `num_workers` 및 `pin_memory` 설정
3. **CUDA 버전**: 최신 CUDA 버전 사용

## 문제 해결

### 일반적인 오류

#### CUDA OOM
```bash
# 배치 크기 감소
"train_micro_batch_size_per_gpu": 1

# CPU 오프로딩 활성화
"offload_optimizer": {
  "device": "cpu",
  "pin_memory": true
}
```

#### 배치 크기 불일치
- DeepSpeed가 자동으로 `train_batch_size`를 계산하므로 config에서 제거

#### 체크포인트 로딩 실패
```bash
# 체크포인트 디렉토리 확인
ls -la checkpoints/
cat checkpoints/latest

# 수동 재시작
--resume_from_checkpoint checkpoints/
```

### 디버깅
```bash
# 상세한 로그 출력
export DEEPSPEED_LOG_LEVEL=DEBUG

# NCCL 디버그 정보
export NCCL_DEBUG=INFO

# CUDA 메모리 최적화
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
```

## 환경 요구사항

- Python 3.10+
- PyTorch 2.0+
- DeepSpeed 0.14+
- CUDA 12.8+ (권장)
- 8x GPU (P4/P5 인스턴스)

## 참고 자료

- [DeepSpeed 공식 문서](https://deepspeed.readthedocs.io/)
- [ZeRO 논문](https://arxiv.org/abs/1910.02054)
- [DeepSpeed 튜토리얼](https://www.deepspeed.ai/tutorials/)
- [HuggingFace Datasets](https://huggingface.co/docs/datasets/)
