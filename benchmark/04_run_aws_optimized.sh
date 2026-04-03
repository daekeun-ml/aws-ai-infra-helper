#!/bin/bash
# =============================================================================
# [Step 4] AWS 최적화 멀티노드 벤치마크
#
# 지원 모델:
#   - Qwen3 30B A3B     (MoE, fp8_cs/fp8_mx)
#   - Llama3 8B         (Dense, fp8_cs/fp8_mx/bf16)
#   - GPT-OSS 120B      (MoE, bf16 only)
#   - Qwen3-VL 30B A3B  (VLM Pretrain, bf16/fp8_cs/fp8_mx)
#
# 사전 조건: 02_prepare_container.sh + 03_run_basic.sh 실행 완료 (레포, venv, sqsh 이미 세팅됨)
#
# v0.3.1에서 docker export sqsh + EFA 멀티노드 구성.
# setup_experiment.py의 nccl_ub 블록 뒤에 EFA/NCCL 환경변수 패치.
#
# 핵심 해결 사항:
#   1. docker export sqsh → custom_env_vars + run_script.py V5 bootstrap로 ENV 복원
#   2. Host EFA 라이브러리(libfabric 2.3+) → -cm 단일 옵션에 comma-separated 마운트
#   3. NCCL_NET_PLUGIN=aws-ofi → aws-ofi-nccl 플러그인 활성화
#   4. NCCL_PROTO/ALGO 제거 → aws-ofi-nccl 자동 튜닝 사용 (지정시 hang 발생)
#   5. PP=1 시 VP=None 강제 (H100 base config VP=12 오버라이드)
# =============================================================================

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# Host EFA 라이브러리 마운트 (콤마 구분, 단일 -cm 옵션)
# 주의: -cm 옵션은 argparse store 타입이므로 마지막 값만 유지됨 → 반드시 단일 옵션으로 모두 지정
# Host libfabric (2.3+)은 EFA_1.4 심볼 필요 → host libefa + libibverbs도 함께 마운트
CUSTOM_MOUNTS="/opt/amazon/efa:/opt/amazon/efa"
CUSTOM_MOUNTS="${CUSTOM_MOUNTS},/opt/amazon/ofi-nccl:/opt/amazon/ofi-nccl"
CUSTOM_MOUNTS="${CUSTOM_MOUNTS},/usr/lib/x86_64-linux-gnu/libefa.so.1:/usr/lib/x86_64-linux-gnu/libefa.so.1"
CUSTOM_MOUNTS="${CUSTOM_MOUNTS},/usr/lib/x86_64-linux-gnu/libefa.so.1.4.60.0:/usr/lib/x86_64-linux-gnu/libefa.so.1.4.60.0"
CUSTOM_MOUNTS="${CUSTOM_MOUNTS},/usr/lib/x86_64-linux-gnu/libibverbs.so.1:/usr/lib/x86_64-linux-gnu/libibverbs.so.1"
CUSTOM_MOUNTS="${CUSTOM_MOUNTS},/usr/lib/x86_64-linux-gnu/libibverbs.so.1.15.60.0:/usr/lib/x86_64-linux-gnu/libibverbs.so.1.15.60.0"
CUSTOM_MOUNTS="${CUSTOM_MOUNTS},/usr/lib/x86_64-linux-gnu/libibverbs:/usr/lib/x86_64-linux-gnu/libibverbs"
# =================================================================

# ===================== 모델 선택 =====================
echo "모델을 선택하세요:"
echo "  1) Qwen3 30B A3B     (MoE)"
echo "  2) Llama3 8B         (Dense)"
echo "  3) GPT-OSS 120B      (MoE, bf16 only)"
echo "  4) Qwen3-VL 30B A3B  (VLM Pretrain)"
read -p "선택 (1/2/3/4): " model_choice

case "$model_choice" in
    1) MODEL_NAME="qwen";    PRESET_PREFIX="qwen3";    MODEL_SIZE="30b_a3b" ;;
    2) MODEL_NAME="llama";   PRESET_PREFIX="llama3";   MODEL_SIZE="8b" ;;
    3) MODEL_NAME="gpt_oss"; PRESET_PREFIX="gpt_oss";  MODEL_SIZE="120b" ;;
    4) MODEL_NAME="qwen_vl"; PRESET_PREFIX="qwen3_vl"; MODEL_SIZE="30b_a3b" ;;
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

