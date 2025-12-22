# Lightning Distributed Training

Qwen3 0.6B 모델을 PyTorch Lightning과 Lightning Fabric으로 분산학습하는 코드입니다.

## 빠른 시작

### PyTorch Lightning (자동화된 학습)
```bash
# Slurm 분산 학습
sbatch train.sbatch

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

## 주요 기능

- **두 가지 방식**: PyTorch Lightning (자동화) vs Lightning Fabric (수동 제어)
- **실제 데이터셋**: HuggingFace 데이터셋 또는 로컬 데이터셋 지원
- **분산 학습**: FSDP로 멀티노드/멀티GPU 지원
- **효율적 처리**: ConcatTokensDataset으로 토큰 연결
- **Mixed Precision**: 16-bit로 메모리 절약
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
| `--checkpoint_dir` | "./checkpoints" | 체크포인트 디렉토리 |

## 파일 구조

```
lightning/
├── train.py              # PyTorch Lightning 학습 스크립트
├── train_fabric.py       # Lightning Fabric 학습 스크립트
├── train.sbatch          # PyTorch Lightning Slurm 스크립트
├── train_fabric.sbatch   # Lightning Fabric Slurm 스크립트
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
- 자동 로깅 (train_loss, val_loss)
- TensorBoard 지원
- Progress bar

### Lightning Fabric
- 커스텀 로깅
- Loss, Gradient Norm, Learning Rate
- 처리량 (samples/sec)
- 진행률 (STEP x/y)

## References

- [PyTorch Lightning Documentation](https://lightning.ai/docs/pytorch/stable/)
- [Lightning Fabric Documentation](https://lightning.ai/docs/fabric/stable/)
- [Qwen3-0.6B Model](https://huggingface.co/Qwen/Qwen3-0.6B)
- [FSDP Strategy Guide](https://lightning.ai/docs/pytorch/stable/advanced/model_parallel/fsdp.html)
- [Distributed Checkpoints](https://lightning.ai/docs/fabric/stable/guide/checkpoint/distributed_checkpoint.html)
- [SLURM Cluster Training](https://lightning.ai/docs/pytorch/stable/clouds/cluster_advanced.html)
