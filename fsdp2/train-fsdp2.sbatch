#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

#SBATCH --nodes=2 # number of nodes to use
#SBATCH --job-name=qwen3_0_6b-FSDP2 # name of your job
#SBATCH --output=logs/%x_%j.out # logfile for stdout
#SBATCH --error=logs/%x_%j.err # logfile for stderr, remove it to merge both outputs
#SBATCH --exclusive # job has exclusive use of the resource, no sharing

set -ex;

# CUDA Version Setup
CUDA_VERSION=${CUDA_VERSION:-"12.8"}  # Default to 12.8
if [ -d "/usr/local/cuda-${CUDA_VERSION}" ]; then
    export CUDA_HOME="/usr/local/cuda-${CUDA_VERSION}"
    export PATH="$CUDA_HOME/bin:$PATH"
    export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$LD_LIBRARY_PATH"
    echo "Using CUDA version: $CUDA_VERSION"
fi

# Change to the parent directory where .venv is located
cd ..

# For Checkpoint: ensuring synchronization across all nodes. If you encounter NCCL errors when saving checkpoints, adding this option will improve stability.
export TORCH_NCCL_BLOCKING_WAIT=1
export PYTHONPATH=$(dirname $(pwd)):$PYTHONPATH

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

# Change back to fsdp directory for training
cd fsdp2

# Environment Check
echo "=== Environment Check ==="
if [ "$UV_RUN" = "1" ]; then
    echo "Python: $(uv run which python)"
    echo "PyTorch version: $(uv run python -c 'import torch; print(torch.__version__)' 2>/dev/null || echo 'PyTorch not found')"
    echo "CUDA available: $(uv run python -c 'import torch; print(torch.cuda.is_available())' 2>/dev/null || echo 'Cannot check CUDA')"
else
    echo "Python: $(which python)"
    echo "PyTorch version: $(python -c 'import torch; print(torch.__version__)' 2>/dev/null || echo 'PyTorch not found')"
    echo "CUDA available: $(python -c 'import torch; print(torch.cuda.is_available())' 2>/dev/null || echo 'Cannot check CUDA')"
fi

echo "Number of nodes: $SLURM_JOB_NUM_NODES"
echo "Job ID: $SLURM_JOB_ID"
echo "Master node: $(hostname)"
echo "=========================="

###########################
###### User Variables #####
###########################

GPUS_PER_NODE=8 # 4 for G5.12x, 8 for P4/P5

###############################
###### Container Variable #####
###############################
# Uncomment if you want to use a container instea of Virtual Environment.
#export CONTAINER_IMAGE=$(pwd)/pytorch-fsdp.sqsh
export DATA_PATH=/fsx/ubuntu
export FSX_MOUNT=$(pwd):$DATA_PATH

###########################
## Environment Variables ##
###########################
#export NCCL_DEBUG=INFO

## Plenty of EFA level variables
## For G4dn and other G5, comment out all
export FI_PROVIDER=efa
export FI_EFA_USE_HUGE_PAGE=0    # Set to 0 when you see os.fork() causes OSError: Cannot allocate memory.  Disabling huge page causes minor performance hit.
## Switching SYNC_MEMOPS to zero can boost throughput with FSDP
## Disables CU_POINTER_ATTRIBUTE_SYNC_MEMOPS
## Reduces memory synchronizations
## https://docs.nvidia.com/cuda/cuda-driver-api/group__CUDA__UNIFIED.html
export FI_EFA_SET_CUDA_SYNC_MEMOPS=0
# LD_PRELOAD is required for PyTorch to find the NCCL library
# This path assumes you are using the Deep Learning AMI
# If you are not using the DLAMI, you may need to update this path
export LD_PRELOAD=/usr/local/cuda-${CUDA_VERSION}/lib/libnccl.so
export NCCL_SOCKET_IFNAME=^docker,lo,veth,eth

