#!/bin/bash
# =============================================================================
# [Step 4] AWS 최적화 멀티노드 벤치마크
#
# 사전 조건: 01_prepare_environment.sh 실행 완료 (레포, venv, sqsh 이미 세팅됨)
#
# r0.2.0 브랜치에서 docker export sqsh + EFA 멀티노드 구성.
# setup_experiment.py의 custom_env_vars에 EFA/NCCL 환경변수 직접 패치.
#
# 핵심 해결 사항:
#   1. docker export sqsh → custom_env_vars + VENV_BOOTSTRAP_V5로 ENV 복원
#   2. Host EFA 라이브러리(libfabric 2.3+) → -cm 단일 옵션에 comma-separated 마운트
#   3. NCCL_NET_PLUGIN=ofi → /opt/amazon/ofi-nccl/lib/libnccl-net-ofi.so 로드
#   4. NCCL_PROTO/ALGO 제거 → ofi-nccl 자동 튜닝 사용
#   5. PP=1 시 VP=None 강제 (H100 base config VP=12 오버라이드)
# =============================================================================

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# Host EFA 라이브러리 마운트 (콤마 구분, 단일 -cm 옵션)
CUSTOM_MOUNTS="/opt/amazon/efa:/opt/amazon/efa"
CUSTOM_MOUNTS="${CUSTOM_MOUNTS},/opt/amazon/ofi-nccl:/opt/amazon/ofi-nccl"
CUSTOM_MOUNTS="${CUSTOM_MOUNTS},/usr/lib/x86_64-linux-gnu/libefa.so.1:/usr/lib/x86_64-linux-gnu/libefa.so.1"
CUSTOM_MOUNTS="${CUSTOM_MOUNTS},/usr/lib/x86_64-linux-gnu/libefa.so.1.4.60.0:/usr/lib/x86_64-linux-gnu/libefa.so.1.4.60.0"
CUSTOM_MOUNTS="${CUSTOM_MOUNTS},/usr/lib/x86_64-linux-gnu/libibverbs.so.1:/usr/lib/x86_64-linux-gnu/libibverbs.so.1"
CUSTOM_MOUNTS="${CUSTOM_MOUNTS},/usr/lib/x86_64-linux-gnu/libibverbs.so.1.15.60.0:/usr/lib/x86_64-linux-gnu/libibverbs.so.1.15.60.0"
CUSTOM_MOUNTS="${CUSTOM_MOUNTS},/usr/lib/x86_64-linux-gnu/libibverbs:/usr/lib/x86_64-linux-gnu/libibverbs"

# ===================== 모델 선택 =====================
echo "모델을 선택하세요:"
echo "  1) Qwen3 30B A3B     (MoE)"
echo "  2) Llama3 8B         (Dense)"
echo "  3) GPT-OSS 120B      (MoE, bf16 only)"
echo "  4) Qwen3-VL 30B A3B  (VLM SFT, bf16 only)"
read -p "선택 (1/2/3/4): " model_choice

case "$model_choice" in
    1) MODEL_NAME="qwen3";    PRESET_PREFIX="qwen3";    MODEL_SIZE="30b_a3b" ;;
    2) MODEL_NAME="llama3";   PRESET_PREFIX="llama3";   MODEL_SIZE="8b" ;;
    3) MODEL_NAME="gpt_oss";  PRESET_PREFIX="gpt_oss";  MODEL_SIZE="120b" ;;
    4) MODEL_NAME="qwen3_vl"; PRESET_PREFIX="qwen3_vl"; MODEL_SIZE="30b_a3b" ;;
    *) echo "잘못된 선택. 종료."; exit 1 ;;
esac

# ===================== GPU 타입 선택 =====================
echo "GPU 타입을 선택하세요:"
echo "  1) H100 / H200  (fp8_cs)"
echo "  2) B200         (fp8_mx)"
echo "  3) GB200        (fp8_mx)"
read -p "선택 (1/2/3): " gpu_choice

