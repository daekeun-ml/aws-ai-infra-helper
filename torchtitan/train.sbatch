#!/bin/bash
# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.

# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree.

# Usage:
#   Single node:  sbatch --nodes=1 train.sbatch
#   Multi node:   sbatch --nodes=4 train.sbatch
#   Override module/config:
#     MODULE=llama3    CONFIG=llama3_70b     sbatch --nodes=2 train.sbatch
#     MODULE=qwen3     CONFIG=qwen3_8b       sbatch --nodes=1 train.sbatch
#     MODULE=llama4    CONFIG=llama4_scout   sbatch --nodes=4 train.sbatch
#     MODULE=deepseek_v3 CONFIG=deepseek_v3_671b sbatch --nodes=8 train.sbatch
#
#   Supported modules (models):     llama3, llama4, qwen3, deepseek_v3, gpt_oss, flux
#   Supported modules (experiments): rl, vlm, ft.llama3, autoparallel.llama3, ...

#SBATCH --job-name=torchtitan
#SBATCH --nodes=1
#SBATCH --exclusive

GPUS_PER_NODE=8
MODULE=${MODULE:-"llama3"}
CONFIG=${CONFIG:-"llama3_8b"}

export NCCL_DEBUG=WARN
export PYTHONFAULTHANDLER=1
export FI_PROVIDER=efa
export FI_EFA_USE_HUGE_PAGE=0
## Switching SYNC_MEMOPS to zero can boost throughput with FSDP
## Disables CU_POINTER_ATTRIBUTE_SYNC_MEMOPS
## Reduces memory synchronizations
## https://docs.nvidia.com/cuda/cuda-driver-api/group__CUDA__UNIFIED.html
export FI_EFA_SET_CUDA_SYNC_MEMOPS=0

## Set HuggingFace metadata timeout (in seconds) for large clusters
export HF_HUB_ETAG_TIMEOUT=60

export LD_LIBRARY_PATH=/opt/amazon/efa/lib:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=/usr/local/lib/:$LD_LIBRARY_PATH
export CUDA_LAUNCH_BLOCKING=0

export NCCL_SOCKET_IFNAME=^docker,lo,veth
export NCCL_BUFFSIZE=2097152

# Single-node vs multi-node torchrun args
if [ "$SLURM_JOB_NUM_NODES" -eq 1 ]; then
    declare -a TORCHRUN_ARGS=(
        --nproc_per_node=$GPUS_PER_NODE
        --standalone
    )
else
    declare -a TORCHRUN_ARGS=(
        --nproc_per_node=$GPUS_PER_NODE
        --nnodes=$SLURM_JOB_NUM_NODES
        --rdzv_id=$SLURM_JOB_ID
        --rdzv_backend=c10d
        --rdzv_endpoint=$(hostname)
    )
fi

AUTO_RESUME=""
if [ -d "/opt/sagemaker_cluster" ]; then
    echo "Detected Hyperpod cluster.. enabling --auto-resume=1"
    AUTO_RESUME="--auto-resume=1"
fi

echo "Nodes: $SLURM_JOB_NUM_NODES, Module: $MODULE, Config: $CONFIG"

dcgmi profile --pause
srun ${AUTO_RESUME} -l /fsx/ubuntu/.local/bin/torchrun "${TORCHRUN_ARGS[@]}" -m torchtitan.train --module ${MODULE} --config ${CONFIG}
dcgmi profile --resume
