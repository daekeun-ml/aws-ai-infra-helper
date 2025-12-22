#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

#SBATCH --nodes=2                    # number of nodes to use
#SBATCH --job-name=qwen3-fabric      # name of your job
#SBATCH --gres=gpu:8                 # GPUs per node
#SBATCH --time=02:00:00              # time limit
#SBATCH --output=logs/%x_%j.out      # logfile for stdout
#SBATCH --error=logs/%x_%j.err       # logfile for stderr
#SBATCH --exclusive                  # job has exclusive use of the resource
#SBATCH --signal=SIGUSR1@90          # auto-resubmit 90 seconds before wall time

set -ex

# Create logs directory
mkdir -p logs

# CUDA Version Setup
CUDA_VERSION=${CUDA_VERSION:-"12.8"}
if [ -d "/usr/local/cuda-${CUDA_VERSION}" ]; then
    export CUDA_HOME="/usr/local/cuda-${CUDA_VERSION}"
    export PATH="$CUDA_HOME/bin:$PATH"
    export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$LD_LIBRARY_PATH"
    echo "Using CUDA version: $CUDA_VERSION"
fi

# Environment Variables
#export NCCL_DEBUG=INFO
export PYTHONFAULTHANDLER=1
export TORCH_NCCL_BLOCKING_WAIT=1
export GPUS_PER_NODE=8 # 4 for G5.12x, 8 for P4/P5

# EFA settings for multi-node
export FI_PROVIDER=efa
export FI_EFA_USE_HUGE_PAGE=0
export FI_EFA_SET_CUDA_SYNC_MEMOPS=0
export LD_PRELOAD=/usr/local/cuda-${CUDA_VERSION}/lib/libnccl.so
export NCCL_SOCKET_IFNAME=^docker,lo,veth,eth

# HuggingFace timeout for large clusters
export HF_HUB_ETAG_TIMEOUT=60

# Activate virtual environment
source ../.venv/bin/activate

###########################
##### Training Config #####
###########################

# Model Configuration
MODEL_NAME="Qwen/Qwen3-0.6B"

# Dataset Configuration
DATASET="/fsx/data/pretrain/wikitext-2"
LOCAL_DATASET=true  # Set to false for HuggingFace datasets

# DATASET="allenai/c4"
# DATASET_CONFIG="en"
# LOCAL_DATASET=false

# Training Parameters
MAX_STEPS=500
BATCH_SIZE=2
MAX_LENGTH=4096
LEARNING_RATE=5e-5

# Logging and Checkpointing
SAVE_EVERY_N_STEPS=100
CHECKPOINT_DIR="./checkpoints"

# Environment Check
echo "=== Environment Check ==="
echo "Python: $(which python)"
echo "PyTorch version: $(python -c 'import torch; print(torch.__version__)' 2>/dev/null || echo 'PyTorch not found')"
echo "CUDA available: $(python -c 'import torch; print(torch.cuda.is_available())' 2>/dev/null || echo 'Cannot check CUDA')"
echo "Number of nodes: $SLURM_JOB_NUM_NODES"
echo "Job ID: $SLURM_JOB_ID"
echo "Master node: $(hostname)"
echo "=========================="

# Torchrun arguments
declare -a TORCHRUN_ARGS=(
    --nproc_per_node=$GPUS_PER_NODE
    --nnodes=$SLURM_JOB_NUM_NODES
    --rdzv_id=$SLURM_JOB_ID
    --rdzv_backend=c10d
    --rdzv_endpoint=$(hostname)
)

# Training arguments
declare -a TRAINING_ARGS=(
    --nodes=$SLURM_NNODES
    --gpus=8
    --max_steps=$MAX_STEPS
    --batch_size=$BATCH_SIZE
    --dataset="$DATASET"
    --dataset_config="$DATASET_CONFIG"
    $([ "$LOCAL_DATASET" = true ] && echo "--local_dataset")
    --model_name="$MODEL_NAME"
    --max_length=$MAX_LENGTH
    --learning_rate=$LEARNING_RATE
    --save_every_n_steps=$SAVE_EVERY_N_STEPS
    --checkpoint_dir="$CHECKPOINT_DIR"
)

# Auto-resume for HyperPod
AUTO_RESUME=""
if [ -d "/opt/sagemaker_cluster" ]; then
    echo "Detected Hyperpod cluster.. enabling --auto-resume=1"
    AUTO_RESUME="--auto-resume=1"
fi

echo "Executing command:"
echo "srun ${AUTO_RESUME} torchrun ${TORCHRUN_ARGS[@]} train_fabric.py ${TRAINING_ARGS[@]}"
echo ""

# Run training with srun + torchrun for Fabric
srun ${AUTO_RESUME} torchrun "${TORCHRUN_ARGS[@]}" train_fabric.py "${TRAINING_ARGS[@]}"
