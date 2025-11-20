#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

#SBATCH --nodes=2 # number of nodes to use
#SBATCH --job-name=llama3_2_1b-FSDP # name of your job
#SBATCH --output=logs/%x_%j.out # logfile for stdout
#SBATCH --error=logs/%x_%j.err # logfile for stderr, remove it to merge both outputs
#SBATCH --exclusive # job has exclusive use of the resource, no sharing

set -ex;

###########################
# 
###########################
if [ -f "$(pwd)/env/bin/activate" ]; then
    echo "Activating virtual environment..."
    source $(pwd)/env/bin/activate
    echo "Virtual environment activated: $VIRTUAL_ENV"
else
    echo "⚠️  Virtual environment not found! Please update the path."
    echo "Current working directory: $(pwd)"
    echo "Available environments:"
    find /fsx -name "activate" -type f 2>/dev/null | head -5
    find /shared -name "activate" -type f 2>/dev/null | head -5
fi

# ENvironment Check
echo "=== Environment Check ==="
echo "Python: $(which python)"
echo "Torchrun: $(which torchrun 2>/dev/null || echo 'Not found')"
echo "PyTorch version: $(python -c 'import torch; print(torch.__version__)' 2>/dev/null || echo 'PyTorch not found')"
echo "CUDA available: $(python -c 'import torch; print(torch.cuda.is_available())' 2>/dev/null || echo 'Cannot check CUDA')"
echo "Number of nodes: $SLURM_JOB_NUM_NODES"
echo "Job ID: $SLURM_JOB_ID"
echo "Master node: $(hostname)"
echo "=========================="

###########################
###### User Variables #####
###########################

GPUS_PER_NODE=4 # 4 for G5.12x, 8 for P4/P5

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

## Plenty of EFA level variables
## For G4dn and other G5, comment out all
#export FI_LOG_LEVEL=warn
export NCCL_DEBUG=INFO
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
export LD_PRELOAD=/usr/local/cuda-12.8/lib/libnccl.so
export NCCL_SOCKET_IFNAME=^docker,lo,veth,eth

## Set HuggingFace metadata timeout (in seconds) for large clusters
export HF_HUB_ETAG_TIMEOUT=60


########################
####### Container ######
########################

if [ ! -z $CONTAINER_IMAGE ];
then
    export TRAIN_SCRIPT=./train.py
    
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
# export TRAIN_SCRIPT=${TRAIN_SCRIPT:=./src/train.py}

# UV 실행 설정
if [ "$UV_RUN" = "1" ]; then
    export TORCHRUN="uv run torchrun"
    export TRAIN_SCRIPT=${TRAIN_SCRIPT:=./src/train.py}
else
    export TORCHRUN=torchrun
    export TRAIN_SCRIPT=${TRAIN_SCRIPT:=./src/train.py}
fi

############################
# llama3_2_1b Training Params ##
############################

declare -a TRAINING_ARGS=(
    --max_context_width=8192
    --num_key_value_heads=2
    --intermediate_size=8192
    --hidden_width=2048
    --num_layers=16
    --num_heads=32
    --model_type=llama_v3
    --tokenizer=hf-internal-testing/llama-tokenizer
    --checkpoint_freq=50
    --validation_freq=100
    --max_steps=100
    --checkpoint_dir=./checkpoints
    --dataset=allenai/c4
    --dataset_config_name=en
    --resume_from_checkpoint=./checkpoints
    --train_batch_size=1
    --val_batch_size=1
    --sharding_strategy=full # https://pytorch.org/docs/stable/fsdp.html
    --offload_activations=1
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