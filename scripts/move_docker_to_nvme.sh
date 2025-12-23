#!/bin/bash

# Move Docker and containerd data to NVME disk

set -e

NEW_DOCKER_ROOT="/opt/sagemaker/docker"
NEW_CONTAINERD_ROOT="/opt/sagemaker/containerd"
OLD_DOCKER_ROOT="/var/lib/docker"
OLD_CONTAINERD_ROOT="/var/lib/containerd"

echo "Stopping Docker and containerd services..."
sudo systemctl stop docker containerd

echo "Creating new directories..."
sudo mkdir -p "$NEW_DOCKER_ROOT"
sudo mkdir -p "$NEW_CONTAINERD_ROOT"

echo "Moving existing data..."
if [ -d "$OLD_DOCKER_ROOT" ]; then
    sudo mv "$OLD_DOCKER_ROOT" "${OLD_DOCKER_ROOT}.backup"
fi
if [ -d "$OLD_CONTAINERD_ROOT" ]; then
    sudo mv "$OLD_CONTAINERD_ROOT" "${OLD_CONTAINERD_ROOT}.backup"
fi

echo "Creating symlinks..."
sudo ln -sf "$NEW_DOCKER_ROOT" "$OLD_DOCKER_ROOT"
sudo ln -sf "$NEW_CONTAINERD_ROOT" "$OLD_CONTAINERD_ROOT"

echo "Updating Docker daemon configuration..."
sudo tee /etc/docker/daemon.json << EOF
{
  "data-root": "$NEW_DOCKER_ROOT"
}
EOF

echo "Starting services..."
sudo systemctl start containerd docker

echo "Verifying configuration..."
docker info | grep "Docker Root Dir"

echo "Complete! Docker and containerd now use NVME disk."
echo "Old data backed up as *.backup - remove when confirmed working"
