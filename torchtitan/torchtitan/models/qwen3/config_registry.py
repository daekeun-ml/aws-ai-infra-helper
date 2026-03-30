# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree.

from torchtitan.components.checkpoint import CheckpointManager
from torchtitan.components.lr_scheduler import LRSchedulersContainer
from torchtitan.components.metrics import MetricsProcessor
from torchtitan.components.optimizer import OptimizersContainer
from torchtitan.components.quantization.float8 import (
    Float8GroupedMMConverter,
    Float8LinearConverter,
)
from torchtitan.components.quantization.mx import MXFP8Converter, MXLinearConverter
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


def qwen3_debugmodel() -> Trainer.Config:
    return Trainer.Config(
        hf_assets_path="./tests/assets/tokenizer",
        metrics=MetricsProcessor.Config(log_freq=1),
        model_spec=model_registry("debugmodel"),
        dataloader=HuggingFaceTextDataLoader.Config(dataset="c4_test"),
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
        checkpoint=CheckpointManager.Config(
            interval=10,
            last_save_model_only=False,
        ),
        activation_checkpoint=ActivationCheckpointConfig(
            mode="selective",
        ),
    )


def qwen3_debugmodel_flex() -> Trainer.Config:
    return Trainer.Config(
        hf_assets_path="./tests/assets/tokenizer",
        metrics=MetricsProcessor.Config(log_freq=1),
        model_spec=model_registry("debugmodel_flex"),
        dataloader=HuggingFaceTextDataLoader.Config(dataset="c4_test"),
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
        checkpoint=CheckpointManager.Config(
            interval=10,
            last_save_model_only=False,
        ),
        activation_checkpoint=ActivationCheckpointConfig(
            mode="selective",
        ),
    )


def qwen3_0_6b() -> Trainer.Config:
    return Trainer.Config(
        hf_assets_path="./assets/hf/Qwen3-0.6B",
        metrics=MetricsProcessor.Config(log_freq=1),
        model_spec=model_registry("0.6B"),
        dataloader=HuggingFaceTextDataLoader.Config(
            dataset="c4",
        ),
        optimizer=OptimizersContainer.Config(lr=3e-4),
        lr_scheduler=LRSchedulersContainer.Config(warmup_steps=2),
        training=TrainingConfig(
            local_batch_size=4,
            seq_len=4096,
            steps=10,
        ),
        checkpoint=CheckpointManager.Config(
            interval=500,
            last_save_model_only=False,
            export_dtype="float16",
        ),
        activation_checkpoint=ActivationCheckpointConfig(
            mode="selective",
        ),
    )


def qwen3_1_7b() -> Trainer.Config:
    return Trainer.Config(
        hf_assets_path="./assets/hf/Qwen3-1.7B",
        model_spec=model_registry("1.7B"),
        dataloader=HuggingFaceTextDataLoader.Config(
            dataset="c4",
        ),
        optimizer=OptimizersContainer.Config(lr=8e-4),
        lr_scheduler=LRSchedulersContainer.Config(warmup_steps=20),
        training=TrainingConfig(
            local_batch_size=4,
            seq_len=4096,
            steps=100,
        ),
        checkpoint=CheckpointManager.Config(
            interval=50,
            last_save_model_only=False,
            export_dtype="float16",
        ),
        activation_checkpoint=ActivationCheckpointConfig(
            mode="selective",
        ),
    )


def qwen3_14b() -> Trainer.Config:
    return Trainer.Config(
        hf_assets_path="./assets/hf/Qwen3-14B",
        model_spec=model_registry("14B"),
        dataloader=HuggingFaceTextDataLoader.Config(
            dataset="c4",
        ),
        optimizer=OptimizersContainer.Config(lr=8e-4),
        lr_scheduler=LRSchedulersContainer.Config(warmup_steps=600),
        training=TrainingConfig(
            local_batch_size=4,
            seq_len=4096,
            steps=3000,
        ),
        parallelism=ParallelismConfig(
            data_parallel_shard_degree=-1,
            tensor_parallel_degree=1,
            context_parallel_degree=1,
            pipeline_parallel_degree=1,
        ),
        checkpoint=CheckpointManager.Config(
            interval=500,
            last_save_model_only=False,
            export_dtype="float16",
        ),
        activation_checkpoint=ActivationCheckpointConfig(
            mode="full",
        ),
    )


