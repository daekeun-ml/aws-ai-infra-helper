#!/bin/bash
# =============================================================================
# [Step 2] NeMo 실행 환경 전체 준비
#
#   1. sqsh 컨테이너 생성 (docker export → mksquashfs)
#   2. Pyxis 연결 확인
#   3. Megatron-Bridge 레포 클론 (v0.3.1)
#   4. Python venv + NeMo-Run 설치
#
# 사용법: login 노드 또는 compute 노드에서 직접 실행
#   login 노드에서 실행 시 sinfo로 첫 번째 compute 노드를 찾아 자동으로 SSH 재실행
# =============================================================================

# SSH stdin 경유 실행 시 SCRIPT_DIR이 env로 전달됨; 직접 실행 시 여기서 계산
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# GPU 없으면 login 노드로 간주 → 첫 번째 compute 노드로 SSH하여 재실행
if ! nvidia-smi -L &>/dev/null; then
    echo "[INFO] GPU 미감지 (login 노드). sinfo로 compute 노드 탐색 중..."
    NODELIST=$(sinfo -h -o "%N" 2>/dev/null | head -1)
    FIRST_NODE=$(scontrol show hostnames "$NODELIST" 2>/dev/null | head -1)
    if [ -z "$FIRST_NODE" ]; then
        echo "ERROR: sinfo로 compute 노드를 찾을 수 없습니다. Slurm이 실행 중인지 확인하세요."
        exit 1
    fi
    echo "[INFO] Compute 노드 접속: $FIRST_NODE"
    echo ""
    ssh -o StrictHostKeyChecking=no "$FIRST_NODE" "SCRIPT_DIR='$SCRIPT_DIR' bash -s" < "$0"
    exit $?
fi

set -euo pipefail

source "${SCRIPT_DIR}/env.sh"

echo "============================================================"
echo " NeMo 실행 환경 전체 준비"
echo "============================================================"
echo " sqsh:     $SQSH_FILE"
echo " 레포:     $WORK_DIR/Megatron-Bridge"
echo " venv:     $WORK_DIR/venv"
echo "============================================================"
echo ""

# =============================================================================
# [1/4] sqsh 컨테이너 생성
# =============================================================================
if [ -f "$SQSH_FILE" ]; then
    echo "[1/4] sqsh 파일 이미 존재, 스킵: $SQSH_FILE ($(ls -lh "$SQSH_FILE" | awk '{print $5}'))"
else
    echo "[1/4] sqsh 생성 중 (최초 1회만)..."
    echo "  docker export로 flat filesystem 생성 → mksquashfs로 변환"
    echo ""

    # mksquashfs 확인
    if ! command -v mksquashfs &>/dev/null; then
        echo "  -> squashfs-tools 설치..."
        sudo apt-get update -qq && sudo apt-get install -y squashfs-tools
    fi

    # 디렉토리 생성
    if [ ! -d "$CONTAINER_DIR" ]; then
        sudo mkdir -p "$CONTAINER_DIR"
        sudo chown $(whoami):$(id -gn) "$CONTAINER_DIR"
    fi

    # [a] docker pull
    echo "  [a] docker pull $CONTAINER_IMAGE..."
    if docker image inspect "$CONTAINER_IMAGE" &>/dev/null; then
        echo "  -> 이미지 이미 존재, pull 스킵"
    else
        docker pull "$CONTAINER_IMAGE"
    fi

    # [b] docker export (flat filesystem, no layers → overlay mount 문제 회피)
    FLAT_TAR="${CONTAINER_DIR}/nemo_${NEMO_VERSION}_flat.tar"
    echo "  [b] docker export (flat tar)..."
    docker rm -f nemo_export 2>/dev/null || true
    rm -f "$FLAT_TAR" 2>/dev/null || true
    docker create --name nemo_export "$CONTAINER_IMAGE" /bin/true
    docker export nemo_export -o "$FLAT_TAR"
    docker rm nemo_export
    echo "  -> tar: $(ls -lh "$FLAT_TAR" | awk '{print $5}')"

    # [c] mksquashfs
    echo "  [c] mksquashfs (tar → sqsh)..."
    if sudo mksquashfs - "$SQSH_FILE" -tar -comp zstd -processors "$(nproc)" < "$FLAT_TAR" 2>/dev/null; then
        echo "  -> mksquashfs -tar 성공"
    else
        echo "  -> mksquashfs -tar 미지원, 추출 후 변환..."
        rm -f "$SQSH_FILE" 2>/dev/null || true
        EXPORT_DIR="${CONTAINER_DIR}/nemo_rootfs"
        sudo mkdir -p "$EXPORT_DIR"
        tar xf "$FLAT_TAR" -C "$EXPORT_DIR"
        sudo mksquashfs "$EXPORT_DIR" "$SQSH_FILE" -comp zstd -processors "$(nproc)" -noappend
        sudo rm -rf "$EXPORT_DIR"
    fi

    rm -f "$FLAT_TAR" 2>/dev/null || true
    sudo chown $(whoami):$(id -gn) "$SQSH_FILE"

    if [ -f "$SQSH_FILE" ]; then
        echo ""
        echo "  sqsh 생성 완료: $SQSH_FILE ($(ls -lh "$SQSH_FILE" | awk '{print $5}'))"
    else
        echo "ERROR: sqsh 생성 실패!"
        exit 1
    fi
