import argparse
import datetime
import math
import time
import logging
import sys

import torch
import torch.distributed as dist
import deepspeed
from transformers import AutoModelForCausalLM, AutoTokenizer
from datasets import load_dataset, load_from_disk

from model_utils.concat_dataset import ConcatTokensDataset
from model_utils.train_utils import (
    get_model_config,
    compute_num_params,
    get_learning_rate_scheduler,
    create_streaming_dataloader
)
from model_utils.checkpoint import save_checkpoint, load_checkpoint
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

            # Move data to the correct device
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


def train(
    model_engine,
    train_dataloader,
    val_dataloader,
    model_config,
    num_params,
    args,
    global_rank,
    world_size,
    total_steps=0,
    start_batch_index=0
):
    model_engine.train()
    
    for epoch in range(args.epochs):
        for batch_idx, input_data in enumerate(train_dataloader):
            if batch_idx < start_batch_index:
                continue
                
            step_start = time.time()
            
            # Move data to device
            input_data = input_data.to(model_engine.device)
            
            # Forward pass
            outputs = model_engine(input_ids=input_data, attention_mask=None, labels=input_data)
            loss = outputs.loss
            
            # Backward pass
            model_engine.backward(loss)
            model_engine.step()
            
            total_steps += 1
            step_time = time.time() - step_start
            sample_processed = input_data.shape[0] * world_size
            throughput = sample_processed / step_time
            loss_scalar = loss.item()
            current_lr = model_engine.get_lr()[0]
            
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
                    model_engine, val_dataloader, args.validation_batches
                )
                model_engine.train()
                if global_rank == 0:
                    logger.info(
                        "Batch %d Validation loss: %s",
                        batch_idx,
                        val_loss,
                    )
            
            if args.checkpoint_dir and not total_steps % args.checkpoint_freq:
                user_content = {
                    "cli_args": args.__dict__,
                    "num_params": num_params,
                    "total_steps": total_steps,
                    "model_config": model_config,
                    "start_batch_index": batch_idx + 1,
                }
                sub_dir = f"{args.model_type}-{total_steps}steps"
                
                # DeepSpeed checkpoint
                model_engine.save_checkpoint(args.checkpoint_dir, sub_dir, client_state=user_content)
                
            if total_steps >= args.max_steps:
                break


def main(args):
    # Initialize DeepSpeed
    deepspeed.init_distributed()
    global_rank = dist.get_rank()
    world_size = dist.get_world_size()
    
    # Use default dtype (DeepSpeed config handles bf16)
    dtype = torch.get_default_dtype()
    
    model_config = get_model_config(args)
    if global_rank == 0:
        logger.info("Creating Model")
    
    # Create model
    model = AutoModelForCausalLM.from_config(model_config)
    num_params = compute_num_params(model)
    
    if global_rank == 0:
        logger.info(
            "Created model with total parameters: %d (%.2f B)", 
            num_params, num_params * 1e-9
        )
    
    # Create dataloaders (use small batch size, DeepSpeed will handle actual batching)
    train_dataloader = create_streaming_dataloader(
        args.dataset, 
        args.tokenizer, 
        name=None if args.local_dataset else args.dataset_config_name, 
        batch_size=1,  # DeepSpeed config controls actual batch size
        split='train',
        local_dataset=args.local_dataset
    )
    
    val_dataloader = create_streaming_dataloader(
        args.dataset, 
        args.tokenizer, 
        name=None if args.local_dataset else args.dataset_config_name, 
        batch_size=1,  # DeepSpeed config controls actual batch size
        split='validation',
        local_dataset=args.local_dataset
    )
    
    # Initialize DeepSpeed engine
    model_engine, optimizer, _, lr_scheduler = deepspeed.initialize(
        model=model,
        model_parameters=model.parameters(),
        config_params=args.deepspeed_config
    )
    
    if global_rank == 0:
        logger.info("Initialized DeepSpeed engine")
    
    total_steps = 0
    start_batch_index = 0
    
    # Auto-resume from latest checkpoint if available
    if args.resume_from_checkpoint:
        checkpoint_path = args.resume_from_checkpoint
    else:
        # Check for DeepSpeed latest checkpoint
        import os
        latest_file = os.path.join(args.checkpoint_dir, "latest")
        if os.path.exists(latest_file):
            with open(latest_file, 'r') as f:
                checkpoint_name = f.read().strip()
            checkpoint_path = args.checkpoint_dir
            if global_rank == 0:
                logger.info(f"Found existing checkpoint: {checkpoint_name}")
        else:
            checkpoint_path = None
    
    if checkpoint_path:
        # Load DeepSpeed checkpoint (tag=None means use latest file)
        _, client_state = model_engine.load_checkpoint(checkpoint_path, tag=None)
        if client_state:
            total_steps = client_state.get('total_steps', 0)
            start_batch_index = client_state.get('start_batch_index', 0)
            if global_rank == 0:
                logger.info(f"Resumed from checkpoint at step {total_steps}")
        else:
            if global_rank == 0:
                logger.info("No client state found in checkpoint")
    
    train(
        model_engine,
        train_dataloader,
        val_dataloader,
        model_config,
        num_params,
        args,
        global_rank,
        world_size,
        total_steps,
        start_batch_index
    )
    
    dist.destroy_process_group()


if __name__ == "__main__":
    args, _ = parse_args()
    main(args)
