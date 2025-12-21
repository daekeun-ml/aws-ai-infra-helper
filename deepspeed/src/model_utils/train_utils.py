import os
import torch
from torch.utils.data import DataLoader, IterableDataset
from datasets import load_dataset, load_from_disk
from transformers import AutoTokenizer, LlamaConfig
import logging

logger = logging.getLogger(__name__)


class ConcatTokensDataset(IterableDataset):
    def __init__(self, dataset, tokenizer, max_length=2048):
        self.dataset = dataset
        self.tokenizer = tokenizer
        self.max_length = max_length
        
    def __iter__(self):
        for item in self.dataset:
            if isinstance(item, dict) and 'text' in item:
                text = item['text']
            else:
                text = str(item)
            
            # Skip empty or very short texts
            if not text or len(text.strip()) < 10:
                continue
                
            tokens = self.tokenizer(
                text,
                truncation=True,
                padding='max_length',
                max_length=self.max_length,
                return_tensors="pt"
            )
            
            # Ensure we have valid tokens
            if tokens.input_ids.numel() > 0:
                yield tokens.input_ids.squeeze(0)


def get_model_config(args):
    """Create model configuration."""
    config = LlamaConfig(
        vocab_size=args.vocab_size,
        hidden_size=args.hidden_size,
        intermediate_size=args.intermediate_size,
        num_hidden_layers=args.num_hidden_layers,
        num_attention_heads=args.num_attention_heads,
        num_key_value_heads=args.num_key_value_heads,
        max_position_embeddings=args.max_position_embeddings,
        rms_norm_eps=args.rms_norm_eps,
        rope_theta=args.rope_theta,
        tie_word_embeddings=False,
    )
    return config


def compute_num_params(model):
    """Compute total number of parameters."""
    return sum(p.numel() for p in model.parameters())


def get_learning_rate_scheduler(optimizer, args):
    """Create learning rate scheduler."""
    from torch.optim.lr_scheduler import LinearLR
    return LinearLR(optimizer, start_factor=0.1, total_iters=args.warmup_steps)


def create_streaming_dataloader(dataset_name, tokenizer_name, name=None, batch_size=32, split='train', local_dataset=False):
    """Create streaming dataloader."""
    print(f"DEBUG: dataset_name={dataset_name}, name={name}, local_dataset={local_dataset}")
    tokenizer = AutoTokenizer.from_pretrained(tokenizer_name)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    
    if local_dataset:
        dataset = load_from_disk(dataset_name)[split]
    else:
        dataset = load_dataset(dataset_name, name=name, split=split, streaming=True)
    
    concat_dataset = ConcatTokensDataset(dataset, tokenizer)
    
    return DataLoader(
        concat_dataset,
        batch_size=batch_size,
        shuffle=False,  # Can't shuffle streaming datasets
        num_workers=0,
        pin_memory=True
    )
