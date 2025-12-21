import os
import torch
import logging

logger = logging.getLogger(__name__)


def save_checkpoint(model, optimizer, lr_scheduler, user_content, checkpoint_dir, sub_dir):
    """Save checkpoint (placeholder for DeepSpeed compatibility)."""
    pass


def load_checkpoint(model, optimizer, lr_scheduler, checkpoint_path, model_type, device):
    """Load checkpoint (placeholder for DeepSpeed compatibility)."""
    return model, optimizer, lr_scheduler, 0, 0
