# AWS AI Infra helper for SageMaker HyperPod and ParallelCluster

AWS SageMaker HyperPod 및 ParallelCluster를 위한 헬퍼 스크립트 및 가이드 모음입니다. HPC 클러스터에서 대규모 분산 학습 및 추론을 쉽게 시작할 수 있습니다.

## 🚀 What's New
### v1.0.10
- **전반적인 코드 리팩토링**: FSDP2, Lightning 학습 스크립트 및 인자 처리 코드 정리
- **TorchTitan 가이드 대폭 변경**: 새로운 디렉토리 구조로 재편, 벤치마크/스크립트/멀티노드 학습 파일 추가
- **Lightning 학습 지표 개선**: TPS(Tokens Per Second) 및 TFLOPs/s 실시간 모니터링 추가 (train.py, train_fabric.py)

<details>
<summary>클릭하여 전체 업데이트 내역 보기</summary>

### v1.0.9
- **Workshop Studio 지원 강화**: Workshop Studio의 저사양 GPU 리소스(예: `ml.g5.2xlarge`)에서도 핸즈온 가능하도록 개선

### v1.0.8
- **HyperPod EKS Training 핸즈온 추가**: EKS 기반 분산 학습 클러스터 설정 및 운영 가이드
- **Inference 핸즈온 워크샵 최적화**: Workshop Studio 환경에 맞춘 추론 실습 가이드 및 자동화 스크립트 개선

### v1.0.7
- **HyperPod EKS Task Governance 핸즈온 추가**: 팀과 프로젝트 간의 리소스 할당을 간소화하고 컴퓨팅 리소스의 효율적인 활용을 보장하는 관리 환경 구성
- **HyperPod EKS Workshop Stduio (실습용 임시 계정) 실습을 위한 가이드 및 코드 추가**

### v1.0.6
- **HyperPod EKS Inference 핸즈온 추가**: HyperPod Inference Operator를 활용한 Kubernetes 기반 AI/ML 모델 추론 환경 구성
  - **Basic 추론 환경**: FSx Lustre 및 S3 CSI 기반 모델 배포, 자동화 스크립트 제공
  - **KV Cache & Intelligent Routing**: Managed Tiered KV Cache와 Intelligent Routing을 활용한 고성능 추론 최적화

### v1.0.5
- **FSDP2 & Lightning Pyxis+Enroot 지원**: 컨테이너 기반 분산 학습 환경을 FSDP2와 Lightning에도 확장

### v1.0.4
- **DeepSpeed Pyxis+Enroot 지원**: 컨테이너 기반 분산 학습 환경 구성

### v1.0.3
- **Lightning 분산 학습 추가**: PyTorch Lightning과 Lightning Fabric을 활용한 이중 프레임워크 지원

### v1.0.2
- **데이터셋 관리 개선**: 한국어 Q&A 데이터셋(glan-qna-kr) 등 다양한 데이터셋 추가, 로컬 저장 및 FSx Lustre DRA 동기화 기능 지원
- **데이터셋 용도별 분류**: Pre-training과 SFT(Supervised Fine-tuning) 용도로 구분하여 체계적 관리
- **새로운 유틸리티 스크립트**: CloudFormation 스택 관리용 `export-stack-outputs.sh`와 FSx Lustre DRA 생성용 `create-dra.sh` 추가

### v1.0.1
- **FSDP2 지원 추가**: PyTorch 2.5+ FSDP2 기반 분산 학습 예제 및 가이드
- **DeepSpeed 통합**: DeepSpeed ZeRO 기반 대규모 모델 학습 샘플 추가
- **Qwen 3 0.6B 테스트**: 최신 Qwen 3 0.6B 모델 학습 및 추론 예제 (p4/p5 인스턴스 권장)
- **성능 최적화**: 최신 GPU 인스턴스 타입에 최적화된 설정 및 가이드

</details>

## 개요

이 저장소는 다음을 제공합니다:

- **클러스터 관리 스크립트**: HyperPod 클러스터 연결 및 설정 도구
- **분산 학습 예제**: FSDP, Megatron-LM, TorchTitan을 사용한 대규모 모델 학습
- **검증 및 설치 스크립트**: 클러스터 환경 검증 및 필수 도구 설치
- **한국어 가이드**: 각 프레임워크별 상세한 한국어 문서

