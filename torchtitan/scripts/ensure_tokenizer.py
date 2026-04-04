#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree.

"""
Check whether the tokenizer for a given MODULE/CONFIG exists locally.
If not, download it from HuggingFace Hub using HF_TOKEN from the environment.

Usage (called from run_train.sh):
    python scripts/ensure_tokenizer.py --module llama3 --config llama3_8b
"""

import importlib
import os
import subprocess
import sys

# Mapping from model-name prefix to HuggingFace organisation
_ORG_PREFIXES = [
    ("Llama-", "meta-llama"),
    ("llama-", "meta-llama"),
    ("Qwen3.5", "Qwen"),
    ("Qwen3", "Qwen"),
    ("Qwen2", "Qwen"),
    ("Qwen", "Qwen"),
    ("DeepSeek-", "deepseek-ai"),
    ("deepseek-", "deepseek-ai"),
    ("flux", "black-forest-labs"),
]

_TOKENIZER_INDICATOR_FILES = [
    "tokenizer_config.json",
    "tokenizer.json",
    "tokenizer.model",
]


def _get_hf_assets_path(module: str, config: str) -> str | None:
    """Load Trainer.Config and return hf_assets_path, or None on failure."""
    for prefix in ("torchtitan.models", "torchtitan.experiments"):
        module_path = f"{prefix}.{module}.config_registry"
        try:
            mod = importlib.import_module(module_path)
        except ImportError:
            continue

        config_fn = getattr(mod, config, None)
        if config_fn is None or not callable(config_fn):
            continue

        try:
            trainer_config = config_fn()
            return getattr(trainer_config, "hf_assets_path", None)
        except Exception as e:
            print(f"[ensure_tokenizer] Warning: failed to load config '{config}': {e}", file=sys.stderr)
            return None

    return None


def _tokenizer_exists(hf_assets_path: str) -> bool:
    return any(
        os.path.exists(os.path.join(hf_assets_path, f))
        for f in _TOKENIZER_INDICATOR_FILES
    )


def _infer_repo_id(model_name: str) -> str | None:
    for prefix, org in _ORG_PREFIXES:
        if model_name.startswith(prefix):
            return f"{org}/{model_name}"
    return None


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description="Ensure tokenizer is downloaded.")
    parser.add_argument("--module", required=True, help="Model module (e.g. llama3)")
    parser.add_argument("--config", required=True, help="Config name (e.g. llama3_8b)")
    args = parser.parse_args()

    hf_assets_path = _get_hf_assets_path(args.module, args.config)

    if hf_assets_path is None:
        # Could not determine path - skip silently so training can proceed and
        # surface the real error itself.
        sys.exit(0)

    # Normalise relative paths against the working directory of run_train.sh
    if not os.path.isabs(hf_assets_path):
        hf_assets_path = os.path.join(os.getcwd(), hf_assets_path.lstrip("./"))

    if _tokenizer_exists(hf_assets_path):
        sys.exit(0)

    # Tokenizer is missing - need to download
    model_name = os.path.basename(hf_assets_path.rstrip("/"))
    repo_id = _infer_repo_id(model_name)

    if repo_id is None:
        print(
            f"[ensure_tokenizer] Warning: tokenizer not found at '{hf_assets_path}' "
            f"and could not infer HuggingFace repo_id for model '{model_name}'. "
            "Please download it manually:\n"
            f"  uv run scripts/download_hf_assets.py --repo_id <ORG>/{model_name} "
            f"--assets tokenizer --hf_token=<YOUR-HF-TOKEN>",
            file=sys.stderr,
        )
        sys.exit(0)

    hf_token = os.environ.get("HF_TOKEN")
    if not hf_token:
        print(
            f"[ensure_tokenizer] Error: tokenizer not found at '{hf_assets_path}'.\n"
            "Please set the HF_TOKEN environment variable and re-run:\n"
            "  export HF_TOKEN=<your-huggingface-token>",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"[ensure_tokenizer] Tokenizer not found at '{hf_assets_path}'. Downloading from {repo_id} ...")

    script_dir = os.path.dirname(os.path.abspath(__file__))
    download_script = os.path.join(script_dir, "download_hf_assets.py")

    result = subprocess.run(
        [
            "uv", "run", download_script,
            f"--repo_id={repo_id}",
            "--assets", "tokenizer",
            f"--hf_token={hf_token}",
        ],
        check=False,
    )

    if result.returncode != 0:
        print(
            f"[ensure_tokenizer] Error: failed to download tokenizer for {repo_id}.",
            file=sys.stderr,
        )
        sys.exit(result.returncode)

    print(f"[ensure_tokenizer] Tokenizer downloaded successfully to '{hf_assets_path}'.")


if __name__ == "__main__":
    main()
