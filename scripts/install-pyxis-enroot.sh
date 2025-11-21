#!/bin/bash

set -e

echo "=========================================="
echo "Installing Enroot and Pyxis for HyperPod"
echo "=========================================="

# Variables
SLURM_INSTALL_DIR="/opt/slurm"
PYXIS_TMP_DIR="/tmp/pyxis_install"
PYXIS_VERSION="v0.19.0"
ENROOT_VERSION="3.4.1"

################################################################################
# 1. Modify cgroup.conf to avoid runtime error
################################################################################
echo "Step 1: Configuring cgroup.conf..."
if [[ -f /opt/slurm/etc/cgroup.conf ]]; then
  grep ^ConstrainDevices /opt/slurm/etc/cgroup.conf &> /dev/null \
    || echo "ConstrainDevices=yes" >> /opt/slurm/etc/cgroup.conf
  echo "  ✓ cgroup.conf configured"
else
  echo "  ⚠ /opt/slurm/etc/cgroup.conf not found, skipping..."
fi

################################################################################
# 2. Install dependencies
################################################################################
echo "Step 2: Installing dependencies..."
apt-get update

# Try to install libnvidia-container-tools, if it fails due to version conflict, upgrade all nvidia container packages
echo "  Installing base dependencies..."
apt-get -y -o DPkg::Lock::Timeout=120 install \
  squashfs-tools \
  parallel \
  git \
  build-essential

echo "  Installing nvidia container tools..."
if ! apt-get -y -o DPkg::Lock::Timeout=120 install libnvidia-container-tools; then
  echo "  ⚠ Version conflict detected, upgrading nvidia container packages..."
  apt-get -y -o DPkg::Lock::Timeout=120 install --only-upgrade libnvidia-container1 libnvidia-container-tools || \
  apt-get -y -o DPkg::Lock::Timeout=120 install libnvidia-container1=1.18.0-1 libnvidia-container-tools=1.18.0-1
fi

echo "  ✓ Dependencies installed"

################################################################################
# 3. Install Enroot
################################################################################
echo "Step 3: Installing Enroot ${ENROOT_VERSION}..."

# Create directories
rm -rf $PYXIS_TMP_DIR
mkdir -p $SLURM_INSTALL_DIR/enroot/ $SLURM_INSTALL_DIR/pyxis/ $PYXIS_TMP_DIR

# Download and install Enroot packages
arch=$(dpkg --print-architecture)
cd $PYXIS_TMP_DIR

echo "  Downloading Enroot packages..."
curl -fSsL -O https://github.com/NVIDIA/enroot/releases/download/v${ENROOT_VERSION}/enroot_${ENROOT_VERSION}-1_${arch}.deb
curl -fSsL -O https://github.com/NVIDIA/enroot/releases/download/v${ENROOT_VERSION}/enroot+caps_${ENROOT_VERSION}-1_${arch}.deb

echo "  Installing Enroot packages..."
apt install -y -o DPkg::Lock::Timeout=120 ./enroot_${ENROOT_VERSION}-1_${arch}.deb
apt install -y -o DPkg::Lock::Timeout=120 ./enroot+caps_${ENROOT_VERSION}-1_${arch}.deb

################################################################################
# 4. Configure Enroot
################################################################################
echo "Step 4: Configuring Enroot..."

# Create enroot.conf
cat > /etc/enroot/enroot.conf << 'EOF'
# Enroot configuration for HyperPod
ENROOT_RUNTIME_PATH        /opt/dlami/nvme/tmp/enroot/user-$(id -u)
ENROOT_CONFIG_PATH         ${HOME}/enroot
ENROOT_CACHE_PATH          /fsx/enroot
ENROOT_DATA_PATH           /opt/dlami/nvme/tmp/enroot/data/user-$(id -u)
ENROOT_TEMP_PATH           /opt/dlami/nvme/tmp

# Compression options
ENROOT_SQUASH_OPTIONS      -comp lzo -noI -noD -noF -noX -no-duplicates

# Make container root filesystem writable by default
ENROOT_ROOTFS_WRITABLE     yes

# Don't mount home directory by default
ENROOT_MOUNT_HOME          no

# Don't restrict /dev
ENROOT_RESTRICT_DEV        no
EOF

echo "  ✓ Enroot configured at /etc/enroot/enroot.conf"

