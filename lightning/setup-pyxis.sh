#!/bin/bash

# Container image build and Enroot conversion script for Lightning training

set -e

IMAGE_NAME="lightning-training"
IMAGE_TAG="latest"
FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"

echo "=== Lightning Pyxis+Enroot Setup ==="

# 1. Build Docker image
echo "1. Building Docker image..."
docker build -t $FULL_IMAGE_NAME .

# 2. Convert image for Enroot
echo "2. Converting image for Enroot..."
enroot import -o $IMAGE_NAME.sqsh dockerd://$FULL_IMAGE_NAME

# 3. Set permissions
echo "3. Setting image file permissions..."
chmod 644 $IMAGE_NAME.sqsh

echo "=== Setup Complete ==="
echo "Image: $IMAGE_NAME.sqsh"
echo ""
echo "Usage:"
echo "  sbatch train-pyxis.sbatch"
echo ""
echo "Or interactive execution:"
echo "  srun --container-image=$IMAGE_NAME.sqsh --container-mounts=/fsx:/fsx --pty bash"
