#!/bin/bash
# =============================================================================
# [Step 3] NeMo 멀티모델 기본 벤치마크 (DGX Reference Config)
#
# 지원 모델:
#   - Qwen3 30B A3B     (MoE, fp8_cs/fp8_mx)
#   - Llama3 8B         (Dense, fp8_cs/fp8_mx/bf16)
#   - GPT-OSS 120B      (MoE, bf16 only)
#   - Qwen3-VL 30B A3B  (VLM Pretrain, bf16/fp8_cs/fp8_mx)
#
# 사전 조건: 01_prepare_environment.sh 실행 완료 (sqsh, 레포, venv 준비됨)
#
# HyperPod 헤드노드에서 실행.
# run_script.py V5 패치 + VP=None 패치 (v0.3.1 구조 반영)
# -> setup_experiment.py SQSH_ENV_RESTORE 패치 (nccl_ub 블록 뒤 삽입)
# -> Slurm 잡 제출 -> 자동 모니터링
# =============================================================================

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

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

# 노드 수 수동 선택
GPUS_PER_NODE=8
AVAILABLE_NODES=$(sinfo -p "$SLURM_PARTITION" -h -o "%D" 2>/dev/null | awk '{s+=$1} END{print s+0}')
echo "노드 수를 입력하세요 (파티션 '$SLURM_PARTITION' 가용 노드: ${AVAILABLE_NODES:-?}개):"
read -p "노드 수: " NUM_NODES
if ! [[ "$NUM_NODES" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: 올바른 노드 수를 입력하세요 (1 이상의 정수)."
    exit 1
fi
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
echo " NeMo 기본 벤치마크: $MODEL_NAME $MODEL_SIZE"
echo "============================================================"
echo " Slurm Account:  $SLURM_ACCOUNT"
echo " Slurm Partition: $SLURM_PARTITION"
echo " GPU:             $NUM_GPUS x $GPU_TYPE (컴퓨트 노드에서 실행)"
echo " Precision:       $FP8_PRECISION"
echo " Work Dir:        $WORK_DIR (FSx Lustre)"
echo "============================================================"
echo ""

# ----- 사전 조건 확인 (01_prepare_environment.sh) -----
if [ -z "$HF_TOKEN" ]; then
    echo "ERROR: HF_TOKEN이 설정되지 않았습니다. env.sh에서 HF_TOKEN을 입력하세요."
    exit 1
fi
if [ ! -f "$SQSH_FILE" ]; then
    echo "ERROR: sqsh 파일이 없습니다: $SQSH_FILE"
    echo "먼저 01_prepare_environment.sh를 실행하세요."
    exit 1
fi
if [ ! -d "$WORK_DIR/Megatron-Bridge" ]; then
    echo "ERROR: 레포가 없습니다: $WORK_DIR/Megatron-Bridge"
    echo "먼저 01_prepare_environment.sh를 실행하세요."
    exit 1
fi
if [ ! -f "$WORK_DIR/venv/bin/activate" ]; then
    echo "ERROR: venv가 없습니다: $WORK_DIR/venv"
    echo "먼저 01_prepare_environment.sh를 실행하세요."
    exit 1
fi

CONTAINER_IMAGE="$SQSH_FILE"
echo "[준비] sqsh: $SQSH_FILE ($(ls -lh "$SQSH_FILE" | awk '{print $5}'))"
cd "$WORK_DIR/Megatron-Bridge"
source "$WORK_DIR/venv/bin/activate"
echo ""

# ----- Step 1: run_script.py에 venv site 패치 (V5) -----
# docker export로 만든 sqsh는 Docker ENV를 모두 잃음.
# V5 패치는 다음을 복원:
#   1) PATH, LD_LIBRARY_PATH (venv, CUDA, HPC-X)
#   2) CUDA 환경 (CUDA_HOME, TORCH_CUDA_ARCH_LIST 등)
#   3) NVIDIA 환경 (NVIDIA_VISIBLE_DEVICES 등)
#   4) venv site-packages + .pth editable install 처리
#   5) modelopt 버전 불일치 monkey-patch
RUN_SCRIPT="scripts/performance/run_script.py"
if ! grep -q "VENV_BOOTSTRAP_V5" "$RUN_SCRIPT" 2>/dev/null; then
    echo "  -> run_script.py에 V5 패치 적용 (docker export 전체 ENV 복원)..."

    # 기존 패치가 있으면 원본에서 다시 시작
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

# shebang이 있으면 그 다음에, 없으면 맨 앞에 삽입
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

# ----- Step 2.5b: run_script.py에 VP=None 패치 (PP=1일 때 VP 강제 해제) -----
# base config에서 PP=2, VP=12가 설정된 경우,
# PP=1로 오버라이드하면 VP도 None으로 해제해야 함.
# Megatron은 VP가 None이 아니면 interleaved schedule로 처리 → PP>1 필수.
# v0.3.1: set_post_overrides 이후 / forward_step 선택 이전에 삽입.
if ! grep -q "VP_PP1_FIX" "$RUN_SCRIPT" 2>/dev/null; then
    echo "  -> run_script.py에 VP=None 패치 적용 (PP=1일 때 VP 강제 해제)..."
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
    echo "  -> run_script.py VP=None 패치 이미 적용됨"
fi

# ----- Step 2.5c: run_script.py에 Megatron-Bridge v0.3.1 src 경로 패치 -----
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
_mb_src = '/fsx/megatron-bridge-test-26.02/Megatron-Bridge/src'
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

# ----- Step 2.6: setup_experiment.py에 custom_env_vars 패치 -----
# v0.3.1: custom_env_vars는 인자로 주입됨(기존 `custom_env_vars={},` 패턴 제거).
# nccl_ub 블록 바로 뒤에 setdefault로 CUDA/NVIDIA env 추가.
SETUP_SCRIPT="scripts/performance/setup_experiment.py"
if ! grep -q "SQSH_ENV_RESTORE" "$SETUP_SCRIPT" 2>/dev/null; then
    echo "  -> setup_experiment.py에 SQSH_ENV_RESTORE 패치 적용..."

    python3 << 'PATCH_EOF'
filepath = "scripts/performance/setup_experiment.py"
with open(filepath, "r") as f:
    content = f.read()

old = '    if nccl_ub:\n        custom_env_vars.update({"NCCL_NVLS_ENABLE": "1", "NCCL_CTA_POLICY": "1"})'
new = '''    if nccl_ub:
        custom_env_vars.update({"NCCL_NVLS_ENABLE": "1", "NCCL_CTA_POLICY": "1"})
    # SQSH_ENV_RESTORE: docker export sqsh loses Docker ENV. Restore critical CUDA/NVIDIA env vars.
    custom_env_vars.setdefault("NVIDIA_VISIBLE_DEVICES", "all")
    custom_env_vars.setdefault("NVIDIA_DRIVER_CAPABILITIES", "compute,utility")
    custom_env_vars.setdefault("CUDA_HOME", "/usr/local/cuda")
    custom_env_vars.setdefault("CUDA_PATH", "/usr/local/cuda")
    custom_env_vars.setdefault("LIBRARY_PATH", "/usr/local/cuda/lib64/stubs:/usr/local/cuda/lib64")
    custom_env_vars.setdefault("CPATH", "/usr/local/cuda/include")
    custom_env_vars.setdefault("PATH", "/opt/venv/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
    custom_env_vars.setdefault("TRITON_PTXAS_PATH", "/usr/local/cuda/bin/ptxas")
    # MB_PYTHONPATH: 컨테이너 내 구버전 megatron.bridge를 FSx v0.3.1로 override하기 위해 PYTHONPATH 앞에 삽입
    _mb_src = "/fsx/megatron-bridge-test-26.02/Megatron-Bridge/src"
    _cur_pp = custom_env_vars.get("PYTHONPATH", "")
    if _mb_src not in _cur_pp:
        custom_env_vars["PYTHONPATH"] = _mb_src + (":" + _cur_pp if _cur_pp else "")'''

if old in content:
    content = content.replace(old, new, 1)
    with open(filepath, "w") as f:
        f.write(content)
    print("  -> SQSH_ENV_RESTORE 패치 완료")
else:
    print("  -> nccl_ub 패턴 미발견 (이미 패치됨?)")
PATCH_EOF
else
    echo "  -> setup_experiment.py SQSH_ENV_RESTORE 이미 패치됨"
fi

# executors.py 패치 복원 (이전 실행에서 잘못 적용된 경우)
EXECUTOR_FILE="scripts/performance/utils/executors.py"
if [ -f "${EXECUTOR_FILE}.bak_path" ]; then
    echo "  -> executors.py 이전 PATH 패치 복원..."
    mv "${EXECUTOR_FILE}.bak_path" "$EXECUTOR_FILE"
fi
echo ""

# ----- Step 3: Dry-run -----
echo "[1/3] Dry-run: sbatch 스크립트 확인..."
echo ""

RESULTS_DIR="$WORK_DIR/results/${PRESET_PREFIX}_${MODEL_SIZE}_basic"
mkdir -p "$RESULTS_DIR"
export NEMORUN_HOME="$RESULTS_DIR"
export MB_CUDA_ARCH="$CUDA_ARCH"

# 이전 실행의 stale experiment 정리
rm -rf "$RESULTS_DIR/experiments/" 2>/dev/null
rm -rf "$WORK_DIR/Megatron-Bridge"/temp_extract_* 2>/dev/null

FSDP_FLAG=""
[ "${FSDP:-0}" -gt 0 ] && FSDP_FLAG="--use_megatron_fsdp true"
NO_CUDA_GRAPHS_FLAG=""
[ "${NO_CUDA_GRAPHS:-0}" -gt 0 ] && NO_CUDA_GRAPHS_FLAG="--cuda_graph_impl none"
VP_FLAG=""
[ -n "${VP// /}" ] && VP_FLAG="-vp $VP"
EP_FLAG=""
[ -n "${EP// /}" ] && EP_FLAG="-ep $EP"   # Dense 모델(EP=)은 플래그 생략
TASK_FLAG=""
DOMAIN_FLAG=""
[ "$MODEL_NAME" = "qwen_vl" ] && { TASK_FLAG="--task pretrain"; DOMAIN_FLAG="--domain vlm"; }

echo "[DEBUG] preset: TP=$TP PP=$PP CP=$CP VP='${VP:-}' EP='${EP:-}' MBS=$MBS GBS=$GBS FSDP=${FSDP:-0} NO_CUDA_GRAPHS=${NO_CUDA_GRAPHS:-0}"

python scripts/performance/setup_experiment.py \
  -a "$SLURM_ACCOUNT" \
  -p "$SLURM_PARTITION" \
  -i "$CONTAINER_IMAGE" \
  -m $MODEL_NAME \
  -mr ${PRESET_PREFIX}_${MODEL_SIZE} \
  -ng $NUM_GPUS \
  -gn $GPUS_PER_NODE \
  -g $GPU_TYPE \
  -c $FP8_PRECISION \
  -tp $TP -pp $PP -cp $CP ${VP_FLAG} ${EP_FLAG} \
  -mb $MBS -gb $GBS \
  ${FSDP_FLAG} ${NO_CUDA_GRAPHS_FLAG} \
  ${TASK_FLAG} ${DOMAIN_FLAG} \
  -hf "$HF_TOKEN" \
  -l "$RESULTS_DIR" \
  -t "00:30:00" \
  -ms 20 \
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

# ----- Step 4: 실제 제출 -----
echo "[2/3] 벤치마크 Slurm 잡 제출..."

# dryrun 임시 파일 정리
rm -rf "$WORK_DIR/Megatron-Bridge"/temp_extract_* 2>/dev/null
rm -rf "$RESULTS_DIR/experiments/" 2>/dev/null

python scripts/performance/setup_experiment.py \
  -a "$SLURM_ACCOUNT" \
  -p "$SLURM_PARTITION" \
  -i "$CONTAINER_IMAGE" \
  -m $MODEL_NAME \
  -mr ${PRESET_PREFIX}_${MODEL_SIZE} \
  -ng $NUM_GPUS \
  -gn $GPUS_PER_NODE \
  -g $GPU_TYPE \
  -c $FP8_PRECISION \
  -tp $TP -pp $PP -cp $CP ${VP_FLAG} ${EP_FLAG} \
  -mb $MBS -gb $GBS \
  ${FSDP_FLAG} ${NO_CUDA_GRAPHS_FLAG} \
  ${TASK_FLAG} ${DOMAIN_FLAG} \
  -hf "$HF_TOKEN" \
  -l "$RESULTS_DIR" \
  -t "00:30:00" \
  -ms 20

deactivate

# ----- Step 5: 자동 모니터링 -----
echo ""
echo "[3/3] 로그 모니터링 시작..."
echo ""
echo " Ctrl+C로 모니터링 종료 (잡은 계속 실행됨)"
echo "============================================================"

# 로그 파일이 생길 때까지 대기 후 tail -f
# 실제 경로: experiments/<config>/<experiment_id>/<task>/log-*.out (3단계 하위)
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
