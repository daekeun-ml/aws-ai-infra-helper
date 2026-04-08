#!/bin/bash
# =============================================================================
# [Step 2] NeMo 실행 환경 전체 준비
#
#   1. sqsh 컨테이너 생성 (docker export → mksquashfs)
#   2. Pyxis 연결 확인
#   3. Megatron-Bridge 레포 클론 (r0.2.0)
#   4. Python venv + NeMo-Run 설치
#   5. run_script.py 패치 (VENV_BOOTSTRAP_V5 / VP_PP1_FIX / VLM_FORWARD_STEP_FIX)
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
echo " NeMo 실행 환경 전체 준비 (NeMo ${NEMO_VERSION} / MB ${MB_VERSION})"
echo "============================================================"
echo " sqsh:     $SQSH_FILE"
echo " 레포:     $WORK_DIR/Megatron-Bridge  (${MB_VERSION})"
echo " venv:     $WORK_DIR/venv"
echo "============================================================"
echo ""

# =============================================================================
# [1/5] sqsh 컨테이너 생성
# =============================================================================
if [ -f "$SQSH_FILE" ]; then
    echo "[1/5] sqsh 파일 이미 존재, 스킵: $SQSH_FILE ($(ls -lh "$SQSH_FILE" | awk '{print $5}'))"
else
    echo "[1/5] sqsh 생성 중 (최초 1회만)..."
    echo "  docker export로 flat filesystem 생성 → mksquashfs로 변환"
    echo ""

    if ! command -v mksquashfs &>/dev/null; then
        echo "  -> squashfs-tools 설치..."
        sudo apt-get update -qq && sudo apt-get install -y squashfs-tools
    fi

    if [ ! -d "$CONTAINER_DIR" ]; then
        sudo mkdir -p "$CONTAINER_DIR"
        sudo chown $(whoami):$(id -gn) "$CONTAINER_DIR"
    fi

    echo "  [a] docker pull $CONTAINER_IMAGE..."
    if docker image inspect "$CONTAINER_IMAGE" &>/dev/null; then
        echo "  -> 이미지 이미 존재, pull 스킵"
    else
        docker pull "$CONTAINER_IMAGE"
    fi

    FLAT_TAR="${CONTAINER_DIR}/nemo_${NEMO_VERSION}_flat.tar"
    echo "  [b] docker export (flat tar)..."
    docker rm -f nemo_export 2>/dev/null || true
    rm -f "$FLAT_TAR" 2>/dev/null || true
    docker create --name nemo_export "$CONTAINER_IMAGE" /bin/true
    docker export nemo_export -o "$FLAT_TAR"
    docker rm nemo_export
    echo "  -> tar: $(ls -lh "$FLAT_TAR" | awk '{print $5}')"

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
# [2/5] Pyxis 연결 체크
# =============================================================================
check_pyxis() {
    echo "[2/5] Pyxis 연결 상태 확인 중..."
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

    echo "  [복구 1/3] scontrol reconfigure..."
    if ! srun -N "$num_nodes" sudo scontrol reconfigure 2>&1; then
        echo "  [경고] scontrol reconfigure 실패. 다음 단계로 진행합니다."
    fi

    echo "  [복구 2/3] slurmd 재시작..."
    if ! srun -N "$num_nodes" sudo systemctl restart slurmd 2>&1; then
        echo "  [경고] slurmd 재시작 실패."
    fi

    sleep 5

    echo "  [복구 3/3] Pyxis 재검증..."
    if timeout "$timeout_sec" srun -N 1 --container-image="$test_image" nvidia-smi &>/dev/null 2>&1; then
        echo "  -> Pyxis 복구 성공"
        return 0
    fi

    echo ""
    echo "============================================================"
    echo " [경고] Pyxis 자동 복구 실패. 수동 복구 필요:"
    echo "  1) srun -N ${num_nodes} sudo scontrol reconfigure"
    echo "  2) srun -N ${num_nodes} sudo systemctl restart slurmd"
    echo "  3) srun -N 1 --container-image=${test_image} nvidia-smi"
    echo "============================================================"
    return 1
}

check_pyxis
PYXIS_OK=$?
echo ""

# =============================================================================
# [3/5] 작업 디렉토리 + Megatron-Bridge 레포 클론
# =============================================================================
echo "[3/5] 작업 디렉토리 + Megatron-Bridge 레포 (${MB_VERSION})..."
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

echo "  -> ${MB_VERSION} 체크아웃..."
git checkout -f "${MB_VERSION}" 2>/dev/null || git checkout -f main
echo "  -> 현재 브랜치/태그: $(git describe --tags --exact-match 2>/dev/null || git branch --show-current)"
echo ""

# =============================================================================
# [4/5] Python venv + NeMo-Run 설치
# =============================================================================
echo "[4/5] Python venv + NeMo-Run..."

