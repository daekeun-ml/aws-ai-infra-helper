#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

#SBATCH --nodes=2 # number of nodes to use
#SBATCH --job-name=qwen3_0_6b-DeepSpeed # name of your job
#SBATCH --output=logs/%x_%j.out # logfile for stdout
#SBATCH --error=logs/%x_%j.err # logfile for stderr, remove it to merge both outputs
#SBATCH --exclusive # job has exclusive use of the resource, no sharing

set -ex;

# Or set CUDA version via environment variable
CUDA_VERSION=${CUDA_VERSION:-"12.8"}  # Default to 12.8
if [ -d "/usr/local/cuda-${CUDA_VERSION}" ]; then
    export CUDA_HOME="/usr/local/cuda-${CUDA_VERSION}"
    export PATH="$CUDA_HOME/bin:$PATH"
    export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$LD_LIBRARY_PATH"
    echo "Using CUDA version: $CUDA_VERSION"
fi

# Change to the parent directory where pyproject.toml is located
cd ..

# For Checkpoint: ensuring synchronization across all nodes
export TORCH_NCCL_BLOCKING_WAIT=1

GPUS_PER_NODE=8 # 4 for G5.12x, 8 for P4/P5

###########################
# UV Environment Setup
###########################
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

# Environment Check
echo "=== Environment Check ==="
if [ "$UV_RUN" = "1" ]; then
    echo "Python: $(uv run which python)"
    echo "PyTorch version: $(uv run python -c 'import torch; print(torch.__version__)' 2>/dev/null || echo 'PyTorch not found')"
    echo "CUDA available: $(uv run python -c 'import torch; print(torch.cuda.is_available())' 2>/dev/null || echo 'Cannot check CUDA')"
    echo "DeepSpeed version: $(uv run python -c 'import deepspeed; print(deepspeed.__version__)' 2>/dev/null || echo 'DeepSpeed not found')"
else
    echo "Python: $(which python)"
    echo "PyTorch version: $(python -c 'import torch; print(torch.__version__)' 2>/dev/null || echo 'PyTorch not found')"
    echo "CUDA available: $(python -c 'import torch; print(torch.cuda.is_available())' 2>/dev/null || echo 'Cannot check CUDA')"
    echo "DeepSpeed version: $(python -c 'import deepspeed; print(deepspeed.__version__)' 2>/dev/null || echo 'DeepSpeed not found')"
fi

echo "Number of nodes: $SLURM_JOB_NUM_NODES"
echo "Job ID: $SLURM_JOB_ID"
echo "Master node: $(hostname)"
echo "=========================="

###########################
# Model and Training Configuration
###########################
MODEL_TYPE="qwen3_0_6b"
TOKENIZER="Qwen/Qwen3-0.6B"

DATASET="allenai/c4"
DATASET_CONFIG_NAME="en"  # Used for HuggingFace datasets (e.g., allenai/c4 -> en)
LOCAL_DATASET=false  # Set to false for HuggingFace datasets

# DATASET="/fsx/data/wikitext-2"
# LOCAL_DATASET=true

CHECKPOINT_DIR="checkpoints"
DEEPSPEED_CONFIG="ds_config.json"

# Training hyperparameters (configured in ds_config.json)
# DeepSpeed automatically calculates train_batch_size from:
# train_micro_batch_size_per_gpu * gradient_accumulation_steps * world_size

LEARNING_RATE=5e-5
MAX_STEPS=200
EPOCHS=1
LOGGING_FREQ=5
VALIDATION_FREQ=100
VALIDATION_BATCHES=5
CHECKPOINT_FREQ=100

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

# Optimization settings
BETA1=0.9
BETA2=0.95
WEIGHT_DECAY=0.1
GRAD_CLIP=1.0
WARMUP_STEPS=100

# Mixed precision
BF16=1

###########################
# Distributed Training Setup
###########################
declare -a TORCHRUN_ARGS=(
    --nproc_per_node=$GPUS_PER_NODE
    --nnodes=$SLURM_JOB_NUM_NODES
    --rdzv_id=$SLURM_JOB_ID
    --rdzv_backend=c10d
    --rdzv_endpoint=$(hostname)
)

echo "TORCHRUN_ARGS: ${TORCHRUN_ARGS[@]}"
echo "SLURM_JOB_NUM_NODES: $SLURM_JOB_NUM_NODES"
echo "SLURM_JOB_ID: $SLURM_JOB_ID"

###########################
# Create necessary directories
###########################
mkdir -p logs
mkdir -p $CHECKPOINT_DIR

###########################
# Launch Training
###########################
if [ "$UV_RUN" = "1" ]; then
    TORCHRUN="uv run torchrun"
else
    TORCHRUN="torchrun"
fi

AUTO_RESUME=""
if [ -d "/opt/sagemaker_cluster" ]; then
    echo "Detected Hyperpod cluster.. enabling --auto-resume=1"
    AUTO_RESUME="--auto-resume=1"
fi

echo "Executing command:"
echo "srun ${AUTO_RESUME} -l ${TORCHRUN} ${TORCHRUN_ARGS[@]} src/train_deepspeed.py --model_type $MODEL_TYPE --tokenizer $TOKENIZER --dataset $DATASET $([ "$LOCAL_DATASET" = true ] && echo "--local_dataset")"
echo ""

srun ${AUTO_RESUME} -l ${TORCHRUN} "${TORCHRUN_ARGS[@]}" src/train_deepspeed.py \
    --model_type $MODEL_TYPE \
    --tokenizer $TOKENIZER \
    --dataset $DATASET \
    $([ "$LOCAL_DATASET" = true ] && echo "--local_dataset") \
    --learning_rate $LEARNING_RATE \
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
    --beta1 $BETA1 \
    --beta2 $BETA2 \
    --weight_decay $WEIGHT_DECAY \
    --grad_clip $GRAD_CLIP \
    --warmup_steps $WARMUP_STEPS \
    --bf16 $BF16 \
    --deepspeed_config $DEEPSPEED_CONFIG

echo "Training completed!"
