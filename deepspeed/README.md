# DeepSpeed Training Setup

This directory contains DeepSpeed-based distributed training code.

## File Structure

```
deepspeed/
├── ds_config.json              # DeepSpeed ZeRO-2 configuration file
├── train.sbatch                # SLURM multi-node batch script
├── train-pyxis.sbatch          # Pyxis+Enroot multi-node batch script
├── train-singlenode.sh         # Single node execution script
├── train-pyxis-singlenode.sh   # Pyxis+Enroot single node execution script
├── setup-pyxis.sh              # Pyxis+Enroot container setup script
├── Dockerfile                  # Docker image for Pyxis+Enroot
├── src/
│   ├── train_deepspeed.py      # Main training script
│   ├── requirements.txt        # Python dependencies
│   └── model_utils/            # Utility modules
│       ├── __init__.py
│       ├── arguments.py        # Command-line argument parser
│       ├── checkpoint.py       # Checkpoint utilities
│       ├── concat_dataset.py   # Dataset utilities
│       └── train_utils.py      # Training utilities
└── README.md                   # This file
```

## Usage

### 1. Environment Setup

#### Local Environment
```bash
uv sync
```

#### Pyxis+Enroot Environment
```bash
./setup-pyxis.sh
```

### 2. Single Node Execution

#### Local Execution
```bash
./train-singlenode.sh
```

#### Pyxis+Enroot Execution
```bash
./train-pyxis-singlenode.sh
```

#### Execute on Specific Node
```bash
./train-singlenode.sh ip-10-1-199-129
./train-pyxis-singlenode.sh ip-10-1-199-129
```

#### Select CUDA Version
```bash
CUDA_VERSION=12.9 ./train-singlenode.sh ip-10-1-199-129
CUDA_VERSION=12.9 ./train-pyxis-singlenode.sh
```

### 3. Multi-Node Execution (SLURM)

#### Local Environment
```bash
sbatch train.sbatch
```

#### Pyxis+Enroot Environment
```bash
sbatch train-pyxis.sbatch
```

#### Select CUDA Version
```bash
CUDA_VERSION=12.9 sbatch train.sbatch
CUDA_VERSION=12.9 sbatch train-pyxis.sbatch
```

## Configuration

### DeepSpeed Configuration (ds_config.json)
All training hyperparameters are centrally managed in `ds_config.json`:

```json
{
  "train_micro_batch_size_per_gpu": 1,
  "gradient_accumulation_steps": 1,
  "optimizer": {
    "type": "AdamW",
    "params": {
      "lr": 5e-5,
      "betas": [0.9, 0.95],
      "weight_decay": 0.1
    }
  },
  "scheduler": {
    "type": "WarmupCosineLR",
    "params": {
      "warmup_min_ratio": 0.0,
      "warmup_num_steps": 10,
      "cosine_min_ratio": 0.0
    }
  },
  "zero_optimization": {
    "stage": 2,
    "offload_optimizer": {
      "device": "cpu",
      "pin_memory": true
    }
  },
  "bf16": {
    "enabled": true
  }
}
```

### Script Configuration

#### Single Node (train-singlenode.sh)
```bash
# Dataset configuration
DATASET="/fsx/data/wikitext-2"          # Local dataset
DATASET_CONFIG_NAME="en"                # For HuggingFace datasets
LOCAL_DATASET=true                      # true: local, false: HuggingFace

# HuggingFace dataset example
# DATASET="allenai/c4"
# DATASET_CONFIG_NAME="en"
# LOCAL_DATASET=false

# Training configuration
MAX_STEPS=100
CHECKPOINT_FREQ=50
```

#### Multi-Node (train.sbatch)
```bash
#SBATCH --nodes=2                       # Number of nodes
#SBATCH --job-name=qwen3_0_6b-DeepSpeed

# Same configuration variables
LOCAL_DATASET=true
MAX_STEPS=1000
```

#### Pyxis+Enroot Configuration (train-pyxis.sbatch)
```bash
# Container configuration
export CONTAINER_IMAGE="/fsx/ubuntu/aws-ai-infra-helper/deepspeed/deepspeed-training.sqsh"
export CONTAINER_MOUNTS="/fsx:/fsx"

# CUDA architecture list for AWS GPUs
export TORCH_CUDA_ARCH_LIST="8.0;8.6;8.9;9.0;10.0;10.3"
# 8.0: P4 (A100)
# 8.6: A10G
# 8.9: L4, L40S
# 9.0: P5 (H100/H200)
# 10.0: P6 (GB200/B200)
# 10.3: GB300/B300

# NCCL network configuration
export NCCL_SOCKET_IFNAME=^docker0,lo
export NCCL_IB_DISABLE=1
export NCCL_P2P_DISABLE=1
```