def qwen3_32b() -> Trainer.Config:
    return Trainer.Config(
        hf_assets_path="./assets/hf/Qwen3-32B",
        model_spec=model_registry("32B"),
        dataloader=HuggingFaceTextDataLoader.Config(
            dataset="c4",
        ),
        optimizer=OptimizersContainer.Config(lr=8e-4),
        lr_scheduler=LRSchedulersContainer.Config(warmup_steps=600),
        training=TrainingConfig(
            local_batch_size=2,
            seq_len=4096,
            steps=3000,
        ),
        parallelism=ParallelismConfig(
            data_parallel_shard_degree=-1,
            tensor_parallel_degree=1,
            context_parallel_degree=1,
            pipeline_parallel_degree=1,
        ),
        checkpoint=CheckpointManager.Config(
            interval=500,
            last_save_model_only=False,
            export_dtype="float16",
        ),
        activation_checkpoint=ActivationCheckpointConfig(
            mode="full",
        ),
    )


def qwen3_30b_a3b() -> Trainer.Config:
    return Trainer.Config(
        hf_assets_path="./assets/hf/Qwen3-30B-A3B",
        model_spec=model_registry("30B-A3B"),
        dataloader=HuggingFaceTextDataLoader.Config(dataset="c4"),
        optimizer=OptimizersContainer.Config(lr=3e-4),
        lr_scheduler=LRSchedulersContainer.Config(
            warmup_steps=2000,
            decay_ratio=0.8,
            decay_type="cosine",
            min_lr_factor=0.1,
        ),
        training=TrainingConfig(
            local_batch_size=1,
            seq_len=8192,
            steps=10000,
        ),
        parallelism=ParallelismConfig(
            expert_parallel_degree=1,
            expert_tensor_parallel_degree=1,
        ),
        checkpoint=CheckpointManager.Config(
            interval=500,
            last_save_model_only=False,
            export_dtype="bfloat16",
        ),
        activation_checkpoint=ActivationCheckpointConfig(mode="full"),
    )


def qwen3_30b_a3b_nemo_h100() -> Trainer.Config:
    """Qwen3-30B-A3B config matching NeMo DGX-H100 performance benchmark.

    Reference: https://docs.nvidia.com/nemo/megatron-bridge/latest/performance-summary.html
    NeMo settings: TP=1, PP=2, CP=1, EP=8, FSDP=0, seq_len=4096, GBS=512, MBS=2,
    VP=24 (Interleaved1F1B, 1 layer/stage), FP8-CS. Requires 2 nodes (16 GPUs).

    TorchTitan EP is a separate mesh dimension from DP, so with EP=8 and PP=2 across
    16 GPUs, DP=1 (16 / (EP=8 × PP=2) = 1). NeMo's GA=32 assumes EP shares DP ranks
    (NeMo DP=8); in TorchTitan the pipeline schedule splits local_batch_size=512 into
    256 microbatches of MBS=2 each, achieving the same GBS=512.
    VP=24 → pipeline_parallel_layers_per_stage=1 (48 layers / (PP=2 × VP=24) = 1).
    """
    return Trainer.Config(
        hf_assets_path="./assets/hf/Qwen3-30B-A3B",
        profiling=ProfilingConfig(
            enable_profiling=True,
            profile_freq=100,
        ),
        metrics=MetricsProcessor.Config(
            enable_tensorboard=True,
        ),
        model_spec=model_registry("30B-A3B"),
        optimizer=OptimizersContainer.Config(lr=3e-4),
        lr_scheduler=LRSchedulersContainer.Config(
            warmup_steps=2000,
            decay_ratio=0.8,
            decay_type="cosine",
            min_lr_factor=0.1,
        ),
        training=TrainingConfig(
            # DP=1; GBS=512 = local_batch_size=512 / MBS=2 = 256 pipeline microbatches
            local_batch_size=512,
            seq_len=4096,
            steps=1000,
        ),
        dataloader=HuggingFaceTextDataLoader.Config(dataset="c4"),
        parallelism=ParallelismConfig(
            data_parallel_shard_degree=1,
            data_parallel_replicate_degree=1,
            tensor_parallel_degree=1,
            pipeline_parallel_degree=2,            # PP=2 across 2 nodes
            pipeline_parallel_schedule="Interleaved1F1B",
            pipeline_parallel_layers_per_stage=1,  # VP=24: 48 layers / 48 stages = 1
            pipeline_parallel_microbatch_size=2,   # MBS=2
            context_parallel_degree=1,
            expert_parallel_degree=8,              # EP=8
            expert_tensor_parallel_degree=1,
        ),
        # FP8-CS: rowwise for dense (excl. output proj and router gate),
        # FP8 grouped MM for MoE routed experts.
        model_converters=ModelConvertersContainer.Config(
            converters=[
                Float8LinearConverter.Config(
                    recipe_name="rowwise",
                    filter_fqns=["output", "router.gate"],
                ),
                Float8GroupedMMConverter.Config(fqns=["experts"]),
            ],
        ),
        compile=CompileConfig(enable=True),
        activation_checkpoint=ActivationCheckpointConfig(mode="selective"),
        checkpoint=CheckpointManager.Config(interval=500),
        validator=None,
    )


