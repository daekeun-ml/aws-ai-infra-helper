# AWS AI Infra helper for SageMaker HyperPod and ParallelCluster

AWS SageMaker HyperPod 및 ParallelCluster를 위한 헬퍼 스크립트 및 가이드 모음입니다. HPC 클러스터에서 대규모 분산 학습 및 추론을 쉽게 시작할 수 있습니다.

## What's New

### v1.0.1 (2025-12-21)
- **FSDP2 지원 추가**: PyTorch 2.5+ FSDP2 기반 분산 학습 예제 및 가이드
- **DeepSpeed 통합**: DeepSpeed ZeRO 기반 대규모 모델 학습 샘플 추가
- **Qwen 3 0.6B 테스트**: 최신 Qwen 3 0.6B 모델 학습 및 추론 예제 (p4/p5 인스턴스 권장)
- **성능 최적화**: 최신 GPU 인스턴스 타입에 최적화된 설정 및 가이드

## 개요

이 저장소는 다음을 제공합니다:

- **클러스터 관리 스크립트**: HyperPod 클러스터 연결 및 설정 도구
- **분산 학습 예제**: FSDP, Megatron-LM, TorchTitan을 사용한 대규모 모델 학습
- **검증 및 설치 스크립트**: 클러스터 환경 검증 및 필수 도구 설치
- **한국어 가이드**: 각 프레임워크별 상세한 한국어 문서

## 기술 스택

- **AWS 서비스**: SageMaker HyperPod (w/ Slurm), AWS ParallelCluster
- **분산 학습 프레임워크**: PyTorch FSDP, Megatron-LM, TorchTitan
- **컨테이너 런타임**: Pyxis/Enroot (Slurm 컨테이너 지원)
- **네트워크**: AWS EFA (Elastic Fabric Adapter)

## 프로젝트 구조

```
aws-ai-infra-helper/
├── scripts/              # 유틸리티 스크립트
│   ├── hyperpod-connect.sh       # SSM 기반 HyperPod 연결
│   ├── hyperpod-ssh.sh           # SSH 기반 HyperPod 연결
│   ├── check-fsx.sh              # FSx for Lustre 검증
│   ├── check-munged.sh           # Slurm 연결 검증
│   ├── check-pyxis-enroot.sh     # Pyxis/Enroot 설치 검증
│   ├── install-pyxis-enroot.sh   # 컨테이너 지원 설치
│   ├── install-nccl-efa.sh       # NCCL/EFA 설치
│   ├── fix-cuda-version.sh       # CUDA 버전 확인 및 수정
│   └── generate-nccl-test.sh     # NCCL 테스트 생성
│
├── fsdp/                 # PyTorch FSDP 예제
│   ├── fsdp-guide-ko.md          # FSDP 한국어 가이드
│   ├── fsdp-train.sbatch         # 멀티노드 학습 스크립트
│   ├── fsdp-train-single-gpu.sbatch  # 단일 GPU 학습 스크립트
│   ├── pyproject.toml            # Python 프로젝트 설정
│   └── src/
│       ├── train.py              # FSDP 학습 스크립트
│       ├── requirements.txt      # Python 의존성
│       └── model_utils/          # 모델 유틸리티
│
├── megatron/             # Megatron-LM 예제
│   └── megatron-lm-guide-ko.md   # Megatron-LM 한국어 가이드
│
├── torchtitan/           # TorchTitan 예제
│   ├── torchtitan-guide-ko.md    # TorchTitan 한국어 가이드
│   └── torchtitan-multinode.sbatch  # 멀티노드 학습 스크립트
│
├── observability/        # 모니터링 및 관찰성 도구
│   ├── install_observability.py  # 통합 설치 스크립트
│   ├── run-observability.sh      # 관찰성 도구 실행
│   ├── stop_observability.py     # 관찰성 도구 중지
│   ├── install_node_exporter.sh  # Node Exporter 설치
│   ├── install_dcgm_exporter.sh  # DCGM Exporter 설치
│   ├── install_efa_exporter.sh   # EFA Exporter 설치
│   ├── install_slurm_exporter.sh # Slurm Exporter 설치
│   ├── install_otel_collector.sh # OpenTelemetry Collector 설치
│   ├── otel_config/              # OTel 설정 파일
│   └── dcgm_metrics_config/      # DCGM 메트릭 설정
│
└── eks/                  # EKS 관련 도구 및 가이드
    ├── training/         # EKS 학습 클러스터 설정
    │   ├── README.md             # EKS 학습 가이드
    │   ├── 1.create-config.sh    # 환경 설정 생성
    │   ├── 2.setup-eks-access.sh # EKS 접근 권한 설정
    │   ├── 3.validate-cluster.sh # 클러스터 검증
    │   └── check-nodegroup.sh    # NodeGroup 정보 확인
    │
    └── inference/        # EKS 추론 엔드포인트
        ├── README.md             # 추론 배포 가이드
        ├── deploy_S3_inference_operator.yaml
        ├── deploy_fsx_lustre_inference_operator.yaml
        └── copy_to_fsx_lustre.yaml
```

