# NeMo Megatron-Bridge 벤치마크

[NVIDIA Megatron-Bridge Performance Summary](https://docs.nvidia.com/nemo/megatron-bridge/latest/performance-summary.html) 결과를 AWS HyperPod 환경에서 재현하기 위한 벤치마크 스크립트 모음입니다.

## 디렉토리 구조

```
benchmark/
├── env_check.sh                 # 환경 점검 (두 버전 공용)
├── 25.11/                       # NeMo 25.11.01 / Megatron-Bridge r0.2.0
│   ├── env.sh
│   ├── 01_prepare_environment.sh
│   ├── 02_run_basic.sh
│   ├── 03_run_aws_optimized.sh
│   └── presets/
└── 26.02/                       # NeMo 26.02.01 / Megatron-Bridge v0.3.1
    ├── env.sh
    ├── 01_prepare_environment.sh
    ├── 02_run_basic.sh
    ├── 03_run_aws_optimized.sh
    ├── fix_nccl_setup.sh
    └── presets/
```

## 버전 선택

| | 25.11 | 26.02 |
|---|---|---|
| NeMo 컨테이너 | `nemo:25.11.01` | `nemo:26.02.01` |
| Megatron-Bridge | r0.2.0 | v0.3.1 |
| VLM 태스크 | SFT | Pretrain |

## 지원 모델

| 모델 | 타입 | Precision | 비고 |
|------|------|-----------|------|
| Qwen3 30B A3B | MoE | fp8_cs / fp8_mx | H100/H200 → fp8_cs, B200/GB200 → fp8_mx |
| Llama3 8B | Dense | fp8_cs / fp8_mx / bf16 | |
| GPT-OSS 120B | MoE | bf16 only | 기능 검증 용도 권장 |
| Qwen3-VL 30B A3B | VLM | bf16 only | |

## 빠른 시작

### 0. 환경 점검

```bash
# 단일 노드 (login 노드 실행 시 첫 번째 compute 노드로 자동 SSH)
bash env_check.sh

# 전체 compute 노드 동시 점검
bash env_check.sh --all
```

GPU, EFA, NCCL/ofi-nccl, Slurm, 컨테이너 런타임, 파일시스템 구성을 출력합니다.

### 1. 환경 변수 설정

사용할 버전 폴더의 `env.sh`를 수정합니다.

```bash
vi 26.02/env.sh   # 또는 25.11/env.sh
```

```bash
SLURM_ACCOUNT="<your-account>"      # sacctmgr show account 결과 참조
SLURM_PARTITION="<your-partition>"  # sinfo 결과 참조
HF_TOKEN="<your-hf-token>"
WORK_DIR="/fsx/megatron-bridge-test-26.02"  # FSx Lustre 경로 (25.11은 /fsx/megatron-bridge-test-25.11)
```

### 2. 환경 준비 (최초 1회)

```bash
cd 26.02   # 또는 cd 25.11
bash 01_prepare_environment.sh
```

수행 내용:
1. **sqsh 생성** — NeMo 컨테이너를 docker export → `.sqsh` 변환 (약 20~30GB, 수십 분 소요). 이미 존재하면 스킵.
2. **Pyxis 연결 확인** — Slurm + Pyxis/Enroot 동작 검증 및 자동 복구 시도.
3. **레포 클론** — `Megatron-Bridge`를 FSx로 클론.
4. **venv + NeMo-Run 설치** — Python venv 생성 및 NeMo-Run pip 설치.

login 노드에서 실행하면 compute 노드로 자동 SSH하여 수행합니다.

### 3. 벤치마크 실행

**단일 노드 또는 소규모 멀티노드 (DGX Reference Config):**

```bash
bash 02_run_basic.sh
```

**AWS EFA 최적화 멀티노드:**

```bash
bash 03_run_aws_optimized.sh
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

- **실행 순서**: `01_prepare_environment.sh`를 먼저 한 번 실행한 뒤 `02` 또는 `03`을 실행합니다. `02`, `03`은 `01`에서 준비한 sqsh / 레포 / venv를 그대로 사용하며, 없으면 에러로 안내합니다.
- **`02_run_basic.sh` vs `03_run_aws_optimized.sh`**: `02`는 NVIDIA DGX Reference Config 그대로 사용, `03`은 AWS EFA (ofi-nccl) 및 Host 라이브러리 마운트 설정을 추가합니다. AWS 멀티노드 환경에서는 `03`을 사용하세요.
- **컨테이너 방식**: Enroot `.sqsh` (docker export 방식)를 사용합니다. `docker export`로 생성한 flat filesystem이므로 Docker ENV가 소실되며, `run_script.py` V5 패치로 복원합니다.
- **결과 위치**: `$WORK_DIR/results/<model>_<size>_basic/` 또는 `_multinode/` 하위에 저장됩니다.

## References

- [Megatron-Bridge Performance Summary](https://docs.nvidia.com/nemo/megatron-bridge/latest/performance-summary.html)
- [Megatron-Bridge GitHub](https://github.com/NVIDIA-NeMo/Megatron-Bridge)
