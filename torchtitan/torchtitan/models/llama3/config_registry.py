# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree.

from torchtitan.components.checkpoint import CheckpointManager
from torchtitan.components.lr_scheduler import LRSchedulersContainer
from torchtitan.components.metrics import MetricsProcessor
from torchtitan.components.optimizer import (
    OptimizersContainer,
    OptimizersInBackwardContainer,
)
from torchtitan.components.quantization.float8 import Float8LinearConverter
from torchtitan.components.quantization.mx import MXLinearConverter
from torchtitan.components.validate import Validator
from torchtitan.config import (
    ActivationCheckpointConfig,
    CompileConfig,
    ParallelismConfig,
    TrainingConfig,
)
from torchtitan.hf_datasets.text_datasets import HuggingFaceTextDataLoader
from torchtitan.protocols.model_converter import ModelConvertersContainer
from torchtitan.tools.profiling import ProfilingConfig
from torchtitan.trainer import Trainer

from . import model_registry


def llama3_debugmodel() -> Trainer.Config:
    return Trainer.Config(
        hf_assets_path="./tests/assets/tokenizer",
        model_spec=model_registry("debugmodel"),
        optimizer=OptimizersContainer.Config(lr=8e-4),
        lr_scheduler=LRSchedulersContainer.Config(
            warmup_steps=2,
            decay_ratio=0.8,
            decay_type="linear",
            min_lr_factor=0.0,
        ),
        training=TrainingConfig(
            local_batch_size=8,
            seq_len=2048,
            steps=10,
        ),
        dataloader=HuggingFaceTextDataLoader.Config(
            dataset="c4_test",
        ),
        metrics=MetricsProcessor.Config(log_freq=1),
        parallelism=ParallelismConfig(pipeline_parallel_schedule="Interleaved1F1B"),
        checkpoint=CheckpointManager.Config(
            interval=10,
            last_save_model_only=False,
        ),
        activation_checkpoint=ActivationCheckpointConfig(
            mode="selective",
        ),
        validator=Validator.Config(
            freq=5,
            steps=10,
        ),
    )


def llama3_debugmodel_flex_attn() -> Trainer.Config:
    config = llama3_debugmodel()
    config.model_spec = model_registry("debugmodel_flex_attn")
    return config


def llama3_debugmodel_varlen_attn() -> Trainer.Config:
    config = llama3_debugmodel()
    config.model_spec = model_registry("debugmodel_varlen_attn")
    return config


def llama3_debugmodel_opt_in_bwd() -> Trainer.Config:
    config = llama3_debugmodel()
    config.optimizer = OptimizersInBackwardContainer.Config(lr=8e-4)
    return config


def llama3_debugmodel_float8() -> Trainer.Config:
    config = llama3_debugmodel()
    config.model_converters = ModelConvertersContainer.Config(
        converters=[
            Float8LinearConverter.Config(
                enable_fsdp_float8_all_gather=True,
                precompute_float8_dynamic_scale_for_fsdp=True,
            ),
        ],
    )
    return config


def llama3_debugmodel_float8_emulate() -> Trainer.Config:
    config = llama3_debugmodel()
    config.model_converters = ModelConvertersContainer.Config(
        converters=[
            Float8LinearConverter.Config(
                enable_fsdp_float8_all_gather=True,
                precompute_float8_dynamic_scale_for_fsdp=True,
                emulate=True,
            ),
        ],
    )
    return config


def llama3_8b() -> Trainer.Config:
    return Trainer.Config(
        hf_assets_path="./assets/hf/Llama-3.1-8B",
        profiling=ProfilingConfig(
            enable_profiling=True,
            profile_freq=100,
        ),
        metrics=MetricsProcessor.Config(
            enable_tensorboard=True,
        ),
        model_spec=model_registry("8B"),
        optimizer=OptimizersContainer.Config(lr=3e-4),
        training=TrainingConfig(
            local_batch_size=1,
            seq_len=8192,
            steps=1000,
        ),
        dataloader=HuggingFaceTextDataLoader.Config(
            dataset="c4",
        ),
        checkpoint=CheckpointManager.Config(interval=500),
        activation_checkpoint=ActivationCheckpointConfig(
            mode="selective",
        ),
        validator=Validator.Config(
            freq=500,
            steps=1200,
        ),
    )


def llama3_8b_nemo_h100() -> Trainer.Config:
    """Llama 3.1 8B config matching NeMo DGX-H100 performance benchmark.

    Reference: https://docs.nvidia.com/nemo/megatron-bridge/latest/performance-summary.html
    NeMo settings: FSDP=8, TP=1, PP=1, CP=1, seq_len=8192, GBS=128, MBS=1, grad_accum=16,
    FP8-CS (channelwise scaling = torchao rowwise recipe), selective AC, torch.compile.
    """
    return Trainer.Config(
        hf_assets_path="./assets/hf/Llama-3.1-8B",
        profiling=ProfilingConfig(
            enable_profiling=True,
            profile_freq=100,
        ),
        metrics=MetricsProcessor.Config(
            enable_tensorboard=True,
        ),
        model_spec=model_registry("8B"),
        optimizer=OptimizersContainer.Config(lr=3e-4),
        training=TrainingConfig(
            local_batch_size=1,               # MBS=1
            global_batch_size=128,            # GA=16; 1 × 16 × 8 GPUs = GBS 128
            seq_len=8192,
            steps=1000,
        ),
        dataloader=HuggingFaceTextDataLoader.Config(
            dataset="c4",
        ),
        parallelism=ParallelismConfig(
            data_parallel_shard_degree=8,  # FSDP=8
            tensor_parallel_degree=1,      # TP=1
            pipeline_parallel_degree=1,    # PP=1
            context_parallel_degree=1,     # CP=1
        ),
        # FP8-CS: NeMo channelwise scaling = torchao rowwise recipe
        # Note: recipe_name="rowwise" is mutually exclusive with
        # enable_fsdp_float8_all_gather; rowwise handles FSDP internally.
        model_converters=ModelConvertersContainer.Config(
            converters=[
                Float8LinearConverter.Config(recipe_name="rowwise"),
            ],
        ),
        compile=CompileConfig(enable=True),
        activation_checkpoint=ActivationCheckpointConfig(mode="selective"),
        checkpoint=CheckpointManager.Config(interval=500),
        validator=Validator.Config(
            freq=500,
            steps=1200,
        ),
    )