# GPT-OSS는 bf16만 지원
[ "$MODEL_NAME" = "gpt_oss" ] && FP8_PRECISION="bf16"

# GPU 수 선택 (sinfo로 최대 노드 수 확인 후 사용자 선택)
GPUS_PER_NODE=8
MAX_NODES=$(sinfo -p "$SLURM_PARTITION" -h -o "%D" 2>/dev/null | awk '{s+=$1} END{print s+0}')
if [ "${MAX_NODES:-0}" -eq 0 ]; then
    echo "ERROR: sinfo에서 파티션 '$SLURM_PARTITION' 노드 수를 감지하지 못했습니다."
    echo "       sinfo -p $SLURM_PARTITION 출력을 확인하세요."
    exit 1
fi
echo "  -> 파티션 '$SLURM_PARTITION' 최대 노드: ${MAX_NODES}개"
echo ""
echo "사용할 노드 수를 선택하세요 (1~${MAX_NODES}):"
for n in $(seq 1 "$MAX_NODES"); do
    echo "  ${n}) ${n}노드 ($((n * GPUS_PER_NODE)) GPU)"
done
read -p "선택 (1~${MAX_NODES}): " node_choice
if ! [[ "$node_choice" =~ ^[0-9]+$ ]] || [ "$node_choice" -lt 1 ] || [ "$node_choice" -gt "$MAX_NODES" ]; then
    echo "잘못된 선택. 종료."
    exit 1
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
# =========================================================

echo "============================================================"
echo " $MODEL_NAME $MODEL_SIZE AWS 최적화 멀티노드 벤치마크"
echo "============================================================"
echo " Slurm Account:  $SLURM_ACCOUNT"
echo " Slurm Partition: $SLURM_PARTITION"
echo " GPU:             $NUM_GPUS x $GPU_TYPE (${NUM_NODES}노드)"
echo " FP8 Precision:   $FP8_PRECISION"
echo " Work Dir:        $WORK_DIR (FSx Lustre)"
echo "============================================================"

# ----- 컨테이너 확인 -----
if [ -f "$SQSH_FILE" ]; then
    echo "[0] sqsh 컨테이너 사용: $SQSH_FILE ($(ls -lh "$SQSH_FILE" | awk '{print $5}'))"
else
    echo "ERROR: sqsh 파일 없음: $SQSH_FILE"
    echo "먼저 02_run_qwen3_30b_basic.sh를 실행하세요."
    exit 1
fi

cd "$WORK_DIR/Megatron-Bridge"
source "$WORK_DIR/venv/bin/activate"

# NeMo-Run git packager tar 에러 패치 (02에서 이미 적용, 재확인)
GIT_PKG=$(python3 -c "import nemo_run.core.packaging.git as g; print(g.__file__)" 2>/dev/null || true)
if [ -n "$GIT_PKG" ] && ! grep -q "warn=True" "$GIT_PKG" 2>/dev/null; then
    echo "  -> NeMo-Run git packager tar 패치..."
    sed -i 's/ctx\.run(f"tar cf {quoted_output_file} -C {temp_dir} \.")/ctx.run(f"tar cf {quoted_output_file} -C {temp_dir} .", warn=True)/g' "$GIT_PKG"
fi

# ----- run_script.py V5 패치 확인 및 적용 -----
RUN_SCRIPT="scripts/performance/run_script.py"
if ! grep -q "VENV_BOOTSTRAP_V5" "$RUN_SCRIPT" 2>/dev/null; then
    echo "  -> run_script.py V5 패치 적용 중..."

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
# docker export loses ALL Docker ENV. Restore critical environment:
# 1) PATH
if '/opt/venv/bin' not in _os.environ.get('PATH', ''):
    _os.environ['PATH'] = '/opt/venv/bin:' + _os.environ.get('PATH', '')
if '/usr/local/cuda/bin' not in _os.environ.get('PATH', ''):
    _os.environ['PATH'] = '/usr/local/cuda/bin:' + _os.environ.get('PATH', '')
