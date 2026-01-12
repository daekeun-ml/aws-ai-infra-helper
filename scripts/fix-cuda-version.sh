#!/bin/bash

# CUDA Version Check and Fix Script

echo "🔍 === CUDA Version Check Started ==="

# Check nvcc version
if command -v nvcc &> /dev/null; then
    NVCC_VERSION=$(nvcc --version | grep "release" | awk '{print $5}' | cut -d',' -f1)
    echo "📌 Current nvcc version: $NVCC_VERSION"
else
    echo "❌ nvcc not found"
    NVCC_VERSION="none"
fi

# Find installed CUDA versions
echo -e "\n🔎 Searching for installed CUDA versions..."
CUDA_PATHS=($(ls -d /usr/local/cuda-* 2>/dev/null))

if [ ${#CUDA_PATHS[@]} -eq 0 ]; then
    echo "❌ No CUDA installation found"
    exit 1
fi

echo "✅ Found CUDA versions:"
for i in "${!CUDA_PATHS[@]}"; do
    VERSION=$(basename "${CUDA_PATHS[$i]}" | cut -d'-' -f2)
    echo "  [$i] CUDA $VERSION (${CUDA_PATHS[$i]})"
done

# Check if current version should be kept
if [ "$NVCC_VERSION" != "none" ]; then
    echo -ne "\n🤔 Keep current CUDA version ($NVCC_VERSION)? (y/n): "
    read KEEP_CURRENT
    if [[ "$KEEP_CURRENT" =~ ^[Yy]$ ]]; then
        echo "✅ Keeping current CUDA version"
        exit 0
    fi
fi

# User selection
if [ ${#CUDA_PATHS[@]} -eq 1 ]; then
    SELECTED=0
    echo -e "\n✨ Only one CUDA version found, auto-selecting"
else
    echo -ne "\n👉 Select CUDA version number [0-$((${#CUDA_PATHS[@]}-1))]: "
    read SELECTED
    if ! [[ "$SELECTED" =~ ^[0-9]+$ ]] || [ "$SELECTED" -ge ${#CUDA_PATHS[@]} ]; then
        echo "❌ Invalid selection"
        exit 1
    fi
fi

SELECTED_PATH="${CUDA_PATHS[$SELECTED]}"
SELECTED_VERSION=$(basename "$SELECTED_PATH" | cut -d'-' -f2)

echo -e "\n🎯 Selected CUDA: $SELECTED_VERSION ($SELECTED_PATH)"

# Apply to current session
export CUDA_HOME=$SELECTED_PATH
export PATH=$CUDA_HOME/bin:$PATH
export LD_LIBRARY_PATH=$CUDA_HOME/lib64:$LD_LIBRARY_PATH

# Ask for .bashrc update
echo -ne "\n💾 Update ~/.bashrc with CUDA settings? (y/n): "
read UPDATE_BASHRC

if [[ "$UPDATE_BASHRC" =~ ^[Yy]$ ]]; then
    BASHRC="$HOME/.bashrc"
    if [ -f "$BASHRC" ]; then
        # Detect OS and use appropriate sed syntax
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS
            sed -i '' '/# CUDA/d' "$BASHRC"
            sed -i '' '/cuda/d' "$BASHRC"
        else
            # Linux
            sed -i '/# CUDA/d' "$BASHRC"
            sed -i '/cuda/d' "$BASHRC"
        fi
    fi
    
    cat >> "$BASHRC" << EOF

# CUDA settings
export CUDA_HOME=$SELECTED_PATH
export PATH=\$CUDA_HOME/bin:\$PATH
export LD_LIBRARY_PATH=\$CUDA_HOME/lib64:\$LD_LIBRARY_PATH
EOF
    echo "✅ ~/.bashrc updated"
else
    echo "⏭️  Skipping ~/.bashrc update (applied to current session only)"
fi

# Update /usr/local/cuda symlink (if writable)
if [ -w /usr/local ]; then
    echo -ne "\n🔗 Update /usr/local/cuda symlink? (y/n): "
    read UPDATE_SYMLINK
    if [[ "$UPDATE_SYMLINK" =~ ^[Yy]$ ]]; then
        sudo rm -f /usr/local/cuda
        sudo ln -s "$SELECTED_PATH" /usr/local/cuda
        echo "✅ /usr/local/cuda symlink updated"
    else
        echo "⏭️  Skipping symlink update"
    fi
fi

# Verification
echo -e "\n🎉 === Setup Complete ==="
echo "📌 New nvcc version: $(nvcc --version | grep "release" | awk '{print $5}' | cut -d',' -f1)"
echo -e "\n💡 To apply changes, run:"
echo "  source ~/.bashrc"