## Set HuggingFace metadata timeout (in seconds) for large clusters
export HF_HUB_ETAG_TIMEOUT=60


########################
####### Container ######
########################

if [ ! -z $CONTAINER_IMAGE ];
then
    export TRAIN_SCRIPT=./train_fsdp2.py
    
    declare -a ARGS=(
        --container-image $CONTAINER_IMAGE
        --container-mounts $FSX_MOUNT
    )
fi

###########################
####### Torch Dist  #######
###########################

declare -a TORCHRUN_ARGS=(
    --nproc_per_node=$GPUS_PER_NODE
    --nnodes=$SLURM_JOB_NUM_NODES
    --rdzv_id=$SLURM_JOB_ID
    --rdzv_backend=c10d
    --rdzv_endpoint=$(hostname)
)

# export TORCHRUN=torchrun
# export TRAIN_SCRIPT=${TRAIN_SCRIPT:=./src/train_fsdp2.py}

# UV 실행 설정
if [ "$UV_RUN" = "1" ]; then
    export TORCHRUN="uv run torchrun"
    export TRAIN_SCRIPT=${TRAIN_SCRIPT:=./src/train_fsdp2.py}
else
    export TORCHRUN=torchrun
    export TRAIN_SCRIPT=${TRAIN_SCRIPT:=./src/train_fsdp2.py}
fi

############################
# qwen3_0_6b FSDP2 Training Params ##
############################

# Training Configuration
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
CHECKPOINT_DIR="./checkpoints"

# Model configuration (from Qwen3-0.6B config.json)
MAX_CONTEXT_WIDTH=8192
NUM_KEY_VALUE_HEADS=8
INTERMEDIATE_SIZE=3072
HIDDEN_WIDTH=1024
NUM_LAYERS=28
NUM_HEADS=16

# Batch sizes
TRAIN_BATCH_SIZE=1
VAL_BATCH_SIZE=1

declare -a TRAINING_ARGS=(
    --model_type=$MODEL_TYPE
    --tokenizer=$TOKENIZER
    --dataset=$DATASET
    $([ "$LOCAL_DATASET" = true ] && echo "--local_dataset")
    $([ "$LOCAL_DATASET" = false ] && echo "--dataset_config_name $DATASET_CONFIG_NAME")
    --max_steps=$MAX_STEPS
    --epochs=$EPOCHS
    --logging_freq=$LOGGING_FREQ
    --validation_freq=$VALIDATION_FREQ
    --validation_batches=$VALIDATION_BATCHES
    --checkpoint_freq=$CHECKPOINT_FREQ
    --checkpoint_dir=$CHECKPOINT_DIR
    --max_context_width=$MAX_CONTEXT_WIDTH
    --num_key_value_heads=$NUM_KEY_VALUE_HEADS
    --intermediate_size=$INTERMEDIATE_SIZE
    --hidden_width=$HIDDEN_WIDTH
    --num_layers=$NUM_LAYERS
    --num_heads=$NUM_HEADS
    --train_batch_size=$TRAIN_BATCH_SIZE
    --val_batch_size=$VAL_BATCH_SIZE
    --resume_from_checkpoint=$CHECKPOINT_DIR
)

AUTO_RESUME=""
if [ -d "/opt/sagemaker_cluster" ]; then
    echo "Detected Hyperpod cluster.. enabling --auto-resume=1"
    AUTO_RESUME="--auto-resume=1"
fi


echo "Executing command:"
echo "srun ${AUTO_RESUME} -l ${ARGS[@]} ${TORCHRUN} ${TORCHRUN_ARGS[@]} $TRAIN_SCRIPT ${TRAINING_ARGS[@]}"
echo ""

srun ${AUTO_RESUME} -l "${ARGS[@]}" ${TORCHRUN} "${TORCHRUN_ARGS[@]}" $TRAIN_SCRIPT "${TRAINING_ARGS[@]}"
