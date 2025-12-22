import torch
import lightning as L
from lightning.fabric.strategies import FSDPStrategy
from transformers import AutoModelForCausalLM, AutoTokenizer
from torch.utils.data import DataLoader
from datasets import load_dataset, load_from_disk
import argparse
import os
import sys
import warnings
import glob
import time

# Suppress warnings
warnings.filterwarnings("ignore", category=FutureWarning, module="torch.distributed.fsdp")
warnings.filterwarnings("ignore", category=FutureWarning, module="torch.distributed.checkpoint")
warnings.filterwarnings("ignore", category=FutureWarning, module="torch.distributed._state_dict_utils")
# Add fsdp src to path to reuse utilities
sys.path.append('../fsdp/src')
from model_utils.concat_dataset import ConcatTokensDataset

def create_dataloader(dataset_name, dataset_config, tokenizer, batch_size, max_length, local_dataset=False):
    if local_dataset:
        data = load_from_disk(dataset_name)
        train_data = data['train']
    else:
        train_data = load_dataset(dataset_name, dataset_config, streaming=True, split='train')
    
    dataset = ConcatTokensDataset(train_data, tokenizer, max_length, wrap=True)
    return DataLoader(dataset, batch_size=batch_size, num_workers=4, pin_memory=True)

def find_latest_checkpoint(checkpoint_dir):
    if not os.path.exists(checkpoint_dir):
        return None
    
    # Check latest.txt first
    latest_file = os.path.join(checkpoint_dir, "latest.txt")
    if os.path.exists(latest_file):
        with open(latest_file, "r") as f:
            checkpoint_name = f.read().strip()
            checkpoint_path = os.path.join(checkpoint_dir, checkpoint_name)
            if os.path.exists(checkpoint_path):
                return checkpoint_name
    
    # Fallback: Look for checkpoint directories
    ckpt_dirs = []
    for item in os.listdir(checkpoint_dir):
        item_path = os.path.join(checkpoint_dir, item)
        if os.path.isdir(item_path) and item.startswith("checkpoint-"):
            ckpt_dirs.append(item)
    
    if not ckpt_dirs:
        return None
    
    # Return the most recently modified checkpoint directory name
    latest_ckpt = max(ckpt_dirs, key=lambda x: os.path.getmtime(os.path.join(checkpoint_dir, x)))
    return latest_ckpt

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--nodes', type=int, default=1)
    parser.add_argument('--gpus', type=int, default=1)
    parser.add_argument('--epochs', type=int, default=1)
    parser.add_argument('--max_steps', type=int, default=100)
    parser.add_argument('--batch_size', type=int, default=4)
    parser.add_argument('--dataset', type=str, default="wikitext")
    parser.add_argument('--dataset_config', type=str, default="wikitext-2-raw-v1")
    parser.add_argument('--model_name', type=str, default="Qwen/Qwen3-0.6B")
    parser.add_argument('--max_length', type=int, default=512)
    parser.add_argument('--learning_rate', type=float, default=5e-5)
    parser.add_argument('--local_dataset', action='store_true')
    parser.add_argument('--limit_train_batches', type=float, default=1.0)
    parser.add_argument('--val_check_interval', type=int, default=50)
    parser.add_argument('--save_every_n_steps', type=int, default=100)
    parser.add_argument('--checkpoint_dir', type=str, default="./checkpoints")
    args = parser.parse_args()
    
    # Setup Fabric with FSDP
    strategy = FSDPStrategy(state_dict_type="sharded")
    fabric = L.Fabric(
        accelerator="cuda",
        devices=args.gpus,
        num_nodes=args.nodes,
        strategy=strategy,
        precision="16-mixed"
    )
    fabric.launch()
    
    # Create model and optimizer
    with fabric.rank_zero_first():
        model = AutoModelForCausalLM.from_pretrained(args.model_name)
        tokenizer = AutoTokenizer.from_pretrained(args.model_name)
        if tokenizer.pad_token is None:
            tokenizer.pad_token = tokenizer.eos_token
    
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate)
    
    # Setup with Fabric
    model, optimizer = fabric.setup(model, optimizer)
    
    # Create dataloader
    dataloader = create_dataloader(
        args.dataset, args.dataset_config, tokenizer, 
        args.batch_size, args.max_length, args.local_dataset
    )
    dataloader = fabric.setup_dataloaders(dataloader)
    
    # Check for existing checkpoint
    os.makedirs(args.checkpoint_dir, exist_ok=True)
    latest_checkpoint = find_latest_checkpoint(args.checkpoint_dir)
    
    iteration = 0
    epoch = 0
    
    if latest_checkpoint:
        fabric.print(f"Loading checkpoint: {latest_checkpoint}")
        checkpoint_path = os.path.join(args.checkpoint_dir, latest_checkpoint)
        state = {"model": model, "optimizer": optimizer, "iteration": iteration, "epoch": epoch}
        fabric.load(checkpoint_path, state)
        iteration = state["iteration"]
        epoch = state["epoch"]
        fabric.print(f"Resumed from step {iteration}, epoch {epoch}")
        
        # Check if already completed
        if iteration >= args.max_steps:
            fabric.print(f"Training already completed at step {iteration}/{args.max_steps}")
            return
    else:
        fabric.print("No checkpoint found, starting from scratch")
    
    # Training loop
    model.train()
    step_count = iteration  # Start from loaded iteration
    max_steps = args.max_steps if args.max_steps else float('inf')
    
    # Timing variables
    start_time = time.time()
    step_times = []
    
    for current_epoch in range(epoch, args.epochs):
        if step_count >= max_steps:
            break
            
        batch_count = 0
        for batch_idx, batch in enumerate(dataloader):
            if step_count >= max_steps:
                break
            
            step_start_time = time.time()
            
            # Limit train batches
            if args.limit_train_batches < 1.0:
                if batch_count >= int(len(dataloader) * args.limit_train_batches):
                    break
            
            input_ids = batch
            labels = input_ids.clone()
            
            outputs = model(input_ids=input_ids, labels=labels)
            loss = outputs.loss
            
            fabric.backward(loss)
            
            # Calculate gradient norm (FSDP handles gradient management internally)
            total_norm = 0.0
            for p in model.parameters():
                if p.grad is not None:
                    param_norm = p.grad.data.norm(2)
                    total_norm += param_norm.item() ** 2
            grad_norm = total_norm ** (1. / 2)
            
            optimizer.step()
            optimizer.zero_grad()
            
            step_end_time = time.time()
            step_time = step_end_time - step_start_time
            step_times.append(step_time)
            
            # Keep only last 100 step times for moving average
            if len(step_times) > 100:
                step_times.pop(0)
            
            if step_count % 10 == 0:
                avg_step_time = sum(step_times) / len(step_times)
                samples_per_sec = args.batch_size / avg_step_time
                elapsed_time = time.time() - start_time
                
                fabric.print(
                    f"STEP {step_count}/{max_steps} | "
                    f"Epoch {current_epoch} | "
                    f"Loss: {loss.item():.4f} | "
                    f"Grad Norm: {grad_norm:.4f} | "
                    f"LR: {optimizer.param_groups[0]['lr']:.2e} | "
                    f"Samples/sec: {samples_per_sec:.2f} | "
                    f"Time: {elapsed_time:.1f}s"
                )
            
            # Save checkpoint
            if step_count % args.save_every_n_steps == 0 and step_count > iteration:
                checkpoint_path = os.path.join(args.checkpoint_dir, f"checkpoint-epoch-{current_epoch:02d}-step-{step_count}")
                state = {
                    "model": model, 
                    "optimizer": optimizer, 
                    "iteration": step_count,
                    "epoch": current_epoch
                }
                fabric.save(checkpoint_path, state)
                fabric.print(f"Saved checkpoint: {checkpoint_path}")
                
                # Update latest.txt
                with open(os.path.join(args.checkpoint_dir, "latest.txt"), "w") as f:
                    f.write(f"checkpoint-epoch-{current_epoch:02d}-step-{step_count}")
            
            step_count += 1
            batch_count += 1
    
    # Final checkpoint
    final_checkpoint = os.path.join(args.checkpoint_dir, f"checkpoint-epoch-{current_epoch:02d}-step-{step_count}")
    state = {"model": model, "optimizer": optimizer, "iteration": step_count, "epoch": current_epoch}
    fabric.save(final_checkpoint, state)
    fabric.print(f"Saved final checkpoint: {final_checkpoint}")
    
    # Update latest.txt for final checkpoint
    with open(os.path.join(args.checkpoint_dir, "latest.txt"), "w") as f:
        f.write(f"checkpoint-epoch-{current_epoch:02d}-step-{step_count}")

if __name__ == "__main__":
    main()