## 기술 스택

- **AWS 서비스**: SageMaker HyperPod (w/ Slurm), AWS ParallelCluster
- **분산 학습 프레임워크**: PyTorch FSDP/FSDP2, DeepSpeed, Lightning, Megatron-LM, TorchTitan
- **컨테이너 런타임**: Pyxis/Enroot (Slurm 컨테이너 지원)
- **네트워크**: AWS EFA (Elastic Fabric Adapter)

## 프로젝트 구조

<details>
<summary>📁 클릭하여 전체 구조 보기</summary>

```
aws-ai-infra-helper/
├── prepare-datasets.py   # 데이터셋 준비 및 S3/FSx 동기화 스크립트
├── scripts/              # 유틸리티 스크립트
│   ├── hyperpod-connect.sh       # SSM 기반 HyperPod 연결
│   ├── hyperpod-ssh.sh           # SSH 기반 HyperPod 연결
│   ├── export-stack-outputs.sh  # CloudFormation 스택 출력 추출
│   ├── create-dra.sh             # FSx Lustre DRA 생성
│   ├── check-fsx.sh              # FSx for Lustre 검증
│   ├── check-munged.sh           # Slurm 연결 검증
│   ├── check-pyxis-enroot.sh     # Pyxis/Enroot 설치 검증
│   ├── install-pyxis-enroot.sh   # 컨테이너 지원 설치
│   ├── install-nccl-efa.sh       # NCCL/EFA 설치
│   ├── fix-cuda-version.sh       # CUDA 버전 확인 및 수정
│   └── generate-nccl-test.sh     # NCCL 테스트 생성
│
├── lightning/             # Lightning 분산 학습
│   ├── README.md                 # Lightning 한국어 가이드
│   ├── train.py                  # PyTorch Lightning 구현
│   ├── train_fabric.py           # Lightning Fabric 구현
│   ├── train.sbatch              # PyTorch Lightning Slurm 스크립트
│   ├── train_fabric.sbatch       # Lightning Fabric Slurm 스크립트
│   ├── train-pyxis.sbatch        # Pyxis+Enroot 컨테이너 학습 스크립트
│   ├── Dockerfile                # 컨테이너 이미지 빌드용
│   ├── setup-pyxis.sh            # Pyxis+Enroot 환경 설정
│   ├── release.sh                # 릴리즈 자동화 스크립트
│   └── RELEASE_NOTES.md          # 상세 릴리즈 노트
│
├── fsdp/                 # PyTorch FSDP 예제
│   ├── README.md                 # FSDP 한국어 가이드
│   ├── train-fsdp.sbatch         # 멀티노드 학습 스크립트
│   ├── train-fsdp-singlegpu.sbatch  # 단일 GPU 학습 스크립트
│   └── src/
│       ├── train.py              # FSDP 학습 스크립트
│       ├── requirements.txt      # Python 의존성
│       └── model_utils/          # 모델 유틸리티
│
├── fsdp2/                # PyTorch FSDP2 예제
│   ├── README.md                 # FSDP2 한국어 가이드
│   ├── train-fsdp2.sbatch        # 멀티노드 학습 스크립트
│   ├── train-fsdp2-singlenode.sh # 단일 노드 학습 스크립트
│   ├── train-pyxis.sbatch        # Pyxis+Enroot 컨테이너 학습 스크립트
│   ├── Dockerfile                # 컨테이너 이미지 빌드용
│   ├── setup-pyxis.sh            # Pyxis+Enroot 환경 설정
│   └── src/
│       ├── train_fsdp2.py        # FSDP2 학습 스크립트
│       └── model_utils/          # 모델 유틸리티
│
├── deepspeed/            # DeepSpeed 예제
│   ├── README.md                 # DeepSpeed 영문 가이드
│   ├── train-qwen3-0-6b.sbatch   # Qwen 3 0.6B 학습 스크립트
│   ├── train-qwen3-0-6b-singlenode.sh  # 단일 노드 학습
│   ├── train-pyxis.sbatch        # Pyxis+Enroot 컨테이너 학습 스크립트
│   ├── Dockerfile                # 컨테이너 이미지 빌드용
│   ├── setup-pyxis.sh            # Pyxis+Enroot 환경 설정
│   ├── ds_config.json            # DeepSpeed 설정
│   └── src/
│       ├── train_deepspeed.py    # DeepSpeed 학습 스크립트
│       └── model_utils/          # 모델 유틸리티
│
├── megatron/             # Megatron-LM 예제
│   ├── megatron-lm-slurm-guide-ko.md  # Slurm 가이드
│   └── megatron-lm-eks-guide-ko.md    # EKS 가이드
│
├── torchtitan/           # TorchTitan 예제
│   ├── README.md                 # TorchTitan 한국어 가이드
│   ├── train.sbatch              # 멀티노드 학습 Slurm 스크립트
│   ├── multinode_trainer.slurm   # 멀티노드 트레이너 Slurm 스크립트
│   ├── run_train.sh              # 학습 실행 쉘 스크립트
│   ├── benchmarks/               # 벤치마크 설정 및 스크립트
│   ├── scripts/                  # 유틸리티 스크립트
│   └── torchtitan/               # TorchTitan 소스 코드
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
    ├── setup/         # EKS 학습 클러스터 설정
    │   ├── README.md                     # EKS 학습 가이드
    │   ├── 1.create-config.sh            # 환경 설정 생성
    │   ├── 1.create-config-workshop.sh   # Workshop Studio용 환경 설정
    │   ├── 2.setup-eks-access.sh         # EKS 접근 권한 설정
    │   ├── 3.validate-cluster.sh         # 클러스터 검증
    │   └── check-nodegroup.sh            # NodeGroup 정보 확인
    │
    ├── inference/        # HyperPod EKS 추론 솔루션
    │   ├── README.md             # HyperPod EKS Inference 가이드
    │   ├── install_tools.sh      # 필수 도구 설치 스크립트
    │   ├── explore_fsx.sh        # FSx 탐색 도구
    │   │
    │   ├── basic/                # 기본 추론 환경
    │   │   ├── README.md                         # 기본 추론 배포 가이드
    │   │   ├── 1.grant_eks_access.sh             # EKS 접근 권한 설정
    │   │   ├── 2.prepare_fsx_inference.sh        # FSx 기반 추론 환경 준비
    │   │   ├── 3.copy_to_s3.sh                   # 모델을 S3에 복사
    │   │   ├── 4.fix_s3_csi_credentials.sh       # S3 CSI 자격증명 수정
    │   │   ├── 5a.prepare_s3_inference_operator.sh # S3 Inference Operator 배포
    │   │   ├── 5b.prepare_s3_direct_deploy.sh    # S3 Direct 배포
    │   │   ├── 6a.create_test_pod.sh             # 테스트 Pod 생성
    │   │   ├── invoke.py                         # 기본 추론 테스트
    │   │   └── template/                         # Kubernetes 배포 템플릿
    │   │       ├── deploy_S3_inference_operator_template.yaml
    │   │       ├── deploy_S3_direct_template.yaml
    │   │       ├── deploy_fsx_lustre_inference_operator_template.yaml
    │   │       └── copy_to_fsx_lustre_template.yaml
    │   │
    │   └── kvcache-and-intelligent-routing/ # 고급 추론 최적화
    │       ├── README.md                 # KV Cache & Intelligent Routing 가이드
    │       ├── 1.copy_to_s3.sh           # 모델을 S3에 복사
    │       ├── 2.setup_s3_csi.sh         # S3 CSI 설정
    │       ├── 3.prepare.sh              # 환경 준비
    │       ├── 4.check_status.sh         # 상태 확인
    │       ├── cleanup.sh                # 리소스 정리
    │       ├── benchmark.py              # 고성능 벤치마크
    │       ├── invoke.py                 # 추론 테스트
    │       └── inference_endpoint_config.yaml # 추론 엔드포인트 설정
    │
    └── task-governance/  # HyperPod EKS Task Governance
        ├── README.md                     # Task Governance 가이드
        ├── setup-task-governance.sh      # Task Governance 설정 스크립트
        ├── g5.8xlarge/                   # g5.8xlarge 인스턴스용 설정
        └── g5.12xlarge/                  # g5.12xlarge 인스턴스용 설정
```