## 빠른 시작

### 1. 클러스터 연결

#### SSM을 통한 연결 (권장)

```bash
# 헤드 노드 연결
./scripts/hyperpod-connect.sh

# 특정 클러스터 지정
./scripts/hyperpod-connect.sh --cluster-name my-cluster
```

#### SSH를 통한 연결

```bash
./scripts/hyperpod-ssh.sh --cluster-name my-cluster
```

### 2. 환경 검증

```bash
# FSx for Lustre 마운트 확인
./scripts/check-fsx.sh

# Slurm 연결 확인
./scripts/check-munged.sh

# Pyxis/Enroot 설치 확인 (컨테이너 사용 시)
./scripts/check-pyxis-enroot.sh
```

### 3. 필수 도구 설치

```bash
# Pyxis 및 Enroot 설치 (컨테이너 런타임)
sudo ./scripts/install-pyxis-enroot.sh

# NCCL 및 EFA 라이브러리 설치
./scripts/install-nccl-efa.sh
```

## 분산 학습 프레임워크

### FSDP (Fully Sharded Data Parallel)

PyTorch 네이티브 분산 학습 프레임워크로, 메모리 효율적인 대규모 모델 학습을 지원합니다.

**주요 특징:**
- PyTorch 표준 API와 원활한 통합
- 유연한 샤딩 전략 (FULL_SHARD, SHARD_GRAD_OP, NO_SHARD, HYBRID_SHARD)
- Activation checkpointing 및 CPU offloading
- HuggingFace 체크포인트 호환성

**시작하기:**
```bash
cd fsdp

# 단일 GPU 테스트
sbatch fsdp-train-single-gpu.sbatch

# 멀티노드 학습
sbatch fsdp-train.sbatch
```

**상세 가이드:** [fsdp/fsdp-guide-ko.md](fsdp/fsdp-guide-ko.md)

### Megatron-LM

NVIDIA에서 개발한 대규모 언어 모델 학습 프레임워크입니다.

**주요 특징:**
- Tensor Parallel, Pipeline Parallel, Data Parallel
- Sequence Parallel 및 Group-Query Attention
- 최적화된 Transformer 구현
- GPT, LLaMA 모델 지원

**시작하기:**
```bash
cd megatron

# 데이터 전처리
sbatch 1.data-preprocessing.sbatch

# 분산 학습
sbatch 2.distributed-training.sbatch
```

**상세 가이드:** [megatron/megatron-lm-guide-ko.md](megatron/megatron-lm-guide-ko.md)

### TorchTitan

Meta(PyTorch 팀)에서 개발한 최신 대규모 모델 학습 플랫폼입니다.

