#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

#SBATCH --nodes=2 # number of nodes to use
#SBATCH --job-name=qwen3_0_6b-fsdp2-pyxis # name of your job
#SBATCH --output=logs/%x_%j.out # logfile for stdout
#SBATCH --error=logs/%x_%j.err # logfile for stderr, remove it to merge both outputs
#SBATCH --exclusive # job has exclusive use of the resource, no sharing

set -ex;

# CUDA configuration
export TORCH_CUDA_ARCH_LIST="8.0;8.6;8.9;9.0;10.0;10.3"  # P4/A100, A10G, L4/L40S, P5/H100, P6/B200, GB300/B300
CUDA_VERSION=${CUDA_VERSION:-"12.8"}
if [ -d "/usr/local/cuda-${CUDA_VERSION}" ]; then
    export CUDA_HOME="/usr/local/cuda-${CUDA_VERSION}"
    export PATH="$CUDA_HOME/bin:$PATH"
    export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$LD_LIBRARY_PATH"
    echo "Using CUDA version: $CUDA_VERSION"
fi

# Container configuration
export CONTAINER_IMAGE="/fsx/ubuntu/aws-ai-infra-helper/fsdp2/fsdp2-training.sqsh"
export CONTAINER_MOUNTS="/fsx:/fsx"

# For Checkpoint: ensuring synchronization across all nodes
export TORCH_NCCL_BLOCKING_WAIT=1
# export NCCL_DEBUG=INFO
# export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

# NCCL network configuration for multi-node
export NCCL_SOCKET_IFNAME=^docker0,lo
export NCCL_IB_DISABLE=1

GPUS_PER_NODE=8 # 4 for G5.12x, 8 for P4/P5

# Environment Check
echo "=== Environment Check ==="
echo "Python: $(python --version)"
echo "CUDA available: $(python -c 'import torch; print(torch.cuda.is_available())' 2>/dev/null || echo 'Cannot check CUDA')"
echo "Number of nodes: $SLURM_JOB_NUM_NODES"
echo "Job ID: $SLURM_JOB_ID"
echo "Master node: $(hostname)"
echo "=========================="

###########################
# Model and Training Configuration
###########################
MODEL_TYPE="qwen3_0_6b"
TOKENIZER="Qwen/Qwen3-0.6B"

DATASET="/fsx/data/pretrain/wikitext-2"
LOCAL_DATASET=true  # Set to false for HuggingFace datasets

# DATASET="allenai/c4"
# DATASET_CONFIG_NAME="en"
# LOCAL_DATASET=false

MAX_STEPS=100
EPOCHS=1
LOGGING_FREQ=10
VALIDATION_FREQ=100
VALIDATION_BATCHES=5
CHECKPOINT_FREQ=50
CHECKPOINT_DIR="checkpoints"

# Model configuration
MAX_CONTEXT_WIDTH=8192
NUM_KEY_VALUE_HEADS=8
INTERMEDIATE_SIZE=3072
HIDDEN_WIDTH=1024
NUM_LAYERS=28
NUM_HEADS=16

# Batch sizes
TRAIN_BATCH_SIZE=1
VAL_BATCH_SIZE=1

###########################
# Distributed Training Setup
###########################
declare -a TORCHRUN_ARGS=(
    --nproc_per_node=$GPUS_PER_NODE
    --nnodes=$SLURM_JOB_NUM_NODES
    --rdzv_id=$SLURM_JOB_ID
    --rdzv_backend=c10d
    --rdzv_endpoint=$(scontrol show hostnames $SLURM_JOB_NODELIST | head -n 1):29500
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
AUTO_RESUME=""
if [ -d "/opt/sagemaker_cluster" ]; then
    echo "Detected Hyperpod cluster.. enabling --auto-resume=1"
    AUTO_RESUME="--auto-resume=1"
fi

echo "Executing command:"
echo "srun ${AUTO_RESUME} -l --container-image=$CONTAINER_IMAGE --container-mounts=$CONTAINER_MOUNTS torchrun ${TORCHRUN_ARGS[@]} /workspace/src/train_fsdp2.py --model_type $MODEL_TYPE --tokenizer $TOKENIZER --dataset $DATASET $([ "$LOCAL_DATASET" = true ] && echo "--local_dataset")"
echo ""

srun ${AUTO_RESUME} -l \
     --container-image=$CONTAINER_IMAGE \
     --container-mounts=$CONTAINER_MOUNTS \
     torchrun "${TORCHRUN_ARGS[@]}" /workspace/src/train_fsdp2.py \
    --model_type=$MODEL_TYPE \
    --tokenizer=$TOKENIZER \
    --dataset=$DATASET \
    $([ "$LOCAL_DATASET" = true ] && echo "--local_dataset") \
    $([ "$LOCAL_DATASET" = false ] && echo "--dataset_config_name $DATASET_CONFIG_NAME") \
    --max_steps=$MAX_STEPS \
    --epochs=$EPOCHS \
    --logging_freq=$LOGGING_FREQ \
    --validation_freq=$VALIDATION_FREQ \
    --validation_batches=$VALIDATION_BATCHES \
    --checkpoint_freq=$CHECKPOINT_FREQ \
    --checkpoint_dir=$CHECKPOINT_DIR \
    --max_context_width=$MAX_CONTEXT_WIDTH \
    --num_key_value_heads=$NUM_KEY_VALUE_HEADS \
    --intermediate_size=$INTERMEDIATE_SIZE \
    --hidden_width=$HIDDEN_WIDTH \
    --num_layers=$NUM_LAYERS \
    --num_heads=$NUM_HEADS \
    --train_batch_size=$TRAIN_BATCH_SIZE \
    --val_batch_size=$VAL_BATCH_SIZE \
    --resume_from_checkpoint=$CHECKPOINT_DIR

echo "Training completed!"
