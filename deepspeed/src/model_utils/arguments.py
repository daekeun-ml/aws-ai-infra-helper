import argparse


def parse_args():
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(description="DeepSpeed Training")
    
    # Model configuration
    parser.add_argument("--model_type", type=str, default="qwen3_0_6b")
    parser.add_argument("--tokenizer", type=str, default="Qwen/Qwen3-0.6B")
    parser.add_argument("--vocab_size", type=int, default=151936)
    parser.add_argument("--hidden_size", type=int, default=1024)
    parser.add_argument("--intermediate_size", type=int, default=3072)
    parser.add_argument("--num_hidden_layers", type=int, default=28)
    parser.add_argument("--num_attention_heads", type=int, default=16)
    parser.add_argument("--num_key_value_heads", type=int, default=8)
    parser.add_argument("--max_position_embeddings", type=int, default=40960)
    parser.add_argument("--rms_norm_eps", type=float, default=1e-6)
    parser.add_argument("--rope_theta", type=float, default=1000000)
    
    # Dataset configuration
    parser.add_argument("--dataset", type=str, default="/fsx/data/wikitext-2")
    parser.add_argument("--dataset_config_name", type=str, default="en")
    parser.add_argument("--local_dataset", action="store_true", default=False)
    
    # Training configuration
    parser.add_argument("--train_batch_size", type=int, default=32)
    parser.add_argument("--train_micro_batch_size_per_gpu", type=int, default=1)
    parser.add_argument("--gradient_accumulation_steps", type=int, default=1)
    parser.add_argument("--learning_rate", type=float, default=5e-5)
    parser.add_argument("--max_steps", type=int, default=1000)
    parser.add_argument("--epochs", type=int, default=1)
    parser.add_argument("--logging_freq", type=int, default=10)
    parser.add_argument("--validation_freq", type=int, default=100)
    parser.add_argument("--validation_batches", type=int, default=10)
    parser.add_argument("--checkpoint_freq", type=int, default=500)
    parser.add_argument("--checkpoint_dir", type=str, default="checkpoints")
    
    # Optimization
    parser.add_argument("--beta1", type=float, default=0.9)
    parser.add_argument("--beta2", type=float, default=0.95)
    parser.add_argument("--weight_decay", type=float, default=0.1)
    parser.add_argument("--grad_clip", type=float, default=1.0)
    parser.add_argument("--warmup_steps", type=int, default=100)
    
    # Mixed precision
    parser.add_argument("--bf16", action="store_true", default=False)
    
    # DeepSpeed
    parser.add_argument("--deepspeed_config", type=str, default="ds_config.json")
    parser.add_argument("--resume_from_checkpoint", type=str, default=None)
    
    # DeepSpeed arguments
    parser.add_argument("--local_rank", type=int, default=-1)
    
    return parser.parse_known_args()