def llama3_8b_nemo_b200() -> Trainer.Config:
    """Llama 3.1 8B config matching NeMo DGX-B200 performance benchmark with MXFP8.

    Reference: https://docs.nvidia.com/nemo/megatron-bridge/latest/performance-summary.html
    NeMo settings: FSDP=0 (DDP), TP=1, PP=1, CP=1, seq_len=8192, GBS=128, MBS=2,
    grad_accum=8. Uses MXFP8 (microscaling FP8) via cuBLAS on SM100 (B200).
    Note: NeMo FSDP=0 means no weight sharding (DDP). B200 has 192GB HBM per GPU,
    sufficient to hold 8B model + optimizer states without sharding.
    """
    return Trainer.Config(
        hf_assets_path="./assets/hf/Llama-3.1-8B",
        profiling=ProfilingConfig(
            enable_profiling=True,
            profile_freq=100,
        ),
        metrics=MetricsProcessor.Config(
            enable_tensorboard=True,
        ),
        model_spec=model_registry("8B"),
        optimizer=OptimizersContainer.Config(lr=3e-4),
        training=TrainingConfig(
            local_batch_size=2,               # MBS=2
            global_batch_size=128,            # GA=8; 2 × 8 × 8 GPUs = GBS 128
            seq_len=8192,
            steps=1000,
        ),
        dataloader=HuggingFaceTextDataLoader.Config(
            dataset="c4",
        ),
        parallelism=ParallelismConfig(
            # NeMo FSDP=0 → DDP (no weight sharding); B200 192GB HBM fits without FSDP
            data_parallel_replicate_degree=8,
            data_parallel_shard_degree=1,
            tensor_parallel_degree=1,   # TP=1
            pipeline_parallel_degree=1, # PP=1
            context_parallel_degree=1,  # CP=1
        ),
        # MXFP8: microscaling FP8 with cuBLAS kernels native to SM100 (B200).
        # Uses 1x32 block scaling (e4m3fn data, e8m0 scale). All communication
        # in high precision (DDP allreduce in bfloat16/float32).
        model_converters=ModelConvertersContainer.Config(
            converters=[
                MXLinearConverter.Config(recipe_name="mxfp8_cublas"),
            ],
        ),
        compile=CompileConfig(enable=True),
        activation_checkpoint=ActivationCheckpointConfig(mode="selective"),
        checkpoint=CheckpointManager.Config(interval=500),
        validator=Validator.Config(
            freq=500,
            steps=1200,
        ),
    )


def llama3_70b() -> Trainer.Config:
    return Trainer.Config(
        hf_assets_path="./assets/hf/Llama-3.1-70B",
        profiling=ProfilingConfig(
            enable_profiling=True,
            profile_freq=100,
        ),
        metrics=MetricsProcessor.Config(
            enable_tensorboard=True,
        ),
        model_spec=model_registry("70B"),
        optimizer=OptimizersContainer.Config(lr=1.5e-4),
        training=TrainingConfig(
            local_batch_size=8,
            seq_len=8192,
            steps=1000,
        ),
        dataloader=HuggingFaceTextDataLoader.Config(
            dataset="c4",
        ),
        parallelism=ParallelismConfig(
            tensor_parallel_degree=8,
        ),
        checkpoint=CheckpointManager.Config(interval=500),
        activation_checkpoint=ActivationCheckpointConfig(mode="full"),
        validator=Validator.Config(
            freq=500,
            steps=1200,
        ),
    )


def llama3_405b() -> Trainer.Config:
    return Trainer.Config(
        hf_assets_path="./assets/hf/Llama-3.1-405B",
        profiling=ProfilingConfig(
            enable_profiling=True,
            profile_freq=100,
        ),
        metrics=MetricsProcessor.Config(
            enable_tensorboard=True,
        ),
        model_spec=model_registry("405B"),
        model_converters=ModelConvertersContainer.Config(
            converters=[
                Float8LinearConverter.Config(
                    enable_fsdp_float8_all_gather=True,
                    precompute_float8_dynamic_scale_for_fsdp=True,
                    filter_fqns=["output"],
                ),
            ],
        ),
        optimizer=OptimizersContainer.Config(lr=8e-5),
        lr_scheduler=LRSchedulersContainer.Config(warmup_steps=600),
        training=TrainingConfig(
            local_batch_size=2,
            seq_len=8192,
            steps=3000,
        ),
        dataloader=HuggingFaceTextDataLoader.Config(
            dataset="c4",
        ),
        parallelism=ParallelismConfig(
            tensor_parallel_degree=8,
            enable_async_tensor_parallel=True,
        ),
        checkpoint=CheckpointManager.Config(interval=500),
        activation_checkpoint=ActivationCheckpointConfig(mode="full"),
        compile=CompileConfig(enable=True),
        validator=Validator.Config(
            freq=500,
            steps=1200,
        ),
    )
