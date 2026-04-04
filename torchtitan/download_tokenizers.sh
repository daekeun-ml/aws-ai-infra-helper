#!/usr/bin/env bash
# Download tokenizers for all models supported by torchtitan on AWS.
#
# Models requiring HF_TOKEN (meta-llama access):
#   Llama 3.1 8B / 70B / 405B, Llama 4 Maverick / Scout
#
# Public models (no token required):
#   Qwen3 (0.6B ~ 235B-A22B), Qwen3.5-35B-A3B
#   DeepSeek-V3 (16B, 671B)
#
# Usage:
#   # All models (Llama models require HF_TOKEN)
#   HF_TOKEN=<token> ./download_tokenizers.sh
#
#   # Specific model groups only
#   ./download_tokenizers.sh llama3
#   ./download_tokenizers.sh llama4
#   ./download_tokenizers.sh qwen3
#   ./download_tokenizers.sh qwen3_5_moe
#   ./download_tokenizers.sh deepseek
#
#   # Multiple groups
#   HF_TOKEN=<token> ./download_tokenizers.sh llama3 qwen3
#
#   # Pass token inline
#   ./download_tokenizers.sh --hf_token <token> llama3 llama4

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
DOWNLOAD="${SCRIPT_DIR}/scripts/download_hf_assets.py"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
HF_TOKEN="${HF_TOKEN:-}"
MODEL_GROUPS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hf_token)   HF_TOKEN="$2"; shift 2 ;;
        --hf_token=*) HF_TOKEN="${1#*=}"; shift ;;
        llama3|llama4|qwen3|qwen3_5_moe|deepseek)
            MODEL_GROUPS+=("$1"); shift ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Valid groups: llama3, llama4, qwen3, qwen3_5_moe, deepseek" >&2
            exit 1 ;;
    esac
done

# Default: all groups
if [[ ${#MODEL_GROUPS[@]} -eq 0 ]]; then
    MODEL_GROUPS=(llama3 llama4 qwen3 qwen3_5_moe deepseek)
fi

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------
download_tokenizer() {
    local repo_id="$1"
    local token="${2:-}"
    echo ""
    echo "=================================================="
    echo " Downloading: ${repo_id}"
    echo "=================================================="
    if [[ -n "${token}" ]]; then
        uv run "${DOWNLOAD}" --repo_id "${repo_id}" --assets tokenizer --hf_token "${token}"
    else
        uv run "${DOWNLOAD}" --repo_id "${repo_id}" --assets tokenizer
    fi
}

require_token() {
    local group="$1"
    if [[ -z "${HF_TOKEN}" ]]; then
        echo "Error: ${group} tokenizers require HF_TOKEN (meta-llama access)." >&2
        echo "  export HF_TOKEN=<your-huggingface-token>" >&2
        echo "  or: ./download_tokenizers.sh ${group} --hf_token <token>" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Download by group
# ---------------------------------------------------------------------------
cd "${REPO_ROOT}"

for group in "${MODEL_GROUPS[@]}"; do
    case "${group}" in

        llama3)
            require_token "llama3"
            download_tokenizer "meta-llama/Llama-3.1-8B"   "${HF_TOKEN}"
            download_tokenizer "meta-llama/Llama-3.1-70B"  "${HF_TOKEN}"
            download_tokenizer "meta-llama/Llama-3.1-405B" "${HF_TOKEN}"
            ;;

        llama4)
            require_token "llama4"
            download_tokenizer "meta-llama/Llama-4-Maverick-17B-128E" "${HF_TOKEN}"
            download_tokenizer "meta-llama/Llama-4-Scout-17B-16E"     "${HF_TOKEN}"
            ;;

        qwen3)
            download_tokenizer "Qwen/Qwen3-0.6B"
            download_tokenizer "Qwen/Qwen3-1.7B"
            download_tokenizer "Qwen/Qwen3-14B"
            download_tokenizer "Qwen/Qwen3-32B"
            download_tokenizer "Qwen/Qwen3-30B-A3B"
            download_tokenizer "Qwen/Qwen3-235B-A22B"
            ;;

        qwen3_5_moe)
            download_tokenizer "Qwen/Qwen3.5-35B-A3B"
            ;;

        deepseek)
            download_tokenizer "deepseek-ai/deepseek-moe-16b-base"
            download_tokenizer "deepseek-ai/DeepSeek-V3.1-Base"
            ;;

    esac
done

echo ""
echo "Done. Tokenizers saved under: ${REPO_ROOT}/assets/hf/"