</details>

## 📚 폴더별 가이드

### 🔧 유틸리티 및 도구
- **[scripts/](scripts/)** - 클러스터 연결, 환경 검증, 설치 스크립트
- **[observability/](observability/)** - 모니터링 및 관찰성 도구 (Prometheus, Grafana 등)

### 🚀 분산 학습 프레임워크
- **[lightning/](lightning/README.md)** - PyTorch Lightning + Lightning Fabric 이중 프레임워크
- **[fsdp/](fsdp/README.md)** - PyTorch 네이티브 FSDP 분산 학습
- **[fsdp2/](fsdp2/README.md)** - 차세대 FSDP2 (PyTorch 2.5+)
- **[deepspeed/](deepspeed/README.md)** - Microsoft DeepSpeed ZeRO 최적화
- **[megatron/](megatron/)** - NVIDIA Megatron-LM 대규모 모델 학습
- **[torchtitan/](torchtitan/)** - Meta TorchTitan 최신 학습 플랫폼

### ☸️ Kubernetes (EKS) 솔루션
- **[eks/training/](eks/training/README.md)** - EKS 기반 학습 클러스터 설정
- **[eks/inference/](eks/inference/README.md)** - HyperPod EKS Inference 솔루션
  - **[basic/](eks/inference/basic/README.md)** - 기본 추론 환경 (FSx/S3 기반)
  - **[kvcache-and-intelligent-routing/](eks/inference/kvcache-and-intelligent-routing/README.md)** - 고급 추론 최적화

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