PYTHON_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
if ! python3 -c "import ensurepip" &>/dev/null; then
    echo "  -> python${PYTHON_VERSION}-venv 설치 중..."
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
# [5/5] run_script.py 패치
# =============================================================================
RUN_SCRIPT="scripts/performance/run_script.py"

# ----- 5a: VENV_BOOTSTRAP_V5 -----
# docker export sqsh는 Docker ENV를 모두 잃음. V5 패치로 PATH/LD_LIBRARY_PATH/CUDA/venv 복원.
if ! grep -q "VENV_BOOTSTRAP_V5" "$RUN_SCRIPT" 2>/dev/null; then
    echo "  -> run_script.py V5 패치 적용..."

    if [ -f "${RUN_SCRIPT}.bak" ]; then
        cp "${RUN_SCRIPT}.bak" "$RUN_SCRIPT"
    else
        cp "$RUN_SCRIPT" "${RUN_SCRIPT}.bak"
    fi

    python3 << 'PATCH_EOF'
filepath = "scripts/performance/run_script.py"
with open(filepath, "r") as f:
    content = f.read()

bootstrap = '''# --- VENV_BOOTSTRAP_V5: docker export sqsh full env restore ---
import sys as _sys, os as _os, site as _site, glob as _glob
if '/opt/venv/bin' not in _os.environ.get('PATH', ''):
    _os.environ['PATH'] = '/opt/venv/bin:' + _os.environ.get('PATH', '')
if '/usr/local/cuda/bin' not in _os.environ.get('PATH', ''):
    _os.environ['PATH'] = '/usr/local/cuda/bin:' + _os.environ.get('PATH', '')
_ld = _os.environ.get('LD_LIBRARY_PATH', '')
for _p in ['/usr/local/cuda/lib64', '/usr/local/cuda/compat', '/usr/local/nvidia/lib64',
           '/opt/hpcx/nccl_rdma_sharp_plugin/lib', '/opt/hpcx/ucc/lib',
           '/opt/hpcx/ucx/lib', '/opt/hpcx/ompi/lib', '/opt/hpcx/sharp/lib']:
    if _p not in _ld:
        _ld = _p + ':' + _ld if _ld else _p
_os.environ['LD_LIBRARY_PATH'] = _ld
_os.environ.setdefault('CUDA_HOME', '/usr/local/cuda')
_os.environ.setdefault('CUDA_PATH', '/usr/local/cuda')
_os.environ.setdefault('TORCH_CUDA_ARCH_LIST', _os.environ.get('MB_CUDA_ARCH', '12.0+PTX'))
_lib_path = _os.environ.get('LIBRARY_PATH', '')
if '/usr/local/cuda/lib64/stubs' not in _lib_path:
    _os.environ['LIBRARY_PATH'] = '/usr/local/cuda/lib64/stubs:/usr/local/cuda/lib64' + (':' + _lib_path if _lib_path else '')
_cpath = _os.environ.get('CPATH', '')
if '/usr/local/cuda/include' not in _cpath:
    _os.environ['CPATH'] = '/usr/local/cuda/include' + (':' + _cpath if _cpath else '')
_os.environ.setdefault('NVIDIA_VISIBLE_DEVICES', 'all')
_os.environ.setdefault('NVIDIA_DRIVER_CAPABILITIES', 'compute,utility')
_os.environ.setdefault('CUDA_DEVICE_MAX_CONNECTIONS', '1')
_sp = None
for _pyver in ['3.12', '3.11', '3.13', '3.10']:
    _candidate = f'/opt/venv/lib/python{_pyver}/site-packages'
    if _os.path.isdir(_candidate):
        _sp = _candidate
        break
if _sp:
    _site.addsitedir(_sp)
    _pth_paths = []
    for _pth_file in sorted(_glob.glob(_os.path.join(_sp, '*.pth'))):
        try:
            with open(_pth_file) as _f:
                for _line in _f:
                    _line = _line.strip()
                    if _line and not _line.startswith('#') and not _line.startswith('import '):
                        if _os.path.isdir(_line) and _line not in _sys.path:
                            _pth_paths.append(_line)
        except Exception:
            pass
    for _p in reversed([_sp] + _pth_paths):
        if _p in _sys.path:
            _sys.path.remove(_p)
        _sys.path.insert(0, _p)
    print(f"VENV_BOOTSTRAP_V5: addsitedir({_sp}) + {len(_pth_paths)} editable paths prepended", file=_sys.stderr, flush=True)
else:
    print("VENV_BOOTSTRAP_V5: WARNING - no site-packages found", file=_sys.stderr, flush=True)
try:
    import importlib as _importlib
    _mtd = _importlib.import_module('modelopt.torch.distill.plugins.megatron')
    if not hasattr(_mtd, 'DistillationConfig'):
        class _FallbackDistillationConfig:
            pass
        _mtd.DistillationConfig = _FallbackDistillationConfig
    if not hasattr(_mtd, 'get_tensor_shapes_adjust_fn_for_distillation'):
        _mtd.get_tensor_shapes_adjust_fn_for_distillation = lambda *a, **kw: None
    if not hasattr(_mtd, 'adjust_tensor_shapes_for_distillation'):
        _mtd.adjust_tensor_shapes_for_distillation = lambda *a, **kw: None
    if not hasattr(_mtd, 'get_distillation_loss_func'):
        _mtd.get_distillation_loss_func = lambda *a, **kw: None
except Exception as _e:
    print(f"VENV_BOOTSTRAP_V5: modelopt patch failed: {_e}", file=_sys.stderr, flush=True)
# --- END VENV_BOOTSTRAP_V5 ---
'''