**주요 특징:**
- FSDP2 (Fully Sharded Data Parallel v2)
- Tensor/Pipeline/Context Parallel
- Float8 양자화 및 torch.compile 통합
- Zero-bubble Pipeline Parallel
- TensorBoard 및 Weights & Biases 통합

**시작하기:**
```bash
cd torchtitan

# 멀티노드 학습
sbatch torchtitan-multinode.sbatch

# 커스텀 설정 파일 사용
CONFIG_FILE="./custom_config.toml" sbatch torchtitan-multinode.sbatch
```

**상세 가이드:** [torchtitan/torchtitan-guide-ko.md](torchtitan/torchtitan-guide-ko.md)

## 유틸리티 스크립트

### 클러스터 연결

| 스크립트 | 설명 | 사용법 |
|---------|------|-------|
| `hyperpod-connect.sh` | SSM 기반 HyperPod 연결 | `./scripts/hyperpod-connect.sh [--cluster-name NAME]` |
| `hyperpod-ssh.sh` | SSH 기반 HyperPod 연결 | `./scripts/hyperpod-ssh.sh --cluster-name NAME` |

### 검증 스크립트

| 스크립트 | 설명 | 사용법 |
|---------|------|-------|
| `check-fsx.sh` | FSx for Lustre 마운트 확인 | `./scripts/check-fsx.sh` |
| `check-munged.sh` | Slurm 연결 확인 | `./scripts/check-munged.sh` |
| `check-pyxis-enroot.sh` | Pyxis/Enroot 설치 확인 | `./scripts/check-pyxis-enroot.sh` |

### 설치 스크립트

| 스크립트 | 설명 | 사용법 |
|---------|------|-------|
| `install-pyxis-enroot.sh` | Pyxis/Enroot 설치 | `sudo ./scripts/install-pyxis-enroot.sh` |
| `install-nccl-efa.sh` | NCCL 및 EFA 라이브러리 설치 | `./scripts/install-nccl-efa.sh` |

### 기타 도구

| 스크립트 | 설명 | 사용법 |
|---------|------|-------|
| `fix-cuda-version.sh` | CUDA 버전 확인 및 수정 | `./scripts/fix-cuda-version.sh` |
| `generate-nccl-test.sh` | NCCL 테스트 생성 | `./scripts/generate-nccl-test.sh` |

## NCCL 테스트

클러스터의 네트워크 성능을 테스트하려면:

```bash
# NCCL 테스트 스크립트 생성
./scripts/generate-nccl-test.sh

# 생성된 스크립트 실행
sbatch nccl-test.sbatch
```

## 환경 변수 설정

대부분의 학습 스크립트는 AWS EFA 및 NCCL 최적화를 위한 환경 변수를 포함합니다:

```bash
# EFA 설정
export FI_PROVIDER=efa
export FI_EFA_USE_HUGE_PAGE=0
export FI_EFA_SET_CUDA_SYNC_MEMOPS=0

# NCCL 설정
export NCCL_DEBUG=INFO
export NCCL_SOCKET_IFNAME=^docker,lo,veth,eth

# CUDA 라이브러리
export LD_PRELOAD=/usr/local/cuda-12.8/lib/libnccl.so

# HuggingFace 타임아웃
export HF_HUB_ETAG_TIMEOUT=60
```

## HyperPod 자동 재시작

모든 학습 스크립트는 HyperPod의 자동 재시작 기능을 지원합니다. 노드 장애 시 마지막 체크포인트에서 자동으로 학습을 재개합니다.

```bash
# 자동 재시작 활성화 (스크립트에 포함됨)
if [ -d "/opt/sagemaker_cluster" ]; then
    AUTO_RESUME="--auto-resume=1"
fi
```

## 일반적인 Slurm 명령어

```bash
# 작업 제출
sbatch script.sbatch

# 작업 상태 확인
squeue
squeue -u $USER

# 작업 취소
scancel <JOB_ID>

# 노드 정보
sinfo
sinfo -N -l

# 작업 상세 정보
scontrol show job <JOB_ID>

# 파티션 정보
scontrol show partition
```