### 4. 로컬 데이터셋 준비 (선택사항)

HyperPod 클러스터에서 로컬 데이터셋을 사용하려면 두 가지 방법 중 선택할 수 있습니다.

#### 방법 A: FSx Lustre DRA 없이 직접 다운로드 (테스트용 권장)

S3 동기화나 DRA 설정 없이 `/fsx/data/` 에 바로 다운로드합니다:

```bash
# 데이터셋을 /fsx/data/pretrain/ 또는 /fsx/data/sft/ 에 직접 저장
python3 prepare-datasets.py --local-only

# 저장 경로를 변경하려면 (기본값: /fsx/data)
python3 prepare-datasets.py --local-only --local-base-dir /fsx/data
```

다운로드가 완료되면 다음 경로에서 데이터셋을 바로 사용할 수 있습니다:
- Pre-training: `/fsx/data/pretrain/<dataset-name>/`
- SFT: `/fsx/data/sft/<dataset-name>/`

#### 방법 B: S3 및 FSx Lustre DRA를 통한 동기화 (프로덕션 권장)

```bash
# 1. 스택 정보 추출 및 환경변수 설정
./scripts/export-stack-outputs.sh hyperpod-cluster-name
source stack-env-vars.sh

# 2. FSx Lustre DRA (Data Repository Association) 생성
./scripts/create-dra.sh

# 3. 데이터셋 다운로드 및 S3/FSx 동기화
python3 prepare-datasets.py
```

이 과정을 통해 선택한 데이터셋이 S3와 FSx Lustre에 자동으로 동기화됩니다.

**사용 가능한 데이터셋:**

**Pre-training 용도:**
- wikitext-2: Language modeling dataset (~36k samples)
- wikitext-103: Large language modeling dataset (limited to 180k)

**Supervised Fine-tuning (SFT) 용도:**
- emotion: Emotion classification with 6 emotions (~20k samples)  
- sst2: Stanford Sentiment Treebank binary classification (~67k samples)
- cola: Corpus of Linguistic Acceptability (~8.5k samples)
- rte: Recognizing Textual Entailment (~2.5k samples)
- imdb: Movie review sentiment analysis (~50k samples)
- ag_news: News categorization into 4 classes (~120k samples)
- yelp_polarity: Yelp review sentiment analysis (limited to 100k)
- glan-qna-kr: Korean Q&A dataset (limited to 150k samples)

## 분산 학습 프레임워크

### Lightning (PyTorch Lightning + Lightning Fabric)

PyTorch Lightning과 Lightning Fabric을 활용한 이중 프레임워크 지원으로, 자동화된 학습과 세밀한 제어를 모두 제공합니다.

