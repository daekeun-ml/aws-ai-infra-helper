# NeMo Megatron-Bridge 벤치마크

[NVIDIA Megatron-Bridge Performance Summary](https://docs.nvidia.com/nemo/megatron-bridge/latest/performance-summary.html) 결과를 AWS HyperPod 환경에서 재현하기 위한 벤치마크 스크립트 모음입니다.

## 테스트 환경

| 항목 | 내용 |
|------|------|
| 인스턴스 | p5 (H100), p5e / p5en (H200), p6-b200 (B200) |
| GPU 구성 | 8장 (1노드), 16장 (2노드) |
| 컨테이너 | `nvcr.io/nvidia/nemo:26.02.01` |
| Megatron-Bridge | v0.3.1 |

## 지원 모델

| 모델 | 타입 | Precision | 비고 |
|------|------|-----------|------|
| Qwen3 30B A3B | MoE | fp8_cs / fp8_mx | H100/H200 → fp8_cs, B200/GB200 → fp8_mx |
| Llama3 8B | Dense | fp8_cs / fp8_mx / bf16 | |
| GPT-OSS 120B | MoE | bf16 only | 기능 검증 용도 권장 |
| Qwen3-VL 30B A3B | VLM Pretrain | bf16 / fp8_cs / fp8_mx | |

## 스크립트 구성

```
benchmark/
├── env.sh                    # 공통 환경 변수 (편집 필요)
├── 01_env_check.sh           # [Step 1] HyperPod 환경 점검
├── 02_prepare_container.sh   # [Step 2] NeMo sqsh 컨테이너 생성
├── 03_run_basic.sh           # [Step 3] 기본 벤치마크 (DGX Reference Config)
├── 04_run_aws_optimized.sh   # [Step 4] AWS 최적화 벤치마크 (EFA 멀티노드)
└── presets/                  # 모델별 병렬화 설정
```

## 빠른 시작

### 1. 환경 변수 설정

`env.sh`를 열어 클러스터 환경에 맞게 수정합니다.

```bash
vi env.sh
```

```bash
SLURM_ACCOUNT="<your-account>"   # sacctmgr show account 결과 참조
SLURM_PARTITION="<your-partition>" # sinfo 결과 참조
HF_TOKEN="<your-hf-token>"
WORK_DIR="/fsx/megatron-bridge-test"  # FSx Lustre 경로
NEMO_VERSION="26.02.01"
```

### 2. 환경 점검

```bash
bash 01_env_check.sh
```

login 노드에서 실행하면 compute 노드로 자동 SSH하여 점검합니다. GPU, EFA, NCCL, Slurm 구성을 출력합니다.

### 3. 컨테이너 준비 (최초 1회)

```bash
bash 02_prepare_container.sh
```

NeMo 컨테이너를 docker export 방식으로 `.sqsh` 파일로 변환합니다. login 노드에서 실행하면 compute 노드로 자동 SSH하여 수행합니다.

> 생성 위치: `/fsx/containers/nemo_26.02.01.sqsh` (약 20~30GB, 수십 분 소요)

### 4. 벤치마크 실행

**단일 노드 또는 소규모 멀티노드 (DGX Reference Config):**

```bash
bash 03_run_basic.sh
```

**AWS EFA 최적화 멀티노드:**

```bash
bash 04_run_aws_optimized.sh
```

두 스크립트 모두 실행 시 모델 / GPU 타입 / 노드 수를 대화식으로 선택하고, dry-run으로 sbatch 스크립트를 확인한 뒤 제출합니다.

## Preset 구성

| Preset 파일 | 모델 | GPU | TP | PP | EP | VP |
|-------------|------|-----|----|----|----|----|
| `qwen3_30b_a3b_8gpu_1node.conf` | Qwen3 30B A3B | 8 | 1 | 1 | 8 | 1 |
| `qwen3_30b_a3b_16gpu_2node.conf` | Qwen3 30B A3B | 16 | 1 | 2 | 8 | 24 |
| `llama3_8b_8gpu_1node.conf` | Llama3 8B | 8 | 1 | 1 | - | - |
| `llama3_8b_16gpu_2node.conf` | Llama3 8B | 16 | 1 | 1 | - | - |
| `gpt_oss_120b_8gpu_1node.conf` | GPT-OSS 120B | 8 | 8 | 1 | 1 | - |
| `gpt_oss_120b_16gpu_2node.conf` | GPT-OSS 120B | 16 | 8 | 1 | 1 | - |
| `gpt_oss_120b_64gpu_8node.conf` | GPT-OSS 120B | 64 | 8 | 1 | 1 | - |
| `qwen3_vl_30b_a3b_8gpu_1node.conf` | Qwen3-VL 30B A3B | 8 | 1 | 1 | 8 | - |
| `qwen3_vl_30b_a3b_16gpu_2node.conf` | Qwen3-VL 30B A3B | 16 | 1 | 1 | 8 | - |

## 참고 사항

- **`03_run_basic.sh` vs `04_run_aws_optimized.sh`**: `03`은 NVIDIA DGX Reference Config 그대로 사용, `04`는 AWS EFA (`aws-ofi-nccl`) 및 Host 라이브러리 마운트 설정을 추가합니다. AWS 멀티노드 환경에서는 `04`를 사용하세요.
- **컨테이너 방식**: Enroot `.sqsh` (docker export 방식)를 사용합니다. `docker export`로 생성한 flat filesystem이므로 Docker ENV가 소실되며, `run_script.py` V5 패치로 복원합니다.
- **결과 위치**: `$WORK_DIR/results/<model>_<size>_basic/` 또는 `_multinode/` 하위에 저장됩니다.

## References

- [Megatron-Bridge Performance Summary](https://docs.nvidia.com/nemo/megatron-bridge/latest/performance-summary.html)
- [Megatron-Bridge GitHub](https://github.com/NVIDIA-NeMo/Megatron-Bridge)