fi
echo ""

# =============================================================================
# [2/4] Pyxis 연결 체크
# =============================================================================
check_pyxis() {
    echo "[2/4] Pyxis 연결 상태 확인 중..."
    local test_image="nvcr.io#nvidia/cuda:11.8.0-base-ubuntu22.04"
    local timeout_sec=60

    if timeout "$timeout_sec" srun -N 1 --container-image="$test_image" true &>/dev/null 2>&1; then
        echo "  -> Pyxis 정상 동작 확인"
        return 0
    fi

    echo "  [경고] Pyxis 연결 실패. 자동 복구를 시도합니다..."

    local num_nodes
    num_nodes=$(sinfo -h -o "%D" 2>/dev/null | awk '{sum+=$1} END{print sum}')
    if [ -z "$num_nodes" ] || [ "$num_nodes" -eq 0 ]; then
        echo "  [경고] sinfo로 노드 수를 확인할 수 없습니다. num_nodes=1 로 시도합니다."
        num_nodes=1
    fi
    echo "  -> 클러스터 노드 수: $num_nodes"

    echo "  [복구 1/3] slurmctld → slurmd plugstack 재배포 (scontrol reconfigure)..."
    if ! srun -N "$num_nodes" sudo scontrol reconfigure 2>&1; then
        echo "  [경고] scontrol reconfigure 실패 (권한 부족 등). 다음 단계로 진행합니다."
    fi

    echo "  [복구 2/3] 각 컴퓨트 노드 slurmd 재시작..."
    if ! srun -N "$num_nodes" sudo systemctl restart slurmd 2>&1; then
        echo "  [경고] slurmd 재시작 실패. 수동으로 각 노드에서 실행해야 할 수 있습니다."
    fi

    sleep 5

    echo "  [복구 3/3] Pyxis 재검증..."
    if timeout "$timeout_sec" srun -N 1 --container-image="$test_image" nvidia-smi &>/dev/null 2>&1; then
        echo "  -> Pyxis 복구 성공"
        return 0
    fi

    echo ""
    echo "============================================================"
    echo " [경고] Pyxis 자동 복구 실패"
    echo "  아래 순서로 수동 복구를 진행하세요:"
    echo ""
    echo "  1) 컨트롤러 노드에서:"
    echo "     srun -N ${num_nodes} sudo scontrol reconfigure"
    echo ""
    echo "  2) 각 컴퓨트 노드에서 (또는 srun으로):"
    echo "     srun -N ${num_nodes} sudo systemctl restart slurmd"
    echo ""
    echo "  3) 동작 검증:"
    echo "     srun -N 1 --container-image=${test_image} nvidia-smi"
    echo "============================================================"
    echo " 원인: Slurm은 slurmctld(컨트롤러)가 plugstack.conf를 관리하고"
    echo "       slurmd(컴퓨트 노드)가 시작 시 컨트롤러에서 가져오는 구조입니다."
    echo "       pyxis/enroot 설치 후 slurmd를 재시작하지 않으면 이 오류가 발생합니다."
    echo "============================================================"
    return 1
}

