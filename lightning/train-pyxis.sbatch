#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

#SBATCH --nodes=2 # number of nodes to use
#SBATCH --job-name=qwen3-lightning-pyxis # name of your job
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
export CONTAINER_IMAGE="/fsx/ubuntu/aws-ai-infra-helper/lightning/lightning-training.sqsh"
export CONTAINER_MOUNTS="/fsx:/fsx"

# For Checkpoint: ensuring synchronization across all nodes
export TORCH_NCCL_BLOCKING_WAIT=1
export NCCL_DEBUG=INFO
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

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
MODEL_NAME="Qwen/Qwen3-0.6B"

DATASET="/fsx/data/pretrain/wikitext-2"
LOCAL_DATASET=true  # Set to false for HuggingFace datasets

# DATASET="allenai/c4"
# DATASET_CONFIG="en"
# LOCAL_DATASET=false

MAX_STEPS=500
BATCH_SIZE=2
MAX_LENGTH=4096
LEARNING_RATE=5e-5
SAVE_EVERY_N_STEPS=100
VAL_CHECK_INTERVAL=100
CHECKPOINT_DIR="checkpoints"

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
echo "srun ${AUTO_RESUME} -l --container-image=$CONTAINER_IMAGE --container-mounts=$CONTAINER_MOUNTS python /workspace/train.py --nodes=$SLURM_NNODES --gpus=$GPUS_PER_NODE --dataset $DATASET $([ "$LOCAL_DATASET" = true ] && echo "--local_dataset")"
echo ""

srun ${AUTO_RESUME} -l \
     --container-image=$CONTAINER_IMAGE \
     --container-mounts=$CONTAINER_MOUNTS \
     python /workspace/train.py \
    --nodes=$SLURM_NNODES \
    --gpus=$GPUS_PER_NODE \
    --max_steps=$MAX_STEPS \
    --batch_size=$BATCH_SIZE \
    --dataset="$DATASET" \
    --dataset_config="$DATASET_CONFIG" \
    $([ "$LOCAL_DATASET" = true ] && echo "--local_dataset") \
    --model_name="$MODEL_NAME" \
    --max_length=$MAX_LENGTH \
    --learning_rate=$LEARNING_RATE \
    --save_every_n_steps=$SAVE_EVERY_N_STEPS \
    --val_check_interval=$VAL_CHECK_INTERVAL \
    --checkpoint_dir="$CHECKPOINT_DIR"

echo "Training completed!"
