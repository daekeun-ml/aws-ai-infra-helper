#!/bin/bash

set -ex

# Create logs directory
mkdir -p logs

# CUDA Version Setup
CUDA_VERSION=${CUDA_VERSION:-"13.0"}
if [ -d "/usr/local/cuda-${CUDA_VERSION}" ]; then
    export CUDA_HOME="/usr/local/cuda-${CUDA_VERSION}"
    export PATH="$CUDA_HOME/bin:$PATH"
    export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$LD_LIBRARY_PATH"
    echo "Using CUDA version: $CUDA_VERSION"
fi

# Environment Variables
export PYTHONFAULTHANDLER=1
export GPUS_PER_NODE=${GPUS_PER_NODE:-8} # 4 for G5.12x, 8 for P4/P5

# HuggingFace timeout
export HF_HUB_ETAG_TIMEOUT=60

# Activate virtual environment
source ../.venv/bin/activate

###########################
##### Training Config #####
###########################

# Default values (overridden by PRESET if set)
MODEL_NAME="Qwen/Qwen3-0.6B"
DATASET="/fsx/data/pretrain/wikitext-2"
DATASET_CONFIG=""
LOCAL_DATASET=true
PRECISION="bf16-mixed"
MAX_STEPS=500
BATCH_SIZE=2
GRADIENT_ACCUMULATION_STEPS=1
MAX_LENGTH=4096
LEARNING_RATE=5e-5
SAVE_EVERY_N_STEPS=100
VAL_CHECK_INTERVAL=100
CHECKPOINT_DIR="./checkpoints_fabric"

# Load preset if PRESET is set (e.g. PRESET=presets/llama3.1-8b-bench.json)
# Available presets: $(ls presets/*.json 2>/dev/null | xargs -I{} basename {})
PRESET=${PRESET:-""}
if [ -n "$PRESET" ] && [ -f "$PRESET" ]; then
    echo "Loading preset: $PRESET"
    _VARS=$(python3 - "$PRESET" <<'PYEOF'
import json, sys
mapping = {
    "model_name":                  "MODEL_NAME",
    "dataset":                     "DATASET",
    "dataset_config":              "DATASET_CONFIG",
    "local_dataset":               "LOCAL_DATASET",
    "precision":                   "PRECISION",
    "batch_size":                  "BATCH_SIZE",
    "gradient_accumulation_steps": "GRADIENT_ACCUMULATION_STEPS",
    "max_length":                  "MAX_LENGTH",
    "learning_rate":               "LEARNING_RATE",
    "max_steps":                   "MAX_STEPS",
    "save_every_n_steps":          "SAVE_EVERY_N_STEPS",
    "val_check_interval":          "VAL_CHECK_INTERVAL",
    "checkpoint_dir":              "CHECKPOINT_DIR",
}
d = json.load(open(sys.argv[1]))
for jk, bv in mapping.items():
    if jk in d:
        v = d[jk]
        if isinstance(v, bool):
            print(f'{bv}={"true" if v else "false"}')
        else:
            print(f'{bv}="{v}"')
PYEOF
)
    eval "$_VARS"
elif [ -n "$PRESET" ]; then
    echo "ERROR: preset file not found: $PRESET" >&2
    exit 1
fi

# Uncomment to override individual values after preset load:
# MODEL_NAME="meta-llama/Llama-3.1-8B"
# DATASET="allenai/c4"; DATASET_CONFIG="en"; LOCAL_DATASET=false

# Environment Check
echo "=== Environment Check ==="
echo "Python: $(which python)"
echo "PyTorch version: $(python -c 'import torch; print(torch.__version__)' 2>/dev/null || echo 'PyTorch not found')"
echo "CUDA available: $(python -c 'import torch; print(torch.cuda.is_available())' 2>/dev/null || echo 'Cannot check CUDA')"
echo "GPUs per node: $GPUS_PER_NODE"
echo "Host: $(hostname)"
echo "=========================="

# Training arguments
declare -a TRAINING_ARGS=(
    --nodes=1
    --gpus=$GPUS_PER_NODE
    --precision="$PRECISION"
    --max_steps=$MAX_STEPS
    --batch_size=$BATCH_SIZE
    --gradient_accumulation_steps=$GRADIENT_ACCUMULATION_STEPS
    --dataset="$DATASET"
    --dataset_config="$DATASET_CONFIG"
    $([ "$LOCAL_DATASET" = true ] && echo "--local_dataset")
    --model_name="$MODEL_NAME"
    --max_length=$MAX_LENGTH
    --learning_rate=$LEARNING_RATE
    --save_every_n_steps=$SAVE_EVERY_N_STEPS
    --val_check_interval=$VAL_CHECK_INTERVAL
    --checkpoint_dir="$CHECKPOINT_DIR"
)

echo "Executing command:"
echo "python train_fabric.py ${TRAINING_ARGS[@]}"
echo ""

python train_fabric.py "${TRAINING_ARGS[@]}"