**주요 특징:**
- PyTorch Lightning: 자동화된 학습 루프, 콜백, 로깅
- Lightning Fabric: 커스텀 학습 루프, 세밀한 제어
- FSDP 분산 학습 및 BF16 Mixed Precision 지원
- 스마트 체크포인트 관리 (자동 재시작, 완료 감지)
- 향상된 모니터링 (Loss, Grad Norm, LR, TPS, TFLOPs/s)

**시작하기:**
```bash
cd lightning

# PyTorch Lightning (자동화)
python train.py --gpus=8 --batch_size=4 --max_steps=1000
sbatch train.sbatch

# Pyxis+Enroot 컨테이너 (권장)
./setup-pyxis.sh  # 최초 1회 실행
sbatch train-pyxis.sbatch

# Lightning Fabric (세밀한 제어)
python train_fabric.py --gpus=8 --batch_size=4 --max_steps=1000
sbatch train_fabric.sbatch
```

**상세 가이드:** [lightning/README.md](lightning/README.md)

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
sbatch train-fsdp-singlegpu.sbatch

# 멀티노드 학습
sbatch train-fsdp.sbatch
```

**상세 가이드:** [fsdp/README.md](fsdp/README.md)

### FSDP2 (Fully Sharded Data Parallel v2)

PyTorch 2.5+에서 도입된 차세대 FSDP로, 향상된 성능과 메모리 효율성을 제공합니다.

**주요 특징:**
- 개선된 통신 오버헤드 및 메모리 사용량
- 더 나은 컴파일러 최적화 지원
- 향상된 체크포인트 및 재시작 기능
- Float8 양자화 지원

**시작하기:**
```bash
cd fsdp2

# 단일 노드 학습
./train-fsdp2-singlenode.sh

# 멀티노드 학습
sbatch train-fsdp2.sbatch

# Pyxis+Enroot 컨테이너 (권장)
./setup-pyxis.sh  # 최초 1회 실행
sbatch train-pyxis.sbatch
```

**상세 가이드:** [fsdp2/README.md](fsdp2/README.md)

### DeepSpeed

Microsoft에서 개발한 대규모 모델 학습 최적화 라이브러리입니다.

**주요 특징:**
- ZeRO (Zero Redundancy Optimizer) 단계별 최적화
- 메모리 효율적인 attention 구현
- CPU/NVMe offloading 지원
- 자동 혼합 정밀도 및 gradient clipping

**시작하기:**
```bash
cd deepspeed

# Qwen 3 0.6B 단일 노드 학습
./train-qwen3-0-6b-singlenode.sh

# Qwen 3 0.6B 멀티노드 학습
sbatch train-qwen3-0-6b.sbatch

# Pyxis+Enroot 컨테이너 (권장)
./setup-pyxis.sh  # 최초 1회 실행
sbatch train-pyxis.sbatch
```

**상세 가이드:** [deepspeed/README.md](deepspeed/README.md)

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

**상세 가이드:** [megatron/megatron-lm-slurm-guide-ko.md](megatron/megatron-lm-slurm-guide-ko.md)

### TorchTitan

Meta(PyTorch 팀)에서 개발한 PyTorch 네이티브 대규모 언어 모델 사전 학습 플랫폼입니다.

**주요 특징:**
- FSDP2, Tensor/Pipeline/Context Parallel 등 PyTorch 내장 분산 학습 기능 활용
- 다양한 모델 지원: Llama 3/4, Qwen3, DeepSeek-V3, GPT, Flux 등
- Float8 양자화 및 torch.compile 통합
- Zero-bubble Pipeline Parallel
- GRPO 강화학습, 비전-언어 모델(VLM) 등 실험적 기능 포함
- AWS EFA 최적화 설정 내장

**시작하기:**
```bash
cd torchtitan

# 로컬 단일 노드 학습 (기본: llama3 debugmodel, 8 GPU)
./run_train.sh

# 모델/설정 지정
MODULE=llama3 CONFIG=llama3_8b ./run_train.sh

# GPU 없이 설정 유효성 검증 (dry-run)
NGPU=32 COMM_MODE="fake_backend" MODULE=llama3 CONFIG=llama3_70b ./run_train.sh

# 멀티노드 학습 (Slurm)
sbatch --nodes=1 train.sbatch
sbatch multinode_trainer.slurm
```

**상세 가이드:** [torchtitan/README.md](torchtitan/README.md)

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

