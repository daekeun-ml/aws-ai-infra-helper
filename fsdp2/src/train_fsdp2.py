import argparse
import datetime
import math
import time
import logging
import sys
import os
import functools

import torch
import torch.distributed as dist
from torch.distributed.fsdp import fully_shard
from torch.distributed.tensor import distribute_tensor
from transformers import AutoModelForCausalLM, AutoTokenizer

from model_utils.train_utils import (
    compute_num_params,
    get_learning_rate_scheduler,
    create_streaming_dataloader
)
from model_utils.arguments import parse_args

logging.basicConfig(format="%(asctime)s [%(levelname)s] %(name)s: %(message)s", level=logging.INFO, stream=sys.stdout)
logger = logging.getLogger(__name__)


def eval_model(model, dataloader, num_batches):
    """Eval step."""
    model.eval()
    n_batches = 0
    loss = 0.0

    with torch.no_grad():
        for batch_idx, input_data in enumerate(dataloader):
            if batch_idx >= num_batches:
                break

            input_data = input_data.to(model.device)
            outputs = model(input_ids=input_data, attention_mask=None, labels=input_data)
            loss += outputs.loss
            n_batches += 1

    if n_batches > 0:
        detached_loss = loss.detach()
        torch.distributed.all_reduce(detached_loss)
        loss = detached_loss.item() / dist.get_world_size()
        loss /= n_batches
        ppl = math.exp(loss)
    else:
        loss = -1.0
        ppl = -1.0

    return loss, ppl


def save_checkpoint(model, optimizer, lr_scheduler, total_steps, start_batch_index, checkpoint_dir, sub_dir):
    """Save checkpoint using FSDP2 DTensor APIs."""
    from torch.distributed.checkpoint.state_dict import get_model_state_dict, StateDictOptions
    
    save_dir = os.path.join(checkpoint_dir, sub_dir)
    
    if dist.get_rank() == 0:
        os.makedirs(save_dir, exist_ok=True)
        logger.info(f"Saving checkpoint to {save_dir}")
    
    dist.barrier()
    
    try:
        # Get model state dict using DCP API
        model_state_dict = get_model_state_dict(
            model=model,
            options=StateDictOptions(
                full_state_dict=True,
                cpu_offload=True,
            )
        )
        
        # Save on rank 0 only
        if dist.get_rank() == 0:
            torch.save({
                'model_state_dict': model_state_dict,
                'total_steps': total_steps,
                'start_batch_index': start_batch_index,
            }, os.path.join(save_dir, 'checkpoint.pt'))
            
            # Update latest file
            latest_file = os.path.join(checkpoint_dir, f"{args.model_type}-latest")
            with open(latest_file, 'w') as f:
                f.write(sub_dir)
            logger.info(f"Saved checkpoint at step {total_steps}")
            
    except Exception as e:
        if dist.get_rank() == 0:
            logger.error(f"Failed to save checkpoint: {e}")
    
    dist.barrier()


def load_checkpoint(model, optimizer, lr_scheduler, checkpoint_path):
    """Load checkpoint using FSDP2 DTensor APIs."""
    from torch.distributed.checkpoint.state_dict import set_model_state_dict, StateDictOptions
    
    checkpoint_file = os.path.join(checkpoint_path, 'checkpoint.pt')
    
    if not os.path.exists(checkpoint_file):
        return 0, 0
    
    if dist.get_rank() == 0:
        logger.info(f"Loading checkpoint from {checkpoint_file}")
    
    try:
        # Load checkpoint
        checkpoint = torch.load(checkpoint_file, map_location='cpu')
        
        # Load model state dict using DCP API
        if 'model_state_dict' in checkpoint:
            set_model_state_dict(
                model=model,
                model_state_dict=checkpoint['model_state_dict'],
                options=StateDictOptions(
                    full_state_dict=True,
                    broadcast_from_rank0=True,
                ),
            )
        
        total_steps = checkpoint.get('total_steps', 0)
        start_batch_index = checkpoint.get('start_batch_index', 0)
        
        if dist.get_rank() == 0:
            logger.info(f"Loaded checkpoint from step {total_steps}, batch {start_batch_index}")
        
        return total_steps, start_batch_index
        
    except Exception as e:
        if dist.get_rank() == 0:
            logger.warning(f"Failed to load checkpoint: {e}")
        return 0, 0