# 2) LD_LIBRARY_PATH
_ld = _os.environ.get('LD_LIBRARY_PATH', '')
for _p in ['/usr/local/cuda/lib64', '/usr/local/cuda/compat', '/usr/local/nvidia/lib64',
           '/opt/hpcx/nccl_rdma_sharp_plugin/lib', '/opt/hpcx/ucc/lib',
           '/opt/hpcx/ucx/lib', '/opt/hpcx/ompi/lib', '/opt/hpcx/sharp/lib']:
    if _p not in _ld:
        _ld = _p + ':' + _ld if _ld else _p
_os.environ['LD_LIBRARY_PATH'] = _ld
# 3) CUDA environment (lost by docker export)
_os.environ.setdefault('CUDA_HOME', '/usr/local/cuda')
_os.environ.setdefault('CUDA_PATH', '/usr/local/cuda')
_os.environ.setdefault('TORCH_CUDA_ARCH_LIST', _os.environ.get('MB_CUDA_ARCH', '12.0+PTX'))
_lib_path = _os.environ.get('LIBRARY_PATH', '')
if '/usr/local/cuda/lib64/stubs' not in _lib_path:
    _os.environ['LIBRARY_PATH'] = '/usr/local/cuda/lib64/stubs:/usr/local/cuda/lib64' + (':' + _lib_path if _lib_path else '')
_cpath = _os.environ.get('CPATH', '')
if '/usr/local/cuda/include' not in _cpath:
    _os.environ['CPATH'] = '/usr/local/cuda/include' + (':' + _cpath if _cpath else '')
# 4) NVIDIA env
_os.environ.setdefault('NVIDIA_VISIBLE_DEVICES', 'all')
_os.environ.setdefault('NVIDIA_DRIVER_CAPABILITIES', 'compute,utility')
_os.environ.setdefault('CUDA_DEVICE_MAX_CONNECTIONS', '1')
# 5) Restore venv site-packages with editable installs
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
# 6) Monkey-patch modelopt distillation API for container version mismatch
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
    echo "  -> run_script.py V5 패치 확인됨"
fi

# ----- run_script.py VP=None 패치 (PP=1일 때 VP 강제 해제) -----
# v0.3.1: set_post_overrides 이후 / forward_step 선택 이전에 삽입.
if ! grep -q "VP_PP1_FIX" "$RUN_SCRIPT" 2>/dev/null; then
    echo "  -> run_script.py VP=None 패치 적용..."
    python3 << 'PATCH_EOF'
filepath = "scripts/performance/run_script.py"
with open(filepath, "r") as f:
    content = f.read()

old = '    # Select forward step function based on the model family name.\n    if args.domain == "vlm":'
new = """    # VP_PP1_FIX: PP=1이면 VP=None 강제 (base config VP가 남아 있으면 interleaved schedule 오류)
    if recipe.model.pipeline_model_parallel_size == 1 and recipe.model.virtual_pipeline_model_parallel_size is not None:
        recipe.model.virtual_pipeline_model_parallel_size = None

    # VLM_VP_FIX: 컨테이너 VLM은 VP 미지원 → VP=None 강제 + moe_a2a_overlap 비활성화
    # (PP>1 + overlap_moe_expert_parallel_comm=True이면 VP!=None 필수 assertion 회피 목적)
    if args.domain == "vlm":
        recipe.model.virtual_pipeline_model_parallel_size = None
        if hasattr(recipe, 'comm_overlap'):
            recipe.comm_overlap.overlap_moe_expert_parallel_comm = False
            recipe.comm_overlap.delay_wgrad_compute = False

    # Select forward step function based on the model family name.
    if args.domain == "vlm":"""

if old in content:
    content = content.replace(old, new, 1)
    with open(filepath, "w") as f:
        f.write(content)
    print("  -> VP=None 패치 완료")
else:
    print("  -> 패턴 미발견 (이미 패치됨?)")
PATCH_EOF
else
    echo "  -> run_script.py VP=None 패치 확인됨"
fi

# ----- VLM_VP_FIX 패치 (VP_PP1_FIX 적용됐지만 VLM_VP_FIX 없는 경우) -----
if grep -q "VP_PP1_FIX" "$RUN_SCRIPT" 2>/dev/null && ! grep -q "VLM_VP_FIX" "$RUN_SCRIPT" 2>/dev/null; then
    echo "  -> run_script.py에 VLM_VP_FIX 패치 추가..."
    python3 << 'PATCH_EOF'