################################################################################
# 5. Install Pyxis
################################################################################
echo "Step 5: Installing Pyxis ${PYXIS_VERSION}..."

# Clone Pyxis repository
rm -rf $SLURM_INSTALL_DIR/pyxis
git clone --depth 1 --branch $PYXIS_VERSION https://github.com/NVIDIA/pyxis.git $SLURM_INSTALL_DIR/pyxis

# Build and install Pyxis
cd $SLURM_INSTALL_DIR/pyxis/
echo "  Building Pyxis..."
CPPFLAGS="-I /opt/slurm/include/" make -j $(nproc)
echo "  Installing Pyxis..."
CPPFLAGS="-I /opt/slurm/include/" make install

################################################################################
# 6. Configure Pyxis
################################################################################
echo "Step 6: Configuring Pyxis..."

# Create plugstack.conf.d directory
mkdir -p $SLURM_INSTALL_DIR/etc/plugstack.conf.d/

# Add pyxis to plugstack.conf if not already present
if ! grep -q "include $SLURM_INSTALL_DIR/etc/plugstack.conf.d/pyxis.conf" "$SLURM_INSTALL_DIR/etc/plugstack.conf" 2>/dev/null; then
    echo "include $SLURM_INSTALL_DIR/etc/plugstack.conf.d/pyxis.conf" >> $SLURM_INSTALL_DIR/etc/plugstack.conf
    echo "  ✓ Added pyxis to plugstack.conf"
else
    echo "  ℹ Pyxis already in plugstack.conf"
fi

# Create symlink to pyxis.conf
ln -fs /usr/local/share/pyxis/pyxis.conf $SLURM_INSTALL_DIR/etc/plugstack.conf.d/pyxis.conf

################################################################################
# 7. Create runtime directories
################################################################################
echo "Step 7: Creating runtime directories..."

mkdir -p /run/pyxis/ /tmp/enroot/data /opt/enroot/
chmod 777 -R /tmp/enroot /opt/enroot /run/pyxis/

echo "  ✓ Runtime directories created"

################################################################################
# 8. Wait for NVMe to be available (HyperPod specific)
################################################################################
echo "Step 8: Waiting for NVMe storage to be available..."

MAX_WAIT_TIME=120
ELAPSED_TIME=0
CHECK_INTERVAL=5

while true; do
    # Check the ActiveState of the dlami-nvme.service
    ACTIVE_STATE=$(systemctl show dlami-nvme.service --property=ActiveState --value 2>/dev/null || echo "inactive")
    
    if [ "$ACTIVE_STATE" = "active" ]; then
        echo "  ✓ NVMe storage is active"
        break
    fi
    
    if [ $ELAPSED_TIME -ge $MAX_WAIT_TIME ]; then
        echo "  ⚠ Warning: NVMe storage not detected after $MAX_WAIT_TIME seconds, continuing anyway..."
        break
    fi
    
    echo "  Waiting for NVMe storage... (${ELAPSED_TIME}s/${MAX_WAIT_TIME}s)"
    sleep $CHECK_INTERVAL
    ELAPSED_TIME=$((ELAPSED_TIME + CHECK_INTERVAL))
done

################################################################################
# 9. Create Enroot cache directory on FSx
################################################################################
echo "Step 9: Creating Enroot cache directory..."

# Wait a bit more for FSx to be mounted
sleep 5

if [ -d "/fsx" ]; then
    mkdir -p /fsx/enroot
    chmod 777 /fsx/enroot
    echo "  ✓ Created /fsx/enroot cache directory"
else
    echo "  ⚠ Warning: /fsx not found, enroot cache may not work properly"
fi

################################################################################
# 10. Cleanup
################################################################################
echo "Step 10: Cleaning up..."
rm -rf $PYXIS_TMP_DIR
echo "  ✓ Cleanup complete"

################################################################################
# Installation complete
################################################################################
echo ""
echo "=========================================="
echo "✓ Installation Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Restart slurmd on compute nodes:"
echo "   sudo systemctl restart slurmd"
echo ""
echo "2. Reconfigure Slurm controller:"
echo "   sudo scontrol reconfigure"
echo ""
echo "3. Test Pyxis installation:"
echo "   srun --container-image=nvcr.io#nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi"
echo ""
echo "Installed versions:"
echo "  - Enroot: ${ENROOT_VERSION}"
echo "  - Pyxis: ${PYXIS_VERSION}"
echo ""
