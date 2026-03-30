#!/bin/bash

# Simple launcher for FSDP2 training (single node)
# Usage: ./train-fsdp2-singlenode.sh [options] [node_name]
#
# Options:
#   --preset PRESET           Model preset (default: qwen3-0.6b)
#   --max_steps N             Max training steps (default: 1000)
#   --validation_freq N       Validation frequency (default: 500)
#   --checkpoint_freq N       Checkpoint frequency (default: 500)
#   --dataset PATH            Dataset path (default: /fsx/data/pretrain/wikitext-2)
#   --no_local_dataset        Use HuggingFace dataset instead of local
#
# Examples:
#   ./train-fsdp2-singlenode.sh
#   ./train-fsdp2-singlenode.sh --preset llama-3.1-8b
#   ./train-fsdp2-singlenode.sh --preset llama-3.1-8b --max_steps 5000 node-1

set -e

# CUDA version selection
CUDA_VERSION=${CUDA_VERSION:-"12.9"}  # Default to 12.9
if [ -d "/usr/local/cuda-${CUDA_VERSION}" ]; then
    export CUDA_HOME="/usr/local/cuda-${CUDA_VERSION}"
    export PATH="$CUDA_HOME/bin:$PATH"
    export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$LD_LIBRARY_PATH"
    echo "Using CUDA version: $CUDA_VERSION"
fi

###########################
# Defaults
###########################
PRESET="qwen3-0.6b"
DATASET="/fsx/data/pretrain/wikitext-2"
LOCAL_DATASET=true
MAX_STEPS=1000
EPOCHS=1
LOGGING_FREQ=10
VALIDATION_FREQ=500
VALIDATION_BATCHES=5
CHECKPOINT_FREQ=500
CHECKPOINT_DIR="checkpoints"
TRAIN_BATCH_SIZE=1
VAL_BATCH_SIZE=1
NODE_NAME=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --preset)           PRESET="$2";           shift 2 ;;
        --dataset)          DATASET="$2";           shift 2 ;;
        --no_local_dataset) LOCAL_DATASET=false;    shift ;;
        --max_steps)        MAX_STEPS="$2";         shift 2 ;;
        --epochs)           EPOCHS="$2";            shift 2 ;;
        --logging_freq)     LOGGING_FREQ="$2";      shift 2 ;;
        --validation_freq)  VALIDATION_FREQ="$2";   shift 2 ;;
        --checkpoint_freq)  CHECKPOINT_FREQ="$2";   shift 2 ;;
        --checkpoint_dir)   CHECKPOINT_DIR="$2";    shift 2 ;;
        --train_batch_size) TRAIN_BATCH_SIZE="$2";  shift 2 ;;
        --val_batch_size)   VAL_BATCH_SIZE="$2";    shift 2 ;;
        *)                  NODE_NAME="$1";         shift ;;
    esac
done

# Change to the parent directory where .venv is located
cd ..

# UV Environment Setup
if [ -f "$(pwd)/.venv/pyvenv.cfg" ]; then
    echo "Activating uv virtual environment..."
    source $(pwd)/.venv/bin/activate
    echo "Virtual environment activated: $VIRTUAL_ENV"
elif [ -f "$(pwd)/pyproject.toml" ]; then
    echo "Using uv run for project..."
    export UV_RUN=1
else
    echo "⚠️  UV environment not found! Please run 'uv sync' first."
    echo "Current working directory: $(pwd)"
fi

# Change back to fsdp directory for training
cd fsdp2

# Create necessary directories
mkdir -p logs
mkdir -p checkpoints

# Node selection
if [ -n "$NODE_NAME" ]; then
    echo "Running on specified node: $NODE_NAME"
    RUN_CMD="srun -w $NODE_NAME"
else
    echo "Available nodes:"
    sinfo -N -h --format="%N %T" | grep idle | head -5 2>/dev/null || echo "No SLURM available"
    echo "Running locally..."
    RUN_CMD=""
fi

# Environment Variables for FSDP2
export FI_PROVIDER=efa
export FI_EFA_USE_HUGE_PAGE=0
export FI_EFA_SET_CUDA_SYNC_MEMOPS=0
export LD_PRELOAD=/usr/local/cuda-${CUDA_VERSION}/lib/libnccl.so
export NCCL_SOCKET_IFNAME=^docker,lo,veth,eth
export TORCH_NCCL_BLOCKING_WAIT=1
export HF_HUB_ETAG_TIMEOUT=60

# UV execution setup
if [ "$UV_RUN" = "1" ]; then
    TORCHRUN="uv run torchrun"
else
    TORCHRUN="torchrun"
fi

# Launch training with torchrun
$RUN_CMD $TORCHRUN --nproc_per_node=8 src/train_fsdp2.py \
    --preset $PRESET \
    --dataset $DATASET \
    $([ "$LOCAL_DATASET" = true ] && echo "--local_dataset") \
    --max_steps $MAX_STEPS \
    --epochs $EPOCHS \
    --logging_freq $LOGGING_FREQ \
    --validation_freq $VALIDATION_FREQ \
    --validation_batches $VALIDATION_BATCHES \
    --checkpoint_freq $CHECKPOINT_FREQ \
    --checkpoint_dir $CHECKPOINT_DIR \
    --train_batch_size $TRAIN_BATCH_SIZE \
    --val_batch_size $VAL_BATCH_SIZE \
    --resume_from_checkpoint $CHECKPOINT_DIR

echo "FSDP2 Training completed!"