filepath = "scripts/performance/run_script.py"
with open(filepath, "r") as f:
    content = f.read()

old = '''    # VP_PP1_FIX: PP=1이면 VP=None 강제 (base config VP가 남아 있으면 interleaved schedule 오류)
    if recipe.model.pipeline_model_parallel_size == 1 and recipe.model.virtual_pipeline_model_parallel_size is not None:
        recipe.model.virtual_pipeline_model_parallel_size = None

    # Select forward step function based on the model family name.
    if args.domain == "vlm":'''
new = '''    # VP_PP1_FIX: PP=1이면 VP=None 강제 (base config VP가 남아 있으면 interleaved schedule 오류)
    if recipe.model.pipeline_model_parallel_size == 1 and recipe.model.virtual_pipeline_model_parallel_size is not None:
        recipe.model.virtual_pipeline_model_parallel_size = None

    # VLM_VP_FIX: 컨테이너 VLM은 VP 미지원 → VP=None 강제 + moe_a2a_overlap 비활성화
    # (PP>1 + overlap_moe_expert_parallel_comm=True이면 VP!=None 필수 assertion 회피 목적)
    if args.domain == "vlm":
        recipe.model.virtual_pipeline_model_parallel_size = None
        if hasattr(recipe, 'comm_overlap'):
            recipe.comm_overlap.overlap_moe_expert_parallel_comm = False
            recipe.comm_overlap.delay_wgrad_compute = False

    # Select forward step function based on the model family name.
    if args.domain == "vlm":'''

if old in content:
    content = content.replace(old, new, 1)
    with open(filepath, "w") as f:
        f.write(content)
    print("  -> VLM_VP_FIX 패치 완료")
else:
    print("  -> 패턴 미발견 (이미 패치됨?)")
PATCH_EOF
else
    echo "  -> run_script.py VLM_VP_FIX 이미 적용됨"
fi

# ----- run_script.py에 Megatron-Bridge v0.3.1 src 경로 패치 -----
# 컨테이너에는 v0.2.0이 /opt/Megatron-Bridge에 설치되어 있음.
# v0.3.1 스크립트가 필요한 새 심볼(set_deepseek_v3_pipeline_model_parallel_layout 등)은
# 체크아웃된 FSx 소스에만 존재 → sys.path 맨 앞에 삽입해 컨테이너 설치본 override.
if ! grep -q "MB_SRC_V031" "$RUN_SCRIPT" 2>/dev/null; then
    echo "  -> run_script.py에 Megatron-Bridge v0.3.1 src 경로 삽입..."
    python3 << 'PATCH_EOF'
filepath = "scripts/performance/run_script.py"
with open(filepath, "r") as f:
    content = f.read()

patch = '''# MB_SRC_V031: override container's old megatron.bridge with v0.3.1 from FSx
import sys as _sys3, os as _os3
_mb_src = '/fsx/megatron-bridge-test/Megatron-Bridge/src'
if _os3.path.isdir(_mb_src) and _mb_src not in _sys3.path:
    _sys3.path.insert(0, _mb_src)
# END MB_SRC_V031
'''

marker = '# --- END VENV_BOOTSTRAP_V5 ---'
if marker in content:
    content = content.replace(marker, marker + '\n' + patch, 1)
    with open(filepath, "w") as f:
        f.write(content)
    print("  -> MB_SRC_V031 패치 완료")
else:
    print("  -> END VENV_BOOTSTRAP_V5 마커 미발견")
PATCH_EOF
else
    echo "  -> run_script.py MB_SRC_V031 패치 이미 적용됨"
fi

# ----- setup_experiment.py에 EFA/NCCL 환경변수 패치 -----
SETUP_SCRIPT="scripts/performance/setup_experiment.py"
# v0.3.1: custom_env_vars={} 패턴 제거됨. nccl_ub 블록 뒤에 EFA/NCCL+CUDA/NVIDIA env 삽입.
if ! grep -q "EFA_NCCL_ENV_RESTORE" "$SETUP_SCRIPT" 2>/dev/null; then
    echo "  -> setup_experiment.py에 EFA/NCCL env 패치 적용..."

    python3 << 'PATCH_EOF'
filepath = "scripts/performance/setup_experiment.py"
with open(filepath, "r") as f:
    content = f.read()