def train(
    model,
    optimizer,
    lr_scheduler,
    train_dataloader,
    val_dataloader,
    num_params,
    args,
    global_rank,
    world_size,
    total_steps=0,
    start_batch_index=0
):
    model.train()
    
    if global_rank == 0 and start_batch_index > 0:
        logger.info(f"Starting training from step {total_steps}, skipping to batch {start_batch_index + 1}")
    
    for epoch in range(args.epochs):
        for batch_idx, input_data in enumerate(train_dataloader):
            if batch_idx <= start_batch_index:
                continue
                
            step_start = time.time()
            
            # Move data to device
            input_data = input_data.to(model.device)
            
            # Forward pass
            outputs = model(input_ids=input_data, attention_mask=None, labels=input_data)
            loss = outputs.loss
            
            # Backward pass
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
            lr_scheduler.step()
            
            total_steps += 1
            step_time = time.time() - step_start
            sample_processed = input_data.shape[0] * world_size
            throughput = sample_processed / step_time
            loss_scalar = loss.item()
            current_lr = optimizer.param_groups[0]['lr']
            
            if global_rank == 0 and batch_idx % args.logging_freq == 0:
                logger.info(
                    "Batch %d Loss: %.5f, Speed: %.2f samples/sec, lr: %.6f",
                    batch_idx,
                    loss_scalar,
                    throughput,
                    current_lr,
                )
            
            if args.validation_freq and not total_steps % args.validation_freq:
                val_loss, val_ppl = eval_model(
                    model, val_dataloader, args.validation_batches
                )
                model.train()
                if global_rank == 0:
                    logger.info(
                        "Batch %d Validation loss: %s",
                        batch_idx,
                        val_loss,
                    )
            
            if args.checkpoint_dir and not total_steps % args.checkpoint_freq:
                sub_dir = f"{args.model_type}-{total_steps}steps"
                if global_rank == 0:
                    logger.info(f"Triggering checkpoint save at step {total_steps}")
                save_checkpoint(model, optimizer, lr_scheduler, total_steps, batch_idx + 1, args.checkpoint_dir, sub_dir)
                
            if total_steps >= args.max_steps:
                if global_rank == 0:
                    logger.info(f"Training completed! Reached max_steps={args.max_steps}")
                break


def main(args):
    # Initialize distributed
    dist.init_process_group(backend="nccl")
    global_rank = dist.get_rank()
    world_size = dist.get_world_size()
    
    # Set device
    torch.cuda.set_device(global_rank % torch.cuda.device_count())
    device = torch.device("cuda", global_rank % torch.cuda.device_count())
    
    # Use bfloat16 for mixed precision
    dtype = torch.bfloat16
    
    if global_rank == 0:
        logger.info("Creating Model with FSDP2")
    
    # Create model directly on device
    model = AutoModelForCausalLM.from_pretrained(args.tokenizer, dtype=dtype)
    model = model.to(device)
    
    # Apply fully_shard to transformer layers
    for module in model.modules():
        # Apply to transformer decoder layers (adjust based on model architecture)
        if hasattr(module, 'self_attn') and hasattr(module, 'mlp'):  # Common transformer layer pattern
            fully_shard(module)
    
    # Apply fully_shard to root model
    fully_shard(model)
    
    num_params = compute_num_params(model)
    
    if global_rank == 0:
        logger.info(
            "Created FSDP2 model with total parameters: %d (%.2f B)", 
            num_params, num_params * 1e-9
        )
    
    # Create optimizer (after fully_shard)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr)
    
    # Create learning rate scheduler
    lr_scheduler = get_learning_rate_scheduler(optimizer, args)
    
    # Create dataloaders
    train_dataloader = create_streaming_dataloader(
        args.dataset, 
        args.tokenizer, 
        name=None if args.local_dataset else args.dataset_config_name, 
        batch_size=args.train_batch_size,
        split='train',
        local_dataset=args.local_dataset
    )
    
    val_dataloader = create_streaming_dataloader(
        args.dataset, 
        args.tokenizer, 
        name=None if args.local_dataset else args.dataset_config_name, 
        batch_size=args.val_batch_size,
        split='validation',
        local_dataset=args.local_dataset
    )
    
    if global_rank == 0:
        logger.info("Initialized FSDP2 model and dataloaders")
    
    total_steps = 0
    start_batch_index = 0
    
    # Auto-resume from latest checkpoint if available
    if args.resume_from_checkpoint:
        if global_rank == 0:
            logger.info(f"Checking for checkpoints in: {args.resume_from_checkpoint}")
        checkpoint_path = args.resume_from_checkpoint
        latest_file = os.path.join(checkpoint_path, f"{args.model_type}-latest")
        if os.path.exists(latest_file):
            with open(latest_file, 'r') as f:
                checkpoint_name = f.read().strip()
            checkpoint_path = os.path.join(checkpoint_path, checkpoint_name)
            if global_rank == 0:
                logger.info(f"Found existing checkpoint: {checkpoint_name}")
                logger.info(f"Loading checkpoint from: {checkpoint_path}")
            
            # Load checkpoint
            total_steps, start_batch_index = load_checkpoint(model, optimizer, lr_scheduler, checkpoint_path)
            
            # Check if training is already completed
            if total_steps >= args.max_steps:
                if global_rank == 0:
                    logger.info(f"Training already completed! Current steps: {total_steps}, max_steps: {args.max_steps}")
                    logger.info("FSDP2 Training completed successfully!")
                dist.destroy_process_group()
                return
        else:
            if global_rank == 0:
                logger.info(f"No latest file found at: {latest_file}")
    else:
        if global_rank == 0:
            logger.info("No resume_from_checkpoint specified")
    
    train(
        model,
        optimizer,
        lr_scheduler,
        train_dataloader,
        val_dataloader,
        num_params,
        args,
        global_rank,
        world_size,
        total_steps,
        start_batch_index
    )
    
    if global_rank == 0:
        logger.info("FSDP2 Training completed successfully!")
    
    dist.destroy_process_group()


if __name__ == "__main__":
    args, _ = parse_args()
    main(args)