lines = content.split(chr(10))
if lines[0].startswith('#!'):
    lines.insert(1, bootstrap)
else:
    lines.insert(0, bootstrap)
content = chr(10).join(lines)

with open(filepath, "w") as f:
    f.write(content)

print("  -> run_script.py V5 패치 완료")
PATCH_EOF
else
    echo "  -> run_script.py V5 패치 이미 적용됨"
fi

# ----- 5b: VP_PP1_FIX -----
# H100 base config은 PP=2, VP=12. PP=1로 오버라이드 시 VP도 None으로 해제 필요.
if ! grep -q "VP_PP1_FIX" "$RUN_SCRIPT" 2>/dev/null; then
    echo "  -> run_script.py VP=None 패치 적용..."
    python3 << 'PATCH_EOF'
filepath = "scripts/performance/run_script.py"
with open(filepath, "r") as f:
    content = f.read()

old = "    recipe = get_model_recipe_with_user_overrides(**vars(args))\n\n    merged_omega_conf"
new = """    recipe = get_model_recipe_with_user_overrides(**vars(args))

    # VP_PP1_FIX: PP=1이면 VP=None 강제 (base config VP가 남아 있으면 interleaved schedule 오류)
    if recipe.model.pipeline_model_parallel_size == 1 and recipe.model.virtual_pipeline_model_parallel_size is not None:
        recipe.model.virtual_pipeline_model_parallel_size = None

    merged_omega_conf"""

if old in content:
    content = content.replace(old, new, 1)
    with open(filepath, "w") as f:
        f.write(content)
    print("  -> VP=None 패치 완료")
else:
    print("  -> 패턴 미발견 (이미 패치됨?)")
PATCH_EOF
else
    echo "  -> run_script.py VP=None 패치 이미 적용됨"
fi

# ----- 5c: VLM_FORWARD_STEP_FIX -----
# r0.2.0: VLM 모델은 gpt_step 대신 vlm_step.forward_step 사용 (0.3.1에서 내부 통합됨).
if ! grep -q "VLM_FORWARD_STEP_FIX" "$RUN_SCRIPT" 2>/dev/null; then
    echo "  -> run_script.py VLM forward_step 패치 적용..."
    python3 << 'PATCH_EOF'
filepath = "scripts/performance/run_script.py"
with open(filepath, "r") as f:
    content = f.read()

old_import = "from megatron.bridge.training.gpt_step import forward_step"
new_import = """\
# VLM_FORWARD_STEP_FIX: VLM 모델은 vlm_step.forward_step, LLM은 gpt_step.forward_step 사용
from megatron.bridge.training.gpt_step import forward_step as _gpt_forward_step
try:
    from megatron.bridge.training.vlm_step import forward_step as _vlm_forward_step
except ImportError:
    _vlm_forward_step = _gpt_forward_step"""

old_pretrain = "    pretrain(config=recipe, forward_step_func=forward_step)"
new_pretrain = """\
    _is_vlm = type(recipe.dataset).__module__.startswith("megatron.bridge.data.vlm_datasets")
    forward_step = _vlm_forward_step if _is_vlm else _gpt_forward_step
    pretrain(config=recipe, forward_step_func=forward_step)"""

if old_import not in content:
    print("  -> import 패턴 미발견, 스킵")
elif old_pretrain not in content:
    print("  -> pretrain 호출 패턴 미발견, 스킵")
else:
    content = content.replace(old_import, new_import, 1)
    content = content.replace(old_pretrain, new_pretrain, 1)
    with open(filepath, "w") as f:
        f.write(content)
    print("  -> VLM forward_step 패치 완료")
PATCH_EOF
else
    echo "  -> run_script.py VLM forward_step 패치 이미 적용됨"
fi

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
echo " 레포:  $WORK_DIR/Megatron-Bridge  (${MB_VERSION})"
echo " venv:  $WORK_DIR/venv"
echo ""
echo " 다음 단계: 02_run_basic.sh 또는 03_run_aws_optimized.sh 를 실행하세요."
echo "============================================================"
