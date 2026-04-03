#!/bin/bash
# =============================================================================
# [Step 2] NeMo 컨테이너 sqsh 준비
#
# docker export로 flat filesystem sqsh 생성.
# ENV 손실은 run_script.py sys.path 패치(V5)로 해결.
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

source "${SCRIPT_DIR}/env.sh"

echo "============================================================"
echo " NeMo 컨테이너 sqsh 준비"
echo "============================================================"
echo " 대상: $SQSH_FILE"
echo "============================================================"
echo ""

if [ -f "$SQSH_FILE" ]; then
    echo "[완료] sqsh 파일 이미 존재: $SQSH_FILE ($(ls -lh "$SQSH_FILE" | awk '{print $5}'))"
    echo "       03_run_basic.sh 또는 04_run_aws_optimized.sh 를 실행하세요."
    exit 0
fi

echo "[1/3] sqsh 생성 중 (최초 1회만)..."
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
FULL_IMAGE="$CONTAINER_IMAGE"
echo "  [a] docker pull $FULL_IMAGE..."
if docker image inspect "$FULL_IMAGE" &>/dev/null; then
    echo "  -> 이미지 이미 존재, pull 스킵"
else
    docker pull "$FULL_IMAGE"
fi

# [b] docker export (flat filesystem, no layers → overlay mount 문제 회피)
FLAT_TAR="${CONTAINER_DIR}/nemo_${NEMO_VERSION}_flat.tar"
echo "  [b] docker export (flat tar)..."
docker rm -f nemo_export 2>/dev/null || true
rm -f "$FLAT_TAR" 2>/dev/null || true
docker create --name nemo_export "$FULL_IMAGE" /bin/true
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
    echo "============================================================"
    echo " sqsh 생성 완료: $SQSH_FILE"
    echo " 크기: $(ls -lh "$SQSH_FILE" | awk '{print $5}')"
    echo "============================================================"
    echo " 다음 단계: 03_run_basic.sh 를 실행하세요."
    echo "============================================================"
else
    echo "ERROR: sqsh 생성 실패!"
    exit 1
fi
