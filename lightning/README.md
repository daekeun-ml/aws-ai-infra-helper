# Lightning Distributed Training

Qwen3 0.6B 모델을 PyTorch Lightning과 Lightning Fabric으로 분산학습하는 코드입니다.

## 데이터셋 준비

학습 전에 `prepare-datasets.py`로 데이터셋을 다운로드합니다. 루트 디렉토리(`aws-ai-infra-helper/`)에서 실행하세요.

### 방법 A: 로컬 직접 다운로드 (테스트용 권장)

S3/DRA 설정 없이 `/fsx/data/`에 바로 저장합니다:

```bash
cd ..  # aws-ai-infra-helper/ 루트로 이동

# 대화형으로 데이터셋 선택 후 /fsx/data/pretrain/ 또는 /fsx/data/sft/ 에 저장
python3 prepare-datasets.py --local-only

# 저장 경로 변경 시
python3 prepare-datasets.py --local-only --local-base-dir /fsx/data
```

실행 후 선택 메뉴가 나타납니다:

```
📋 Available datasets:

🔤 Continual Pre-training datasets:
  1. wikitext-2 - Language modeling dataset (~36k samples)
  2. wikitext-103 (limited to 180,000) - Large language modeling dataset

🎯 Supervised Fine-tuning datasets:
  3. emotion - Emotion classification with 6 emotions (~20k samples)
  ...
  10. glan-qna-kr (limited to 150,000) - Korean Q&A dataset

  11. All pretrain datasets
  12. All SFT datasets
  13. All datasets
```

다운로드 완료 후 바로 사용 가능한 경로:
- Pre-training: `/fsx/data/pretrain/<dataset-name>/`
- SFT: `/fsx/data/sft/<dataset-name>/`

### 방법 B: S3 및 FSx Lustre DRA 동기화 (프로덕션 권장)

```bash
cd ..

# 1. 스택 정보 추출 및 환경변수 설정
./scripts/export-stack-outputs.sh hyperpod-cluster-name
source stack-env-vars.sh

# 2. FSx Lustre DRA 생성
./scripts/create-dra.sh

# 3. 데이터셋 다운로드 및 S3/FSx 동기화
python3 prepare-datasets.py
```

### 학습에 데이터셋 사용하기

다운로드한 데이터셋은 `--local_dataset` 플래그와 함께 경로를 지정합니다:

```bash
# wikitext-2 로컬 데이터셋으로 학습
python train.py --local_dataset --dataset="/fsx/data/pretrain/wikitext-2" --gpus=8

# SFT 데이터셋 사용 예시
python train.py --local_dataset --dataset="/fsx/data/sft/glan-qna-kr" --gpus=8
```

## 빠른 시작

### 프리셋으로 실행 (권장)

모델별 최적화된 설정이 `presets/` 폴더에 준비되어 있습니다:

```bash
# Llama-3.1-8B 벤치마크
PRESET=presets/llama3.1-8b-bench.json bash run_fabric.sh

# Qwen3-0.6B 벤치마크
PRESET=presets/qwen3-0.6b-bench.json bash run_fabric.sh

# Qwen2.5-7B 벤치마크
PRESET=presets/qwen2.5-7b-bench.json bash run_fabric.sh

# 프리셋 로드 후 일부 값 오버라이드 (예: 스텝 수 변경)
PRESET=presets/llama3.1-8b-bench.json MAX_STEPS=500 bash run_fabric.sh
```

### PyTorch Lightning (자동화된 학습)
```bash
# Slurm 분산 학습 (로컬 환경)
sbatch train.sbatch

# Slurm 분산 학습 (Pyxis+Enroot 컨테이너)
sbatch train-pyxis.sbatch

# 단일 노드 학습 예시
python train.py --gpus=8 --local_dataset --dataset="/fsx/data/pretrain/wikitext-2" --save_every_n_steps=50 --val_check_interval=50 --max_steps=100
```

### Lightning Fabric (세밀한 제어)
```bash
# Slurm 분산 학습
sbatch train_fabric.sbatch

# 단일 노드 학습 예시
python train_fabric.py --gpus=8 --local_dataset --dataset="/fsx/data/pretrain/wikitext-2" --save_every_n_steps=50 --max_steps=100
```

### Pyxis+Enroot 환경 설정

컨테이너 기반 학습을 위한 환경 구성:

```bash
# Docker 이미지 빌드 및 Enroot 변환
./setup-pyxis.sh

# 생성된 이미지 확인
ls -lh lightning-training.sqsh
```

## 주요 기능

- **두 가지 방식**: PyTorch Lightning (자동화) vs Lightning Fabric (수동 제어)
- **프리셋 관리**: 모델별 설정을 `presets/*.json`으로 분리하여 재사용
- **실제 데이터셋**: HuggingFace 데이터셋 또는 로컬 데이터셋 지원
- **분산 학습**: FSDP로 멀티노드/멀티GPU 지원
- **효율적 처리**: ConcatTokensDataset으로 토큰 연결
- **Mixed Precision**: BF16으로 메모리 절약 및 학습 안정성 향상
- **체크포인트 자동 로드**: 학습 중단 시 자동 재시작
- **상세한 로깅**: Loss, Grad Norm, LR, 처리량 등
- **Slurm 지원**: 멀티노드 클러스터 학습

## 📋 사용법

### PyTorch Lightning
```bash
python train.py \
    --nodes=1 \
    --gpus=8 \
    --epochs=3 \
    --batch_size=2 \
    --dataset="wikitext" \
    --model_name="Qwen/Qwen3-0.6B"
```

