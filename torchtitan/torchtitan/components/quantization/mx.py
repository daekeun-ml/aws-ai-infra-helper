# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree.

from dataclasses import dataclass, field
from functools import partial
from importlib.util import find_spec
from typing import ClassVar, Literal

import torch.nn as nn
from torchtitan.components.quantization import QuantizationConverter

from torchtitan.distributed import ParallelDims
from torchtitan.models.common.linear import Linear
from torchtitan.tools.logging import logger
from torchtitan.tools.utils import has_cuda_capability

from .module_utils import (
    capture_module_attrs,
    inject_module_protocol,
    verify_module_protocol,
)
from .utils import module_filter_fn


class MXLinearConverter(QuantizationConverter):
    """
    Converts nn.Linear layers to use MXFP8 (microscaling FP8) dynamic quantization
    via torchao's MXLinearConfig. Designed for SM100 (B200) hardware where cuBLAS
    natively supports MXFP8 GEMMs with 1x32 block-scaled formats.

    All distributed communication (FSDP, DDP, TP) is performed in high precision.
    """

    @dataclass(kw_only=True, slots=True)
    class Config(QuantizationConverter.Config):
        _quantization_type: ClassVar[str] = "mxfp8"

        recipe_name: Literal[
            "mxfp8_cublas", "mxfp8_cublas_rceil", "mxfp8_emulated"
        ] = "mxfp8_cublas"
        """
        MXFP8 recipe for dense linear layers. Options:

        - mxfp8_cublas: MXFP8 with cuBLAS kernels (SM100/B200, highest performance).
        - mxfp8_cublas_rceil: Same as mxfp8_cublas but uses RCEIL rounding for
          e8m0 scale factor computation (consistent with mxfp8_rceil MoE recipe).
        - mxfp8_emulated: Software emulation for testing on SM89+ (no SM100 required).
          Not suitable for production use; use with torch.compile disabled.
        """

        filter_fqns: list[str] = field(default_factory=list)
        """
        List of fully qualified names of modules to skip when applying MXFP8 conversion.
        nn.Linear modules with any dim size not divisible by 16 are always skipped.
        Example: filter_fqns=["output", "router.gate"]
        """

    def __init__(
        self,
        config: Config,
        *,
        parallel_dims: ParallelDims,
        model_compile_enabled: bool,
    ):
        self.enabled = False

        if find_spec("torchao") is None:
            raise ImportError(
                "torchao is not installed. Please install it to use MXFP8 linear layers."
            )

        try:
            from torchao.prototype.mx_formats import MXLinearConfig  # noqa: F401
        except ImportError as e:
            raise ImportError(
                "torchao installation does not have MX formats support. "
                "Please install torchao 0.16.0 or later."
            ) from e

        if config.recipe_name == "mxfp8_emulated":
            if not has_cuda_capability(8, 9):
                raise ValueError(
                    "MXFP8 emulated mode requires SM89 or later for float8 support."
                )
        else:
            if not has_cuda_capability(10, 0):
                raise ValueError(
                    f"MXFP8 recipe '{config.recipe_name}' requires SM100 (B200) or later. "
                    "Use recipe_name='mxfp8_emulated' for testing on older hardware."
                )

        if not model_compile_enabled:
            logger.warning(
                "torch.compile is recommended for highest performance of MXFP8 linear layers."
            )

        self.config = config
        self.filter_fn = partial(module_filter_fn, filter_fqns=config.filter_fqns)
        self.enabled = True
        logger.info(f"MXFP8 linear training enabled with recipe '{config.recipe_name}'")

    def convert(self, model: nn.Module):
        """
        Mutates the model inplace replacing nn.Linear instances with MXLinear layers
        that perform dynamic MXFP8 quantization using 1x32 block scaling.
        """
        if not self.enabled:
            return

        from torchao.prototype.mx_formats import MXLinearConfig, MXLinearRecipeName
        from torchao.quantization.quant_api import quantize_

        # Capture Module attrs before conversion (MX may swap classes, losing them).
        verify_module_protocol(model, nn.Linear, Linear)
        saved_attrs = capture_module_attrs(
            model, ["_init_mean", "_init_std"], nn_module_cls=nn.Linear
        )

        mx_config = MXLinearConfig.from_recipe_name(
            MXLinearRecipeName(self.config.recipe_name)
        )
        quantize_(model, config=mx_config, filter_fn=self.filter_fn)

        # Re-inject Linear protocol and re-attach attrs lost during conversion
        inject_module_protocol(model, Linear, saved_attrs)
        verify_module_protocol(model, nn.Linear, Linear)

        logger.info(
            f"Converted Linear layers to MXFP8 with recipe '{self.config.recipe_name}'"
        )

    def post_optimizer_hook(self, model: nn.Module | list[nn.Module]):
        pass


