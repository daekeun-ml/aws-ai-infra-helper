import torch
import pytorch_lightning as pl
from pytorch_lightning.callbacks import ModelCheckpoint
from pytorch_lightning.strategies import FSDPStrategy
from transformers import AutoModelForCausalLM, AutoTokenizer
from torch.utils.data import DataLoader
from datasets import load_dataset, load_from_disk
import argparse
import os
import sys
import warnings
import glob



# Add fsdp src to path to reuse utilities
sys.path.append('../fsdp/src')
from model_utils.concat_dataset import ConcatTokensDataset

class LanguageModelLightningModule(pl.LightningModule):
    def __init__(self, model_name="Qwen/Qwen3-0.6B", learning_rate=5e-5):
        super().__init__()
        self.model = AutoModelForCausalLM.from_pretrained(model_name)
        self.learning_rate = learning_rate
        
    def training_step(self, batch, batch_idx):
        self.model.train()  # Ensure model is in training mode
        input_ids = batch
        labels = input_ids.clone()
        outputs = self.model(input_ids=input_ids, labels=labels)
        loss = outputs.loss
        self.log('train_loss', loss, prog_bar=True, sync_dist=True)
        return loss
    
    def validation_step(self, batch, batch_idx):
        self.model.eval()
        input_ids = batch
        labels = input_ids.clone()
        with torch.no_grad():
            outputs = self.model(input_ids=input_ids, labels=labels)
            loss = outputs.loss
        self.log('val_loss', loss, prog_bar=True, sync_dist=True)
        return loss
    
    def configure_optimizers(self):
        return torch.optim.AdamW(self.parameters(), lr=self.learning_rate)

class MyDataModule(pl.LightningDataModule):
    def __init__(self, dataset_name="wikitext", dataset_config="wikitext-2-raw-v1", 
                 tokenizer_name="Qwen/Qwen3-0.6B", batch_size=4, max_length=512,
                 num_workers=4, local_dataset=False):
        super().__init__()
        self.dataset_name = dataset_name
        self.dataset_config = dataset_config
        self.tokenizer_name = tokenizer_name
        self.batch_size = batch_size
        self.max_length = max_length
        self.num_workers = num_workers
        self.local_dataset = local_dataset
        
    def setup(self, stage=None):
        self.tokenizer = AutoTokenizer.from_pretrained(self.tokenizer_name)
        if self.tokenizer.pad_token is None:
            self.tokenizer.pad_token = self.tokenizer.eos_token
            
        if self.local_dataset:
            data = load_from_disk(self.dataset_name)
            train_data = data['train']
            val_data = data.get('validation', data['train'])  # Use train if no validation
        else:
            train_data = load_dataset(self.dataset_name, self.dataset_config, 
                                    streaming=True, split='train')
            try:
                val_data = load_dataset(self.dataset_name, self.dataset_config,
                                      streaming=True, split='validation')
            except:
                val_data = train_data  # Use train data if no validation split
            
        self.train_dataset = ConcatTokensDataset(
            train_data, self.tokenizer, self.max_length, wrap=True
        )
        self.val_dataset = ConcatTokensDataset(
            val_data, self.tokenizer, self.max_length, wrap=True
        )
    
    def train_dataloader(self):
        return DataLoader(
            self.train_dataset,
            batch_size=self.batch_size,
            num_workers=self.num_workers,
            pin_memory=True,
            prefetch_factor=4
        )
    
    def val_dataloader(self):
        return DataLoader(
            self.val_dataset,
            batch_size=self.batch_size,
            num_workers=self.num_workers,
            pin_memory=True,
            prefetch_factor=4
        )

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
    
    # Find latest checkpoint
    def find_latest_checkpoint(checkpoint_dir):
        if not os.path.exists(checkpoint_dir):
            return None
        
        # Check latest.txt first
        latest_file = os.path.join(checkpoint_dir, "latest.txt")
        if os.path.exists(latest_file):
            with open(latest_file, "r") as f:
                checkpoint_name = f.read().strip()
                checkpoint_path = os.path.join(checkpoint_dir, checkpoint_name + ".ckpt")
                if os.path.exists(checkpoint_path):
                    return checkpoint_path
        
        # Fallback: Look for .ckpt files
        ckpt_files = glob.glob(os.path.join(checkpoint_dir, "*.ckpt"))
        if not ckpt_files:
            return None
        latest_ckpt = max(ckpt_files, key=os.path.getmtime)
        return latest_ckpt
    
    # Check for existing checkpoint
    latest_checkpoint = find_latest_checkpoint(args.checkpoint_dir)
    if latest_checkpoint:
        print(f"Found checkpoint: {latest_checkpoint}")
        
        # For Lightning, check if max_steps is already reached
        if args.max_steps:
            # Extract step number from checkpoint filename
            import re
            step_match = re.search(r'step=(\d+)', latest_checkpoint)
            if step_match:
                checkpoint_step = int(step_match.group(1))
                if checkpoint_step >= args.max_steps:
                    print(f"Training already completed at step {checkpoint_step}/{args.max_steps}")
                    return
    else:
        print("No checkpoint found, starting from scratch")
    
    # Data module
    data_module = MyDataModule(
        dataset_name=args.dataset,
        dataset_config=args.dataset_config,
        tokenizer_name=args.model_name,
        batch_size=args.batch_size,
        max_length=args.max_length,
        local_dataset=args.local_dataset
    )
    
    # Model
    model = LanguageModelLightningModule(
        model_name=args.model_name,
        learning_rate=args.learning_rate
    )
    
    # Checkpoint callback - distributed checkpointing with FSDP
    checkpoint_callback = ModelCheckpoint(
        dirpath=args.checkpoint_dir,
        filename='checkpoint-{epoch:02d}-{step}',
        every_n_train_steps=args.save_every_n_steps,
        save_top_k=-1,  # Save all checkpoints
        verbose=True
    )
    
    # FSDP strategy for distributed checkpointing
    strategy = FSDPStrategy(
        state_dict_type="sharded",  # Enable distributed/sharded checkpoints
        auto_wrap_policy=None,  # Let Lightning handle wrapping
    )
    
    # Trainer
    trainer = pl.Trainer(
        max_epochs=args.epochs if args.max_steps is None else None,
        max_steps=args.max_steps,
        limit_train_batches=args.limit_train_batches,
        devices=args.gpus,
        num_nodes=args.nodes,
        strategy=strategy,  # Use FSDP strategy
        precision='16-mixed',
        log_every_n_steps=10,
        val_check_interval=args.val_check_interval,
        limit_val_batches=10,  # Fixed number of validation batches
        callbacks=[checkpoint_callback],
        enable_progress_bar=True,
        enable_model_summary=False,
        sync_batchnorm=False,  # Disable sync batchnorm
        use_distributed_sampler=True
        # gradient_clip_val=1.0  # Not supported with FSDP
    )
    
    trainer.fit(model, data_module, ckpt_path=latest_checkpoint)

if __name__ == "__main__":
    main()