case "$gpu_choice" in
    1) GPU_TYPE="h100";  FP8_PRECISION="fp8_cs"; CUDA_ARCH="9.0+PTX"  ;;
    2) GPU_TYPE="b200";  FP8_PRECISION="fp8_mx"; CUDA_ARCH="12.0+PTX" ;;
    3) GPU_TYPE="gb200"; FP8_PRECISION="fp8_mx"; CUDA_ARCH="12.0+PTX" ;;
    *) echo "잘못된 선택. 종료."; exit 1 ;;
esac

[ "$MODEL_NAME" = "gpt_oss"  ] && FP8_PRECISION="bf16"
[ "$MODEL_NAME" = "qwen3_vl" ] && FP8_PRECISION="bf16"

# ===================== 노드 수 선택 =====================
GPUS_PER_NODE=8
MAX_NODES=$(sinfo -p "$SLURM_PARTITION" -h -o "%D" 2>/dev/null | awk '{s+=$1} END{print s+0}')
if [ "${MAX_NODES:-0}" -eq 0 ]; then
    echo "ERROR: sinfo에서 파티션 '$SLURM_PARTITION' 노드 수를 감지하지 못했습니다."
    exit 1
fi

echo "사용할 노드 수를 선택하세요 (1~${MAX_NODES}):"
for n in $(seq 1 "$MAX_NODES"); do
    echo "  ${n}) ${n}노드 ($((n * GPUS_PER_NODE)) GPU)"
done
read -p "선택 (1~${MAX_NODES}): " node_choice
if ! [[ "$node_choice" =~ ^[0-9]+$ ]] || [ "$node_choice" -lt 1 ] || [ "$node_choice" -gt "$MAX_NODES" ]; then
    echo "잘못된 선택. 종료."; exit 1
fi
NUM_NODES="$node_choice"
NUM_GPUS=$((NUM_NODES * GPUS_PER_NODE))
echo "  -> 선택된 노드: ${NUM_NODES}개 → GPU: ${NUM_GPUS}개"