class MXFP8Converter(QuantizationConverter):
    """
    Wraps the weight tensors of target nn.Linears or 3D nn.Parameters with a tensor subclass
    that overrides grouped_mm and linear ops, dispatching to autograd functions that implement
    dynamic quantization and MXFP8 grouped_m/linear ops, based on the given config.
    """

    @dataclass(kw_only=True, slots=True)
    class Config(QuantizationConverter.Config):
        _quantization_type: ClassVar[str] = "mxfp8"
        # Note: __name__ is set to "MXFP8ConverterConfig" below the class body
        # to avoid a tyro subcommand naming collision with MXLinearConverter.Config.

        recipe_name: Literal["mxfp8_rceil"] = "mxfp8_rceil"
        """
        Quantization recipe name for grouped GEMMs. Options: ["mxfp8_rceil"]

        - mxfp8_rceil: MXFP8 dynamic quantization with RCEIL rounding mode when computing the e8m0 scale factors.
        """

        fqns: list[str] = field(default_factory=list)
        """
        *Prototype feature, performance optimization still in progress*
        Comma-separated list of fully qualified names of MoE modules to apply MXFP8 dynamic quantization
        on grouped GEMM operations.
        This is a prototype feature that requires the torchao nightly build.
        """

        pad_token_groups_for_grouped_mm: bool = True
        """
        Boolean indicating if token group sizes should be padded to multiple of 32 (MXFP8 scaling block size)
        for compatibility with quantization kernels. Default is true.

        If using HybridEP, set to false. HybridEP automatically performs this padding as part of the
        all-to-all dispatch step, so running the padding/unpadding kernels would incur unnecessary extra overhead.
        """

    def __init__(
        self,
        config: Config,
        *,
        parallel_dims: ParallelDims,
        model_compile_enabled: bool,
    ):
        self.enabled = False

        # Ensure minimum torchao versions
        if find_spec("torchao") is None:
            raise ImportError(
                "torchao is not installed. Please install it to use MXFP8 linear layers."
            )

        # Can be removed if we enable the emulated versions
        assert has_cuda_capability(
            10, 0
        ), "MXFP8 is only supported on SM100 or architectures"

        # Warn user if torch.compile is not enabled
        if not model_compile_enabled:
            logger.warning(
                "torch.compile enablement is required for highest performance of MXFP8 dynamic quantization."
            )

        self.config = config
        self.enabled = True
        logger.info("MXFP8 MoE training enabled")

    def convert(self, model: nn.Module):
        """
        Mutates the model inplace replacing instances of nn.Parameter with ScaledGroupedMMTensor.
        This will use low precision grouped GEMMs with dynamic quantization using the specified MX dtype,
        rather than the default high precision grouped GEMMs, for the target MoE FQNs.
        """
        if not self.enabled:
            return

        from torchao.prototype.moe_training.config import (
            MXFP8TrainingOpConfig,
            MXFP8TrainingRecipe,
        )
        from torchao.quantization.quant_api import quantize_

        def module_filter_fn(mod: nn.Module, cur_fqn: str) -> bool:
            for target_fqn in self.config.fqns:
                if target_fqn in cur_fqn:
                    return True
            return False

        # Capture Module attrs before conversion (MX may swap classes, losing them).
        # We need to first verify if all nn.Linear have been converted to Linear.
        verify_module_protocol(model, nn.Linear, Linear)
        saved_attrs = capture_module_attrs(
            model, ["_init_mean", "_init_std"], nn_module_cls=nn.Linear
        )

        recipe = MXFP8TrainingRecipe(self.config.recipe_name)
        mxfp8_op_config = MXFP8TrainingOpConfig.from_recipe(recipe)
        mxfp8_op_config.pad_token_groups_for_grouped_mm = (
            self.config.pad_token_groups_for_grouped_mm
        )

        quantize_(model, config=mxfp8_op_config, filter_fn=module_filter_fn)

        # Re-inject Linear protocol and re-attach attrs
        inject_module_protocol(model, Linear, saved_attrs)
        verify_module_protocol(model, nn.Linear, Linear)

        logger.info(
            f"Converted layers matching FQNS {self.config.fqns} "
            f"to use dynamic {self.config.recipe_name} quantization for grouped_mm and linear ops"
        )

    def post_optimizer_hook(self, model: nn.Module | list[nn.Module]):
        """
        MXFP8 training doesn't require any post-optimizer hooks at the moment
        """
        return


# Tyro uses cls.__name__ (not __qualname__) to generate subcommand names for Union types.
# Both MXLinearConverter.Config and MXFP8Converter.Config have __name__ = "Config"
# in the same module, causing a naming collision. Rename to make them distinct.
MXFP8Converter.Config.__name__ = "MXFP8ConverterConfig"
