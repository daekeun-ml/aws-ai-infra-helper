#!/bin/bash

# Simple launcher for DeepSpeed training (single node)
# Usage: ./launch_deepspeed.sh [node_name]

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

# Change back to deepspeed directory for training
cd deepspeed

# Check if DeepSpeed config exists
if [ ! -f "ds_config.json" ]; then
    echo "Error: ds_config.json not found!"
    exit 1
fi

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
    sinfo -N -h --format="%N %T" | grep idle | head -5
    echo ""
    echo "Usage: $0 [node_name]"
    echo "Running locally..."
    RUN_CMD=""
fi

###########################
# Training Configuration
###########################
MODEL_TYPE="qwen3_0_6b"
TOKENIZER="Qwen/Qwen3-0.6B"

DATASET="allenai/c4"
DATASET_CONFIG_NAME="en"  # Used for HuggingFace datasets (e.g., allenai/c4 -> en)
LOCAL_DATASET=false  # Set to false for HuggingFace datasets

# DATASET="/fsx/data/wikitext-2"
# LOCAL_DATASET=true

MAX_STEPS=100
EPOCHS=1
LOGGING_FREQ=10
VALIDATION_FREQ=50
VALIDATION_BATCHES=5
CHECKPOINT_FREQ=50
CHECKPOINT_DIR="checkpoints"

# Model configuration
VOCAB_SIZE=151936
HIDDEN_SIZE=1024
INTERMEDIATE_SIZE=3072
NUM_HIDDEN_LAYERS=28
NUM_ATTENTION_HEADS=16
NUM_KEY_VALUE_HEADS=8
MAX_POSITION_EMBEDDINGS=40960
RMS_NORM_EPS=1e-6
ROPE_THETA=1000000

DEEPSPEED_CONFIG="ds_config.json"

# UV execution setup
if [ "$UV_RUN" = "1" ]; then
    TORCHRUN="uv run torchrun"
else
    TORCHRUN="torchrun"
fi

# Launch training with torchrun
$RUN_CMD $TORCHRUN --nproc_per_node=8 src/train_deepspeed.py \
    --model_type $MODEL_TYPE \
    --tokenizer $TOKENIZER \
    --dataset $DATASET \
    --dataset_config_name $DATASET_CONFIG_NAME \
    $([ "$LOCAL_DATASET" = true ] && echo "--local_dataset") \
    --max_steps $MAX_STEPS \
    --epochs $EPOCHS \
    --logging_freq $LOGGING_FREQ \
    --validation_freq $VALIDATION_FREQ \
    --validation_batches $VALIDATION_BATCHES \
    --checkpoint_freq $CHECKPOINT_FREQ \
    --checkpoint_dir $CHECKPOINT_DIR \
    --vocab_size $VOCAB_SIZE \
    --hidden_size $HIDDEN_SIZE \
    --intermediate_size $INTERMEDIATE_SIZE \
    --num_hidden_layers $NUM_HIDDEN_LAYERS \
    --num_attention_heads $NUM_ATTENTION_HEADS \
    --num_key_value_heads $NUM_KEY_VALUE_HEADS \
    --max_position_embeddings $MAX_POSITION_EMBEDDINGS \
    --rms_norm_eps $RMS_NORM_EPS \
    --rope_theta $ROPE_THETA \
    --deepspeed_config $DEEPSPEED_CONFIG

echo "Training completed!"