# GPU 수에 맞는 preset 파일 선택
PRESET=$(ls "$PRESET_DIR"/${PRESET_PREFIX}_${MODEL_SIZE}_${NUM_GPUS}gpu*.conf 2>/dev/null | head -1)
if [ -z "$PRESET" ]; then
    echo "ERROR: ${PRESET_PREFIX} ${MODEL_SIZE} ${NUM_GPUS}GPU용 preset 없음. 사용 가능한 preset:"
    ls "$PRESET_DIR"/*.conf 2>/dev/null || echo "  (없음)"
    exit 1
fi
source "$PRESET"
echo "  -> preset: $PRESET"
# GA가 설정된 경우 GBS 역산: GBS = MBS * GA * DP (DP = NUM_GPUS / (TP*PP*CP))
if [ -n "${GA// /}" ]; then
    DP=$((NUM_GPUS / (TP * PP * CP)))
    GBS=$((MBS * GA * DP))
    echo "  -> GA=$GA 지정 → GBS 역산: MBS($MBS) * GA($GA) * DP($DP) = $GBS"
fi
# =========================================================

echo "============================================================"
echo " $MODEL_NAME $MODEL_SIZE AWS 최적화 멀티노드 벤치마크"
echo "============================================================"
echo " Slurm Account:   $SLURM_ACCOUNT"
echo " Slurm Partition: $SLURM_PARTITION"
echo " GPU:             $NUM_GPUS x $GPU_TYPE (${NUM_NODES}노드)"
echo " Precision:       $FP8_PRECISION"
echo " Container Mounts: $CUSTOM_MOUNTS"
echo "============================================================"

# sqsh 확인 (AWS 최적화는 sqsh 필수)
if [ ! -f "$SQSH_FILE" ]; then
    echo "ERROR: sqsh 파일 없음: $SQSH_FILE"
    echo "먼저 01_prepare_environment.sh를 실행하세요."
    exit 1
fi
echo "[0] sqsh 컨테이너 사용: $SQSH_FILE ($(ls -lh "$SQSH_FILE" | awk '{print $5}'))"

cd "$WORK_DIR/Megatron-Bridge"
source "$WORK_DIR/venv/bin/activate"

# NeMo-Run git packager tar 패치 재확인
GIT_PKG=$(python3 -c "import nemo_run.core.packaging.git as g; print(g.__file__)" 2>/dev/null || true)
if [ -n "$GIT_PKG" ] && ! grep -q "warn=True" "$GIT_PKG" 2>/dev/null; then
    sed -i 's/ctx\.run(f"tar cf {quoted_output_file} -C {temp_dir} \.")/ctx.run(f"tar cf {quoted_output_file} -C {temp_dir} .", warn=True)/g' "$GIT_PKG"
fi

# ----- setup_experiment.py에 EFA/NCCL custom_env_vars 패치 -----
SETUP_SCRIPT="scripts/performance/setup_experiment.py"
if ! grep -q "NCCL_NET_PLUGIN" "$SETUP_SCRIPT" 2>/dev/null; then
    echo "  -> setup_experiment.py EFA/NCCL custom_env_vars 패치 적용..."

    python3 << 'PATCH_EOF'
filepath = "scripts/performance/setup_experiment.py"
with open(filepath, "r") as f:
    content = f.read()

import re

new = '''custom_env_vars={
                "NVIDIA_VISIBLE_DEVICES": "all",
                "NVIDIA_DRIVER_CAPABILITIES": "compute,utility",
                "CUDA_HOME": "/usr/local/cuda",
                "CUDA_PATH": "/usr/local/cuda",
                "LIBRARY_PATH": "/usr/local/cuda/lib64/stubs:/usr/local/cuda/lib64",
                "CPATH": "/usr/local/cuda/include",
                "PATH": "/opt/venv/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "TRITON_PTXAS_PATH": "/usr/local/cuda/bin/ptxas",
                "FI_PROVIDER": "efa",
                "FI_EFA_USE_DEVICE_RDMA": "1",
                "FI_EFA_FORK_SAFE": "1",
                "NCCL_NET_PLUGIN": "ofi",
                "NCCL_SOCKET_IFNAME": "^lo,docker0,veth_def_agent",
                "NCCL_DEBUG": "INFO",
                "NCCL_DEBUG_SUBSYS": "INIT,NET",
                "LD_LIBRARY_PATH": "/opt/amazon/efa/lib:/opt/amazon/ofi-nccl/lib:/usr/local/cuda/lib64:/usr/local/cuda/compat:/usr/local/nvidia/lib64:/opt/hpcx/nccl_rdma_sharp_plugin/lib:/opt/hpcx/ucc/lib:/opt/hpcx/ucx/lib:/opt/hpcx/ompi/lib:/opt/hpcx/sharp/lib",
            },'''

pattern = r'custom_env_vars=\{[^}]*\},'
if re.search(pattern, content, re.DOTALL):
    content = re.sub(pattern, new, content, count=1, flags=re.DOTALL)
    with open(filepath, "w") as f:
        f.write(content)
    print("  -> EFA/NCCL custom_env_vars 패치 완료")
else:
    print("  -> custom_env_vars 패턴 미발견")
PATCH_EOF
else
    echo "  -> setup_experiment.py EFA/NCCL 패치 이미 적용됨"
fi

# ----- setup_experiment.py dry-run 후 빈 시퀀스 에러 패치 -----
# r0.2.0: dry-run 완료 후 experiment 상태 조회 시 디렉토리가 없어 ValueError 발생.
# 해당 호출을 try-except로 감싸서 에러 없이 정상 종료.
if ! grep -q "DRYRUN_EMPTY_SEQ_FIX" "$SETUP_SCRIPT" 2>/dev/null; then
    echo "  -> setup_experiment.py dry-run 빈 시퀀스 패치 적용..."
    python3 << 'PATCH_EOF'
filepath = "scripts/performance/setup_experiment.py"
with open(filepath, "r") as f:
    content = f.read()

old = "    exp_name_result, job_dict = list(run.Experiment.from_title(exp_name).status(return_dict=True).items()).pop()\n    job_status = str(job_dict[\"status\"])\n\n    if job_status not in [\"SUCCEEDED\", \"SUBMITTED\", \"PENDING\", \"RUNNING\"]:\n        raise Exception(f\"Megatron-Bridge experiment failed for {exp_name_result} with status: {job_status}.\")"
new = """    # DRYRUN_EMPTY_SEQ_FIX: r0.2.0 dry-run 후 experiment 디렉토리 없으면 ValueError 발생
    try:
        exp_name_result, job_dict = list(run.Experiment.from_title(exp_name).status(return_dict=True).items()).pop()
        job_status = str(job_dict["status"])
        if job_status not in ["SUCCEEDED", "SUBMITTED", "PENDING", "RUNNING"]:
            raise Exception(f"Megatron-Bridge experiment failed for {exp_name_result} with status: {job_status}.")
    except (ValueError, IndexError):
        pass  # dry-run: experiment 디렉토리 없음 (정상)"""

if old in content:
    content = content.replace(old, new, 1)
    with open(filepath, "w") as f:
        f.write(content)
    print("  -> dry-run 빈 시퀀스 패치 완료")
else:
    print("  -> 패턴 미발견 (이미 패치됨?)")
PATCH_EOF
else
    echo "  -> setup_experiment.py dry-run 패치 이미 적용됨"
fi

# executors.py 잘못된 PATH 패치 복원
EXECUTOR_FILE="scripts/performance/utils/executors.py"
if [ -f "${EXECUTOR_FILE}.bak_path" ]; then
    echo "  -> executors.py 이전 PATH 패치 복원..."
    mv "${EXECUTOR_FILE}.bak_path" "$EXECUTOR_FILE"
fi
echo ""

RESULTS_DIR="$WORK_DIR/results/${PRESET_PREFIX}_${MODEL_SIZE}_multinode"
mkdir -p "$RESULTS_DIR"
export NEMORUN_HOME="$RESULTS_DIR"
export MB_CUDA_ARCH="$CUDA_ARCH"

rm -rf "$RESULTS_DIR/experiments/" 2>/dev/null
rm -rf "$WORK_DIR/Megatron-Bridge"/temp_extract_* 2>/dev/null

FSDP_FLAG=""
[ "${FSDP:-0}" -gt 0 ] && FSDP_FLAG="--use_megatron_fsdp true"
NO_CUDA_GRAPHS_FLAG=""
[ "${NO_CUDA_GRAPHS:-0}" -gt 0 ] && NO_CUDA_GRAPHS_FLAG="--cuda_graph_impl none"
VP_FLAG=""
[ -n "${VP// /}" ] && VP_FLAG="-vp $VP"
EP_FLAG=""
[ -n "${EP// /}" ] && EP_FLAG="-ep $EP"
TASK_FLAG=""
DOMAIN_FLAG=""
[ "$MODEL_NAME" = "qwen3_vl" ] && { TASK_FLAG="--task sft"; DOMAIN_FLAG="--domain vlm"; }

echo "[DEBUG] preset: TP=$TP PP=$PP CP=$CP VP='${VP:-}' EP='${EP:-}' MBS=$MBS GBS=$GBS FSDP=${FSDP:-0} NO_CUDA_GRAPHS=${NO_CUDA_GRAPHS:-0}"

# ----- Dry Run -----
echo ""
echo "--- Multi-Node: ${NUM_GPUS} GPU (${NUM_NODES}노드 x 8), ${GPU_TYPE}, ${FP8_PRECISION} ---"
echo "  Container Mounts: $CUSTOM_MOUNTS"
echo ""

python scripts/performance/setup_experiment.py \
  -a "$SLURM_ACCOUNT" \
  -p "$SLURM_PARTITION" \
  -i "$SQSH_FILE" \
  -m $MODEL_NAME -s $MODEL_SIZE \
  -ng $NUM_GPUS -gn $GPUS_PER_NODE \
  -g $GPU_TYPE -c $FP8_PRECISION \
  -tp $TP -pp $PP -cp $CP ${VP_FLAG} ${EP_FLAG} \
  -mb $MBS -gb $GBS \
  ${FSDP_FLAG} ${NO_CUDA_GRAPHS_FLAG} \
  ${TASK_FLAG} ${DOMAIN_FLAG} \
  -hf "$HF_TOKEN" \
  -l "$RESULTS_DIR" -t "00:30:00" -ms 20 \
  -cm "$CUSTOM_MOUNTS" \
  -d

echo ""
echo "============================================================"
echo " 위 sbatch 스크립트를 확인하세요."
echo " container-image가 sqsh 경로인지 확인!"
echo " 문제없으면 y를 입력."
echo "============================================================"
read -p "실제 벤치마크 제출? (y/N): " confirm
confirm=$(echo "$confirm" | tr -d '[:space:]')
if [[ "$confirm" != [yY] ]]; then
    echo "취소됨."
    deactivate
    exit 0
fi

# ----- 실제 제출 -----
rm -rf "$WORK_DIR/Megatron-Bridge"/temp_extract_* 2>/dev/null
rm -rf "$RESULTS_DIR/experiments/" 2>/dev/null

python scripts/performance/setup_experiment.py \
  -a "$SLURM_ACCOUNT" \
  -p "$SLURM_PARTITION" \
  -i "$SQSH_FILE" \
  -m $MODEL_NAME -s $MODEL_SIZE \
  -ng $NUM_GPUS -gn $GPUS_PER_NODE \
  -g $GPU_TYPE -c $FP8_PRECISION \
  -tp $TP -pp $PP -cp $CP ${VP_FLAG} ${EP_FLAG} \
  -mb $MBS -gb $GBS \
  ${FSDP_FLAG} ${NO_CUDA_GRAPHS_FLAG} \
  ${TASK_FLAG} ${DOMAIN_FLAG} \
  -hf "$HF_TOKEN" \
  -l "$RESULTS_DIR" -t "00:30:00" -ms 20 \
  -cm "$CUSTOM_MOUNTS"

deactivate

echo ""
echo "============================================================"
echo " 로그 모니터링..."
echo ""
echo " 주의사항:"
echo "   - NCCL_PROTO, NCCL_ALGO 설정 금지 (ofi-nccl 자동 튜닝 사용)"
echo "   - Host EFA 라이브러리 마운트 필수 (libfabric 2.3+, libefa 1.4+)"
echo ""
echo " Ctrl+C로 모니터링 종료 (잡은 계속 실행됨)"
echo "============================================================"

echo "  로그 파일 대기 중..."
LOG_FILE=""
for i in $(seq 1 60); do
    LOG_FILE=$(find "$RESULTS_DIR" -name "log-*.out" -type f -printf "%T@ %p\n" 2>/dev/null | sort -rn | awk '{print $2}' | head -1)
    if [ -n "$LOG_FILE" ]; then
        echo "  -> 로그 파일 발견: $LOG_FILE"
        ln -sf "$LOG_FILE" "$RESULTS_DIR/latest.log"
        echo ""
        tail -f "$LOG_FILE"
        break
    fi
    sleep 2
done

if [ -z "${LOG_FILE:-}" ]; then
    echo "  60초 내 로그 파일 미발견. 수동 확인:"
    echo "    squeue -u \$USER"
    echo "    find $RESULTS_DIR -name 'log-*.out' | head -5"
fi