old = '    if nccl_ub:\n        custom_env_vars.update({"NCCL_NVLS_ENABLE": "1", "NCCL_CTA_POLICY": "1"})'
new = '''    if nccl_ub:
        custom_env_vars.update({"NCCL_NVLS_ENABLE": "1", "NCCL_CTA_POLICY": "1"})
    # EFA_NCCL_ENV_RESTORE: docker export sqsh loses Docker ENV + EFA/NCCL env for AWS multi-node.
    custom_env_vars.setdefault("NVIDIA_VISIBLE_DEVICES", "all")
    custom_env_vars.setdefault("NVIDIA_DRIVER_CAPABILITIES", "compute,utility")
    custom_env_vars.setdefault("CUDA_HOME", "/usr/local/cuda")
    custom_env_vars.setdefault("CUDA_PATH", "/usr/local/cuda")
    custom_env_vars.setdefault("LIBRARY_PATH", "/usr/local/cuda/lib64/stubs:/usr/local/cuda/lib64")
    custom_env_vars.setdefault("CPATH", "/usr/local/cuda/include")
    custom_env_vars.setdefault("PATH", "/opt/venv/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
    custom_env_vars.setdefault("TRITON_PTXAS_PATH", "/usr/local/cuda/bin/ptxas")
    custom_env_vars.setdefault("FI_PROVIDER", "efa")
    custom_env_vars.setdefault("FI_EFA_USE_DEVICE_RDMA", "1")
    custom_env_vars.setdefault("FI_EFA_FORK_SAFE", "1")
    custom_env_vars.setdefault("NCCL_NET_PLUGIN", "aws-ofi")
    custom_env_vars.setdefault("NCCL_SOCKET_IFNAME", "^lo,docker0")
    custom_env_vars.setdefault("NCCL_DEBUG", "INFO")
    custom_env_vars.setdefault("NCCL_DEBUG_SUBSYS", "INIT,NET")
    custom_env_vars.setdefault("LD_LIBRARY_PATH", "/opt/amazon/efa/lib:/opt/amazon/ofi-nccl/lib:/usr/local/cuda/lib64:/usr/local/cuda/compat:/usr/local/nvidia/lib64:/opt/hpcx/nccl_rdma_sharp_plugin/lib:/opt/hpcx/ucc/lib:/opt/hpcx/ucx/lib:/opt/hpcx/ompi/lib:/opt/hpcx/sharp/lib")
    # MB_PYTHONPATH: 컨테이너 내 구버전 megatron.bridge를 FSx v0.3.1로 override하기 위해 PYTHONPATH 앞에 삽입
    _mb_src = "/fsx/megatron-bridge-test/Megatron-Bridge/src"
    _cur_pp = custom_env_vars.get("PYTHONPATH", "")
    if _mb_src not in _cur_pp:
        custom_env_vars["PYTHONPATH"] = _mb_src + (":" + _cur_pp if _cur_pp else "")'''

if old in content:
    content = content.replace(old, new, 1)
    with open(filepath, "w") as f:
        f.write(content)
    print("  -> EFA/NCCL env 패치 완료")
else:
    print("  -> nccl_ub 패턴 미발견 (이미 패치됨?)")
PATCH_EOF
else
    echo "  -> setup_experiment.py EFA/NCCL 패치 이미 적용됨"
fi

# ----- setup_experiment.py에 MB_PYTHONPATH 패치 (EFA_NCCL_ENV_RESTORE 이미 적용된 경우) -----
if grep -q "EFA_NCCL_ENV_RESTORE" "$SETUP_SCRIPT" 2>/dev/null && ! grep -q "MB_PYTHONPATH" "$SETUP_SCRIPT" 2>/dev/null; then
    echo "  -> setup_experiment.py에 MB_PYTHONPATH 패치 적용..."
    python3 << 'PATCH_EOF'
filepath = "scripts/performance/setup_experiment.py"
with open(filepath, "r") as f:
    content = f.read()