### Lightning Fabric
```bash
python train_fabric.py \
    --nodes=1 \
    --gpus=8 \
    --max_steps=1000 \
    --batch_size=2 \
    --dataset="/fsx/data/pretrain/wikitext-2" \
    --local_dataset
```

### Slurm 배치 작업
```bash
# PyTorch Lightning
sbatch train.sbatch

# Lightning Fabric
sbatch train_fabric.sbatch
```

## 파라미터

| 파라미터 | 기본값 | 설명 |
|---------|--------|------|
| `--nodes` | 1 | 노드 수 |
| `--gpus` | 1 | GPU 수 |
| `--epochs` | 1 | 에포크 수 (Lightning만) |
| `--max_steps` | 100 | 최대 스텝 수 |
| `--batch_size` | 4 | 배치 크기 |
| `--dataset` | "wikitext" | 데이터셋 이름 |
| `--model_name` | "Qwen/Qwen3-0.6B" | 모델 이름 |
| `--max_length` | 512 | 최대 시퀀스 길이 |
| `--learning_rate` | 5e-5 | 학습률 |
| `--local_dataset` | False | 로컬 데이터셋 사용 |
| `--save_every_n_steps` | 100 | 체크포인트 저장 주기 |
| `--val_check_interval` | 100 | 검증 실행 주기 (Lightning만) |
| `--checkpoint_dir` | "./checkpoints" | 체크포인트 디렉토리 |

## 프리셋

`presets/` 폴더에 모델별 벤치마크 설정이 JSON 형태로 관리됩니다.

| 프리셋 파일 | 모델 | batch_size | seq_len | 비고 |
|---|---|---|---|---|
| `llama3.1-8b-bench.json` | meta-llama/Llama-3.1-8B | 1 | 8192 | 벤치마크 (100 steps) |
| `qwen3-0.6b-bench.json` | Qwen/Qwen3-0.6B | 4 | 4096 | 벤치마크 (100 steps) |
| `qwen2.5-7b-bench.json` | Qwen/Qwen2.5-7B | 1 | 8192 | 벤치마크 (100 steps) |

### 프리셋 JSON 키

| 키 | 설명 |
|---|---|
| `model_name` | HuggingFace 모델 ID |
| `dataset` / `local_dataset` | 데이터셋 경로 / 로컬 여부 |
| `batch_size` / `max_length` | 배치 크기 / 시퀀스 길이 |
| `learning_rate` / `max_steps` | 학습률 / 총 스텝 수 |
| `save_every_n_steps` / `val_check_interval` | 체크포인트 / 검증 주기 |
| `_description` / `_parallelism` | 주석 (스크립트에 영향 없음) |

새 프리셋 추가 시 기존 JSON을 복사하여 수정하면 됩니다.

## 파일 구조

```
lightning/
├── train.py              # PyTorch Lightning 학습 스크립트
├── train_fabric.py       # Lightning Fabric 학습 스크립트
├── run.sh                # PyTorch Lightning 실행 (프리셋 지원)
├── run_fabric.sh         # Lightning Fabric 실행 (프리셋 지원)
├── presets/              # 모델별 학습 설정 프리셋
│   ├── llama3.1-8b-bench.json
│   ├── qwen3-0.6b-bench.json
│   └── qwen2.5-7b-bench.json
├── train.sbatch          # PyTorch Lightning Slurm 스크립트
├── train_fabric.sbatch   # Lightning Fabric Slurm 스크립트
├── train-pyxis.sbatch    # Pyxis+Enroot 컨테이너 학습 스크립트
├── Dockerfile            # 컨테이너 이미지 빌드용
├── setup-pyxis.sh        # Pyxis+Enroot 환경 설정 스크립트
└── README.md             # 이 파일
```

## PyTorch Lightning vs Lightning Fabric

### PyTorch Lightning
- **장점**: 자동화된 학습 루프, 콜백, 로깅
- **단점**: 제한된 커스터마이징
- **적합한 경우**: 빠른 프로토타이핑, 표준적인 학습

### Lightning Fabric  
- **장점**: 세밀한 제어, 커스텀 학습 루프
- **단점**: 수동 구현 필요
- **적합한 경우**: 복잡한 학습 로직, 연구용

## 체크포인트

- 자동 체크포인트 저장 및 로드
- `latest.txt`에 최신 체크포인트 경로 저장
- 분산 체크포인트로 메모리 효율적 저장
- 학습 중단 시 자동 재시작

## 로깅

### PyTorch Lightning
- 자동 로깅 (train_loss, val_loss, tps, tflops)
- TensorBoard 지원
- Progress bar (Loss, TPS, TFLOPs/s 실시간 표시)

### Lightning Fabric
- 커스텀 로깅
- Loss, Gradient Norm, Learning Rate
- 처리량 (Samples/sec, TPS, TFLOPs/s)
- 진행률 (STEP x/y)
- 시작 시 모델 파라미터 수 출력

## References

- [PyTorch Lightning Documentation](https://lightning.ai/docs/pytorch/stable/)
- [Lightning Fabric Documentation](https://lightning.ai/docs/fabric/stable/)
- [Qwen3-0.6B Model](https://huggingface.co/Qwen/Qwen3-0.6B)
- [Qwen2.5-7B Model](https://huggingface.co/Qwen/Qwen2.5-7B)
- [Llama-3.1-8B Model](https://huggingface.co/meta-llama/Llama-3.1-8B)
- [FSDP Strategy Guide](https://lightning.ai/docs/pytorch/stable/advanced/model_parallel/fsdp.html)
- [Distributed Checkpoints](https://lightning.ai/docs/fabric/stable/guide/checkpoint/distributed_checkpoint.html)
- [SLURM Cluster Training](https://lightning.ai/docs/pytorch/stable/clouds/cluster_advanced.html)
