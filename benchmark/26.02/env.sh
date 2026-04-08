#!/bin/bash
# =============================================================================
# 공통 환경 변수 설정
# 모든 벤치마크 스크립트에서 source하여 사용
# =============================================================================

# ===================== CLUSTER CONFIGURATION =====================
SLURM_ACCOUNT="root"
SLURM_PARTITION="dev"

HF_TOKEN="" # YOUR-HF-TOKEN

WORK_DIR="/fsx/megatron-bridge-test-26.02"
PRESET_DIR="$(dirname "${BASH_SOURCE[0]}")/presets"

# NeMo 컨테이너 버전
NEMO_VERSION="26.02.01"

CONTAINER_IMAGE="nvcr.io/nvidia/nemo:${NEMO_VERSION}"
CONTAINER_DIR="/fsx/containers"
SQSH_FILE="${CONTAINER_DIR}/nemo_${NEMO_VERSION}.sqsh"
# =================================================================