## 문제 해결

### 연결 문제

```bash
# SSM 세션이 시작되지 않는 경우
aws ssm describe-instance-information

# SSH 연결이 안 되는 경우
# 보안 그룹에서 SSH 포트(22) 허용 확인
```

### Slurm 문제

```bash
# Slurm 데몬 상태 확인
sudo systemctl status slurmd

# Slurm 컨트롤러 확인
sudo systemctl status slurmctld

# 로그 확인
sudo journalctl -u slurmd -f
```

### 네트워크 문제

```bash
# EFA 드라이버 확인
fi_info -p efa

# 네트워크 인터페이스 확인
ifconfig

# NCCL 테스트
./scripts/generate-nccl-test.sh
sbatch nccl-test.sbatch
```

### GPU 문제

```bash
# GPU 상태 확인
nvidia-smi

# CUDA 버전 확인
nvcc --version

# CUDA 버전 수정 (필요시)
./scripts/fix-cuda-version.sh
```

## 모범 사례

1. **공유 파일시스템 사용**: 모든 노드에서 접근 가능한 FSx for Lustre 사용
2. **체크포인트 저장**: 정기적으로 체크포인트를 저장하여 장애 복구 시간 최소화
3. **로그 관리**: 로그 디렉토리를 미리 생성하고 적절한 권한 설정
4. **환경 검증**: 학습 시작 전 환경 검증 스크립트 실행
5. **리소스 모니터링**: `squeue`, `nvidia-smi`, `htop` 등으로 리소스 사용량 모니터링
6. **배치 크기 최적화**: GPU 메모리를 최대한 활용하도록 배치 크기 조정
7. **자동 재시작 활용**: HyperPod의 자동 재시작 기능으로 안정성 향상

## 성능 최적화 팁

### 네트워크 최적화

- EFA 사용 (Enhanced Networking)
- NCCL 버퍼 크기 조정: `export NCCL_BUFFSIZE=2097152`
- 비동기 에러 처리: `export NCCL_ASYNC_ERROR_HANDLING=1`

### 메모리 최적화

- Activation checkpointing 활성화
- 혼합 정밀도 학습 (BF16/FP16)
- Gradient accumulation으로 효과적인 배치 크기 증가
- 필요시 CPU offloading (성능 저하 주의)

### 연산 최적화

- torch.compile 사용 (PyTorch 2.0+)
- Flash Attention 활용
- 최적의 병렬화 전략 선택 (TP, PP, DP 조합)

## 기여하기

이슈 및 풀 리퀘스트를 환영합니다!

## 주의사항

- `src/legacy` 디렉토리의 파일은 수정하지 마세요
- `main` 브랜치에 직접 커밋하지 마세요
- 새로운 스크립트 추가 시 실행 권한 설정: `chmod +x script.sh`

## 라이센스

MIT-0 License - 자유롭게 사용, 수정, 배포 가능합니다.

## 추가 리소스

### AWS 문서
- [SageMaker HyperPod 문서](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod.html)
- [AWS ParallelCluster 가이드](https://docs.aws.amazon.com/parallelcluster/)
- [FSx for Lustre 문서](https://docs.aws.amazon.com/fsx/latest/LustreGuide/)
- [EFA 사용자 가이드](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)

### 분산 학습 리소스
- [PyTorch 분산 학습 문서](https://pytorch.org/tutorials/beginner/dist_overview.html)
- [PyTorch FSDP 문서](https://pytorch.org/docs/stable/fsdp.html)
- [Megatron-LM GitHub](https://github.com/NVIDIA/Megatron-LM)
- [TorchTitan GitHub](https://github.com/pytorch/torchtitan)

### Slurm 리소스
- [Slurm 공식 문서](https://slurm.schedmd.com/)
- [Pyxis GitHub](https://github.com/NVIDIA/pyxis)
- [Enroot GitHub](https://github.com/NVIDIA/enroot)