def qwen3_30b_a3b_nemo_b200() -> Trainer.Config:
    """Qwen3-30B-A3B config matching NeMo DGX-B200 performance benchmark.

    Reference: https://docs.nvidia.com/nemo/megatron-bridge/latest/performance-summary.html
    NeMo settings: TP=1, PP=1, CP=1, EP=8, FSDP=0, seq_len=4096, GBS=512, MBS=4,
    MXFP8. Runs on 1 node (8 GPUs).
    Expected: 26,373 tokens/sec/GPU.

    TorchTitan EP is a separate mesh dimension from DP, so with EP=8 across 8 GPUs,
    DP=1. NeMo's GA=16 assumes EP shares DP ranks (NeMo DP=8); in TorchTitan DP=1
    global_batch_size=512 is used to achieve GBS=512 (MBS=4 × GA=128 × DP=1).
    """
    return Trainer.Config(
        hf_assets_path="./assets/hf/Qwen3-30B-A3B",
        profiling=ProfilingConfig(
            enable_profiling=True,
            profile_freq=100,
        ),
        metrics=MetricsProcessor.Config(
            enable_tensorboard=True,
        ),
        model_spec=model_registry("30B-A3B"),
        optimizer=OptimizersContainer.Config(lr=3e-4),
        lr_scheduler=LRSchedulersContainer.Config(
            warmup_steps=2000,
            decay_ratio=0.8,
            decay_type="cosine",
            min_lr_factor=0.1,
        ),
        training=TrainingConfig(
            local_batch_size=4,               # MBS=4
            global_batch_size=512,            # GBS=512; 4 × GA=128 × DP=1
            seq_len=4096,
            steps=1000,
        ),
        dataloader=HuggingFaceTextDataLoader.Config(dataset="c4"),
        parallelism=ParallelismConfig(
            data_parallel_shard_degree=1,
            data_parallel_replicate_degree=1,
            tensor_parallel_degree=1,
            pipeline_parallel_degree=1,
            context_parallel_degree=1,
            expert_parallel_degree=8,              # 128 experts / 8 GPUs = 16 per GPU
            expert_tensor_parallel_degree=1,
        ),
        # MXFP8: cuBLAS microscaling for dense (excl. output proj and router gate),
        # MXFP8 grouped MM for MoE routed experts.
        model_converters=ModelConvertersContainer.Config(
            converters=[
                MXLinearConverter.Config(
                    recipe_name="mxfp8_cublas",
                    filter_fqns=["output", "router.gate"],
                ),
                MXFP8Converter.Config(fqns=["experts"]),
            ],
        ),
        compile=CompileConfig(enable=True),
        activation_checkpoint=ActivationCheckpointConfig(mode="selective"),
        checkpoint=CheckpointManager.Config(interval=500),
        validator=None,
    )


