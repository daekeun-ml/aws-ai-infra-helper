#!/bin/bash
# =============================================================================
# [Step 1] HyperPod 환경 점검
#
# 사용법:
#   bash 01_env_check.sh          # 단일 노드 (login 노드 실행 시 첫 번째 compute 노드로 자동 SSH)
#   bash 01_env_check.sh --all    # 전체 compute 노드 동시 점검 (srun 사용, 공유 파일시스템 필요)
# =============================================================================

# --all 플래그: srun으로 모든 compute 노드에서 동시 실행
if [[ "$1" == "--all" ]]; then
    NUM_NODES=$(sinfo -h -o "%D" 2>/dev/null | awk '{s+=$1}END{print s}')
    if [ -z "$NUM_NODES" ] || [ "$NUM_NODES" -eq 0 ]; then
        echo "ERROR: sinfo로 compute 노드를 찾을 수 없습니다. Slurm이 실행 중인지 확인하세요."
        exit 1
    fi
    echo "[INFO] 전체 ${NUM_NODES}개 노드 점검 시작 (srun)..."
    echo ""
    srun --nodes=$NUM_NODES --ntasks-per-node=1 bash "$0"
    exit $?
fi

# GPU 없으면 login 노드로 간주 → 첫 번째 compute 노드로 SSH하여 재실행
# (srun으로 실행 중인 경우 SLURM_JOB_ID가 설정되므로 이 블록 건너뜀)
if ! nvidia-smi -L &>/dev/null && [ -z "$SLURM_JOB_ID" ]; then
    echo "[INFO] GPU 미감지 (login 노드). sinfo로 compute 노드 탐색 중..."
    NODELIST=$(sinfo -h -o "%N" 2>/dev/null | head -1)
    FIRST_NODE=$(scontrol show hostnames "$NODELIST" 2>/dev/null | head -1)
    if [ -z "$FIRST_NODE" ]; then
        echo "ERROR: sinfo로 compute 노드를 찾을 수 없습니다. Slurm이 실행 중인지 확인하세요."
        exit 1
    fi
    echo "[INFO] Compute 노드 접속: $FIRST_NODE"
    echo ""
    ssh -o StrictHostKeyChecking=no "$FIRST_NODE" "bash -s" < "$0"
    exit $?
fi

# srun으로 실행 중이면 각 노드 출력에 hostname prefix 추가
[ -n "$SLURM_JOB_ID" ] && HOSTNAME_PREFIX="[$(hostname -s)] " || HOSTNAME_PREFIX=""

echo "============================================================"
echo "${HOSTNAME_PREFIX}HyperPod Environment Check"
echo "============================================================"

echo ""
echo "--- [1/8] GPU 정보 ---"
nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv,noheader 2>/dev/null || echo "ERROR: nvidia-smi not found"
echo "GPU 수: $(nvidia-smi -L 2>/dev/null | wc -l)"
echo "CUDA: $(nvidia-smi 2>/dev/null | grep 'CUDA Version' | awk '{print $9}')"

echo ""
echo "--- [2/8] GPU Topology (NVLink/NVSwitch) ---"
nvidia-smi topo -m 2>/dev/null || echo "WARNING: topology unavailable"

echo ""
echo "--- [3/8] Slurm 설정 ---"
if command -v sinfo &> /dev/null; then
    echo "파티션 목록:"
    sinfo -o "%P %N %c %m %G %l" 2>/dev/null
    echo ""
    echo "계정 목록:"
    sacctmgr show account format=Account,Descr -p 2>/dev/null | head -10 || echo "(sacctmgr unavailable)"
else
    echo "ERROR: Slurm not installed"
fi

echo ""
echo "--- [4/8] EFA (Elastic Fabric Adapter) ---"
if command -v fi_info &> /dev/null; then
    fi_info -p efa 2>/dev/null | head -10 || echo "EFA provider not found"
else
    echo "fi_info not found"
fi
ls /opt/amazon/efa/ 2>/dev/null && echo "EFA software: /opt/amazon/efa/ EXISTS" || echo "EFA software: NOT FOUND"

echo ""
echo "--- [5/8] NCCL / aws-ofi-nccl ---"
OFI_NCCL_PATH=""
if [ -f /opt/amazon/ofi-nccl/lib/libnccl-net.so ]; then
    OFI_NCCL_PATH=/opt/amazon/ofi-nccl
elif [ -f /opt/amazon/aws-ofi-nccl/lib/libnccl-net.so ]; then
    OFI_NCCL_PATH=/opt/amazon/aws-ofi-nccl
fi

if [ -n "$OFI_NCCL_PATH" ]; then
    echo "aws-ofi-nccl: INSTALLED ($OFI_NCCL_PATH)"
    ls $OFI_NCCL_PATH/lib/ 2>/dev/null
else
    echo "aws-ofi-nccl: NOT FOUND (확인 경로: /opt/amazon/ofi-nccl 또는 /opt/amazon/aws-ofi-nccl)"
fi

echo ""
echo "--- [6/8] Container Runtime ---"
command -v enroot &> /dev/null && echo "Enroot: $(enroot version 2>/dev/null)" || echo "Enroot: not found"
command -v docker &> /dev/null && echo "Docker: $(docker --version 2>/dev/null)" || echo "Docker: not found"
srun --help 2>&1 | grep -q "container-image" && echo "Pyxis: AVAILABLE" || echo "Pyxis: NOT detected"

echo ""
echo "--- [7/8] 공유 파일시스템 ---"
df -h | grep -E "(fsx|lustre|nfs|efs|nvme|Filesystem)" || df -h

echo ""
echo "--- [8/8] 네트워크 인터페이스 ---"
ip link show 2>/dev/null | grep -E "^[0-9]+:" | awk '{print $2}' | tr -d ':'

echo ""
echo "============================================================"
echo " 결과 요약"
echo "============================================================"
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l)
echo "GPU: ${GPU_NAME} x ${GPU_COUNT}/node"
echo ""
echo ">> 다음 단계: 02 스크립트의 SLURM_ACCOUNT, SLURM_PARTITION 값을 위 결과에서 확인하세요"
echo "============================================================"