old = '    custom_env_vars.setdefault("LD_LIBRARY_PATH", "/opt/amazon/efa/lib:/opt/amazon/ofi-nccl/lib:/usr/local/cuda/lib64:/usr/local/cuda/compat:/usr/local/nvidia/lib64:/opt/hpcx/nccl_rdma_sharp_plugin/lib:/opt/hpcx/ucc/lib:/opt/hpcx/ucx/lib:/opt/hpcx/ompi/lib:/opt/hpcx/sharp/lib")'
new = '''    custom_env_vars.setdefault("LD_LIBRARY_PATH", "/opt/amazon/efa/lib:/opt/amazon/ofi-nccl/lib:/usr/local/cuda/lib64:/usr/local/cuda/compat:/usr/local/nvidia/lib64:/opt/hpcx/nccl_rdma_sharp_plugin/lib:/opt/hpcx/ucc/lib:/opt/hpcx/ucx/lib:/opt/hpcx/ompi/lib:/opt/hpcx/sharp/lib")
    # MB_PYTHONPATH: 컨테이너 내 구버전 megatron.bridge를 FSx v0.3.1로 override하기 위해 PYTHONPATH 앞에 삽입
    _mb_src = "/fsx/megatron-bridge-test/Megatron-Bridge/src"
    _cur_pp = custom_env_vars.get("PYTHONPATH", "")
    if _mb_src not in _cur_pp:
        custom_env_vars["PYTHONPATH"] = _mb_src + (":" + _cur_pp if _cur_pp else "")'''

if old in content and 'MB_PYTHONPATH' not in content:
    content = content.replace(old, new, 1)
    with open(filepath, "w") as f:
        f.write(content)
    print("  -> MB_PYTHONPATH 패치 완료")
else:
    print("  -> 이미 패치됨 또는 LD_LIBRARY_PATH 패턴 미발견")
PATCH_EOF
else
    echo "  -> setup_experiment.py MB_PYTHONPATH 이미 패치됨"
fi

# executors.py 패치 복원 (이전 실행에서 잘못 적용된 경우)
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

# 이전 실행의 stale experiment 정리
rm -rf "$RESULTS_DIR/experiments/" 2>/dev/null
rm -rf "$WORK_DIR/Megatron-Bridge"/temp_extract_* 2>/dev/null

FSDP_FLAG=""
[ "${FSDP:-0}" -gt 0 ] && FSDP_FLAG="--use_megatron_fsdp true"
VP_FLAG=""
[ -n "${VP// /}" ] && VP_FLAG="-vp $VP"
EP_FLAG=""
[ -n "${EP// /}" ] && EP_FLAG="-ep $EP"
TASK_FLAG=""
DOMAIN_FLAG=""
[ "$MODEL_NAME" = "qwen_vl" ] && { TASK_FLAG="--task pretrain"; DOMAIN_FLAG="--domain vlm"; }

echo "[DEBUG] preset: TP=$TP PP=$PP CP=$CP VP='${VP:-}' EP='${EP:-}' MBS=$MBS GBS=$GBS FSDP=${FSDP:-0}"

# ----- Dry Run -----
echo ""
echo "--- Multi-Node: ${NUM_GPUS} GPU (${NUM_NODES}노드 x 8), ${GPU_TYPE}, ${FP8_PRECISION} ---"
echo "  Container Mounts: $CUSTOM_MOUNTS"
echo ""

python scripts/performance/setup_experiment.py \
  -a "$SLURM_ACCOUNT" \
  -p "$SLURM_PARTITION" \
  -i "$SQSH_FILE" \
  -m $MODEL_NAME -mr ${PRESET_PREFIX}_${MODEL_SIZE} \
  -ng $NUM_GPUS -gn $GPUS_PER_NODE \
  -g $GPU_TYPE -c $FP8_PRECISION \
  -tp $TP -pp $PP -cp $CP ${VP_FLAG} ${EP_FLAG} \
  -mb $MBS -gb $GBS \
  ${FSDP_FLAG} \
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
  -m $MODEL_NAME -mr ${PRESET_PREFIX}_${MODEL_SIZE} \
  -ng $NUM_GPUS -gn $GPUS_PER_NODE \
  -g $GPU_TYPE -c $FP8_PRECISION \
  -tp $TP -pp $PP -cp $CP ${VP_FLAG} ${EP_FLAG} \
  -mb $MBS -gb $GBS \
  ${FSDP_FLAG} \
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
echo "   - NCCL_PROTO, NCCL_ALGO 설정 금지 (aws-ofi-nccl 자동 튜닝 사용)"
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
        echo "  -> 심볼릭 링크: $RESULTS_DIR/latest.log"
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