check_pyxis
PYXIS_OK=$?
echo ""

# =============================================================================
# [3/4] 작업 디렉토리 + Megatron-Bridge 레포 클론
# =============================================================================
echo "[3/4] 작업 디렉토리 + Megatron-Bridge 레포..."
if [ ! -d "$WORK_DIR" ]; then
    sudo mkdir -p "$WORK_DIR"
    sudo chown $(whoami):$(id -gn) "$WORK_DIR"
fi
cd "$WORK_DIR"

if [ -d "Megatron-Bridge" ]; then
    echo "  -> 이미 존재. git fetch..."
    cd Megatron-Bridge
    git fetch --all
else
    git clone https://github.com/NVIDIA-NeMo/Megatron-Bridge.git
    cd Megatron-Bridge
fi

echo "  -> v0.3.1 태그 체크아웃..."
git stash 2>/dev/null; git checkout v0.3.1 2>/dev/null || git checkout main
echo "  -> 현재 브랜치/태그: $(git describe --tags --exact-match 2>/dev/null || git branch --show-current)"
echo ""

# =============================================================================
# [4/4] Python venv + NeMo-Run 설치
# =============================================================================
echo "[4/4] Python venv + NeMo-Run..."

PYTHON_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
if ! python3 -c "import ensurepip" &>/dev/null; then
    echo "  -> python${PYTHON_VERSION}-venv 설치 중 (ensurepip 없음)..."
    sudo apt-get update -qq && sudo apt-get install -y -qq python3-venv "python${PYTHON_VERSION}-venv" 2>/dev/null || true
fi

VENV_DIR="$WORK_DIR/venv"
if [ -d "$VENV_DIR" ] && [ ! -f "$VENV_DIR/bin/activate" ]; then
    rm -rf "$VENV_DIR"
fi
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"

if ! python3 -c "import nemo_run" &>/dev/null; then
    pip install --upgrade pip
    echo "  -> NeMo-Run 설치 중..."
    pip install git+https://github.com/NVIDIA-NeMo/Run.git
else
    echo "  -> NeMo-Run 이미 설치됨"
fi

# NeMo-Run git packager tar 에러 패치
# FSx Lustre에서 "tar: .: file changed as we read it" (exit 1) 발생.
# invoke가 exit 1을 에러로 처리하여 submit 실패.
# git.py의 ctx.run()에 warn=True 추가하여 tar warning 무시.
GIT_PKG=$(python3 -c "import nemo_run.core.packaging.git as g; print(g.__file__)" 2>/dev/null || true)
if [ -n "$GIT_PKG" ] && ! grep -q "warn=True" "$GIT_PKG" 2>/dev/null; then
    echo "  -> NeMo-Run git packager tar 에러 패치..."
    sed -i 's/ctx\.run(f"tar cf {quoted_output_file} -C {temp_dir} \.")/ctx.run(f"tar cf {quoted_output_file} -C {temp_dir} .", warn=True)/g' "$GIT_PKG"
    echo "  -> 패치 완료"
elif [ -n "$GIT_PKG" ]; then
    echo "  -> NeMo-Run tar 패치 이미 적용됨"
fi

deactivate
echo ""

# =============================================================================
# 최종 요약
# =============================================================================
echo "============================================================"
if [ "$PYXIS_OK" -eq 0 ]; then
    echo " 모든 준비 완료."
else
    echo " 레포/venv 준비 완료. Pyxis 연결은 위 안내에 따라 수동 복구하세요."
fi
echo ""
echo " sqsh:  $SQSH_FILE"
echo " 레포:  $WORK_DIR/Megatron-Bridge  (v0.3.1)"
echo " venv:  $WORK_DIR/venv"
echo ""
echo " 다음 단계: 02_run_basic.sh 또는 03_run_aws_optimized.sh 를 실행하세요."
echo "============================================================"