def qwen3_30b_a3b_nemo_h100_1node() -> Trainer.Config:
    """Qwen3-30B-A3B single-node H100 config: same topology as B200 but with FP8-CS.

    Same parallelism as B200 (EP=8, PP=1, TP=1, DP=1 on 8 GPUs) and same batch config
    (MBS=4, GBS=512), but uses FP8-CS (torchao rowwise) instead of MXFP8.
    """
    return Trainer.Config(
        hf_assets_path="./assets/hf/Qwen3-30B-A3B",
        profiling=ProfilingConfig(
            enable_profiling=True,
            profile_freq=100,
        ),
        metrics=MetricsProcessor.Config(
            enable_tensorboard=True,
        ),
        model_spec=model_registry("30B-A3B"),
        optimizer=OptimizersContainer.Config(lr=3e-4),
        lr_scheduler=LRSchedulersContainer.Config(
            warmup_steps=2000,
            decay_ratio=0.8,
            decay_type="cosine",
            min_lr_factor=0.1,
        ),
        training=TrainingConfig(
            local_batch_size=4,               # MBS=4
            global_batch_size=512,            # GBS=512; 4 × GA=128 × DP=1
            seq_len=4096,
            steps=1000,
        ),
        dataloader=HuggingFaceTextDataLoader.Config(dataset="c4"),
        parallelism=ParallelismConfig(
            data_parallel_shard_degree=1,
            data_parallel_replicate_degree=1,
            tensor_parallel_degree=1,
            pipeline_parallel_degree=1,
            context_parallel_degree=1,
            expert_parallel_degree=8,
            expert_tensor_parallel_degree=1,
        ),
        # FP8-CS: rowwise for dense (excl. output proj and router gate),
        # FP8 grouped MM for MoE routed experts.
        model_converters=ModelConvertersContainer.Config(
            converters=[
                Float8LinearConverter.Config(
                    recipe_name="rowwise",
                    filter_fqns=["output", "router.gate"],
                ),
                Float8GroupedMMConverter.Config(fqns=["experts"]),
            ],
        ),
        compile=CompileConfig(enable=True),
        activation_checkpoint=ActivationCheckpointConfig(mode="selective"),
        checkpoint=CheckpointManager.Config(interval=500),
        validator=None,
    )


def qwen3_235b_a22b() -> Trainer.Config:
    return Trainer.Config(
        hf_assets_path="./assets/hf/Qwen3-235B-A22B",
        model_spec=model_registry("235B-A22B"),
        dataloader=HuggingFaceTextDataLoader.Config(dataset="c4"),
        optimizer=OptimizersContainer.Config(lr=1e-4),
        lr_scheduler=LRSchedulersContainer.Config(
            warmup_steps=2000,
            decay_ratio=0.8,
            decay_type="cosine",
            min_lr_factor=0.1,
        ),
        training=TrainingConfig(
            local_batch_size=1,
            seq_len=4096,
            steps=10000,
        ),
        parallelism=ParallelismConfig(
            expert_parallel_degree=1,
            expert_tensor_parallel_degree=1,
        ),
        checkpoint=CheckpointManager.Config(
            interval=500,
            last_save_model_only=False,
            export_dtype="bfloat16",
        ),
        activation_checkpoint=ActivationCheckpointConfig(mode="full"),
    )


def qwen3_moe_debug() -> Trainer.Config:
    return Trainer.Config(
        hf_assets_path="./tests/assets/tokenizer",
        metrics=MetricsProcessor.Config(log_freq=1),
        model_spec=model_registry("debugmodel_moe"),
        dataloader=HuggingFaceTextDataLoader.Config(
            dataset="c4_test",
        ),
        optimizer=OptimizersContainer.Config(lr=3e-4),
        lr_scheduler=LRSchedulersContainer.Config(warmup_steps=2),
        training=TrainingConfig(
            local_batch_size=4,
            seq_len=4096,
            steps=10,
        ),
        parallelism=ParallelismConfig(
            expert_parallel_degree=1,
            expert_tensor_parallel_degree=1,
        ),
        checkpoint=CheckpointManager.Config(
            interval=10,
            last_save_model_only=False,
            export_dtype="float16",
        ),
        activation_checkpoint=ActivationCheckpointConfig(
            mode="selective",
        ),
    )
