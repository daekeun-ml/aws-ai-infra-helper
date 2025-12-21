#!/bin/bash

# Simple launcher for FSDP2 training (single node)
# Usage: ./train-fsdp2-singlenode.sh [node_name]

set -e

# CUDA version selection
CUDA_VERSION=${CUDA_VERSION:-"12.8"}  # Default to 12.8
if [ -d "/usr/local/cuda-${CUDA_VERSION}" ]; then
    export CUDA_HOME="/usr/local/cuda-${CUDA_VERSION}"
    export PATH="$CUDA_HOME/bin:$PATH"
    export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$LD_LIBRARY_PATH"
    echo "Using CUDA version: $CUDA_VERSION"
fi

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
if [ $# -eq 1 ]; then
    NODE_NAME=$1
    echo "Running on specified node: $NODE_NAME"
    RUN_CMD="srun -w $NODE_NAME"
else
    echo "Available nodes:"
    sinfo -N -h --format="%N %T" | grep idle | head -5 2>/dev/null || echo "No SLURM available"
    echo ""
    echo "Usage: $0 [node_name]"
    echo "Running locally..."
    RUN_CMD=""
fi

###########################
# Training Configuration
###########################
MODEL_TYPE="qwen3_0_6b-debug"
TOKENIZER="Qwen/Qwen3-0.6B"

DATASET="/fsx/data/pretrain/wikitext-2"
LOCAL_DATASET=true  # Set to false for HuggingFace datasets

# DATASET="allenai/c4"
# DATASET_CONFIG_NAME="en"
# LOCAL_DATASET=false

MAX_STEPS=100
EPOCHS=1
LOGGING_FREQ=10
VALIDATION_FREQ=50
VALIDATION_BATCHES=5
CHECKPOINT_FREQ=50
CHECKPOINT_DIR="checkpoints"

# Model configuration (from Qwen3-0.6B config.json)
MAX_CONTEXT_WIDTH=8192
NUM_KEY_VALUE_HEADS=8
INTERMEDIATE_SIZE=3072
HIDDEN_WIDTH=1024
NUM_LAYERS=28
NUM_HEADS=16

# FSDP2 specific settings
TRAIN_BATCH_SIZE=1
VAL_BATCH_SIZE=1

# Environment Variables for FSDP2
export FI_PROVIDER=efa
export FI_EFA_USE_HUGE_PAGE=0
export FI_EFA_SET_CUDA_SYNC_MEMOPS=0
export LD_PRELOAD=/usr/local/cuda-${CUDA_VERSION}/lib/libnccl.so
export NCCL_SOCKET_IFNAME=^docker,lo,veth,eth
export TORCH_NCCL_BLOCKING_WAIT=1

# UV execution setup
if [ "$UV_RUN" = "1" ]; then
    TORCHRUN="uv run torchrun"
else
    TORCHRUN="torchrun"
fi

# Launch training with torchrun
$RUN_CMD $TORCHRUN --nproc_per_node=8 src/train_fsdp2.py \
    --model_type $MODEL_TYPE \
    --tokenizer $TOKENIZER \
    --dataset $DATASET \
    $([ "$LOCAL_DATASET" = true ] && echo "--local_dataset") \
    $([ "$LOCAL_DATASET" = false ] && echo "--dataset_config_name $DATASET_CONFIG_NAME") \
    --max_steps $MAX_STEPS \
    --epochs $EPOCHS \
    --logging_freq $LOGGING_FREQ \
    --validation_freq $VALIDATION_FREQ \
    --validation_batches $VALIDATION_BATCHES \
    --checkpoint_freq $CHECKPOINT_FREQ \
    --checkpoint_dir $CHECKPOINT_DIR \
    --max_context_width $MAX_CONTEXT_WIDTH \
    --num_key_value_heads $NUM_KEY_VALUE_HEADS \
    --intermediate_size $INTERMEDIATE_SIZE \
    --hidden_width $HIDDEN_WIDTH \
    --num_layers $NUM_LAYERS \
    --num_heads $NUM_HEADS \
    --train_batch_size $TRAIN_BATCH_SIZE \
    --val_batch_size $VAL_BATCH_SIZE \
    --resume_from_checkpoint $CHECKPOINT_DIR

echo "FSDP2 Training completed!"
