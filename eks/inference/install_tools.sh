#!/bin/bash

# Install kubectl and eksctl for HyperPod management

set -e

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    KUBECTL_ARCH="amd64"
else
    KUBECTL_ARCH="arm64"
fi

SYSTEM=$(uname -s | tr '[:upper:]' '[:lower:]')

echo "🔍 Detected: $SYSTEM / $KUBECTL_ARCH"
echo ""

# Install helm
if command_exists helm; then
    echo "✅ helm already installed: $(helm version --short 2>/dev/null || helm version)"
else
    echo "📦 Installing helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    echo "✅ helm installed: $(helm version --short 2>/dev/null || helm version)"
fi

echo ""

# Install kubectl
if command_exists kubectl; then
    echo "✅ kubectl already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
else
    echo "📦 Installing kubectl..."
    KUBECTL_VERSION=$(curl -Ls https://dl.k8s.io/release/stable.txt)
    
    if [ "$SYSTEM" = "darwin" ]; then
        curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/darwin/${KUBECTL_ARCH}/kubectl"
    else
        curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${KUBECTL_ARCH}/kubectl"
    fi
    
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
    echo "✅ kubectl installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
fi

echo ""

# Install eksctl
if command_exists eksctl; then
    echo "✅ eksctl already installed: $(eksctl version)"
else
    echo "📦 Installing eksctl..."
    PLATFORM="${SYSTEM}_${KUBECTL_ARCH}"
    
    curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${PLATFORM}.tar.gz" | tar xz -C /tmp
    sudo mv /tmp/eksctl /usr/local/bin/
    echo "✅ eksctl installed: $(eksctl version)"
fi

echo ""
echo "🎉 Installation complete!"