## Checkpoint Management

### Automatic Restart
- Scripts automatically check `checkpoints/latest` file and restart from the latest checkpoint
- Manual restart: use `--resume_from_checkpoint checkpoints/` parameter

### Checkpoint Structure
```
checkpoints/
├── latest                              # Latest checkpoint name
├── qwen3_0_6b-500steps/               # Checkpoint directory
│   ├── mp_rank_00_model_states.pt     # Model states
│   └── bf16_zero_pp_rank_*_optim_states.pt  # Optimizer states
└── zero_to_fp32.py                    # Checkpoint conversion script
```

## Monitoring

### Check Logs
```bash
# SLURM logs
tail -f logs/qwen3_0_6b-DeepSpeed_*.out

# Real-time training progress
grep -E "(Step|Loss|lr)" logs/qwen3_0_6b-DeepSpeed_*.out
```

### Performance Metrics
- Training loss and validation loss
- Learning rate scheduling
- Throughput (tokens/sec)
- GPU memory usage

## Performance Optimization

### Memory Optimization
1. **Adjust batch size**: Modify `train_micro_batch_size_per_gpu` value
2. **CPU offloading**: Enable `offload_optimizer` when out of memory
3. **Gradient accumulation**: Increase `gradient_accumulation_steps`

### Throughput Optimization
1. **Communication optimization**: Adjust `allgather_bucket_size`, `reduce_bucket_size`
2. **Data loading**: Configure `num_workers` and `pin_memory`
3. **CUDA version**: Use latest CUDA version

## Troubleshooting

### Common Errors

#### CUDA OOM
```bash
# Reduce batch size
"train_micro_batch_size_per_gpu": 1

# Enable CPU offloading
"offload_optimizer": {
  "device": "cpu",
  "pin_memory": true
}
```

#### Batch Size Mismatch
- DeepSpeed automatically calculates `train_batch_size`, so remove it from config

#### Checkpoint Loading Failure
```bash
# Check checkpoint directory
ls -la checkpoints/
cat checkpoints/latest

# Manual restart
--resume_from_checkpoint checkpoints/
```

#### NCCL Network Errors (Pyxis/Enroot)
```bash
# Bootstrap: no socket interface found
# Solution: Use NCCL_SOCKET_IFNAME=^docker0,lo to exclude docker/loopback interfaces

# Connection errors between nodes
# Solution: Ensure proper network configuration and container mounts
```

### Debugging
```bash
# Verbose logging
export DEEPSPEED_LOG_LEVEL=DEBUG

# NCCL debug information
export NCCL_DEBUG=INFO

# CUDA memory optimization
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
```

## Pyxis+Enroot Specifics

### Container Image Management
```bash
# Build and convert image
./setup-pyxis.sh

# Check image
ls -lh deepspeed-training.sqsh

# Interactive container session
srun --container-image=deepspeed-training.sqsh --container-mounts=/fsx:/fsx --pty bash
```

### Container Mounts
- `--container-mounts=/fsx:/fsx`: Mount host `/fsx` to container `/fsx`
- Does not affect container size (files remain on host)
- Provides access to datasets and code from within container

### Container Writable Mode
- Containers are read-only by default
- Use `--container-writable-tmpfs` for temporary file creation
- Changes are lost when container exits
- Persistent data must be saved to mounted paths

## Environment Requirements

- Python 3.10+
- PyTorch 2.0+
- DeepSpeed 0.14+
- CUDA 12.8+ (recommended)
- 8x GPU (P4/P5 instances)
- For Pyxis+Enroot: Docker, Enroot, Pyxis SLURM plugin

## References

- [DeepSpeed Official Documentation](https://deepspeed.readthedocs.io/)
- [ZeRO Paper](https://arxiv.org/abs/1910.02054)
- [DeepSpeed Tutorials](https://www.deepspeed.ai/tutorials/)
- [HuggingFace Datasets](https://huggingface.co/docs/datasets/)
- [NVIDIA Pyxis](https://github.com/NVIDIA/pyxis)
- [NVIDIA Enroot](https://github.com/NVIDIA/enroot)
