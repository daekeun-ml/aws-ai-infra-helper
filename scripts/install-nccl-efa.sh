#!/bin/bash

set -exo pipefail

NCCL_VERSION=${1:-v2.28.7-1}
AWS_OFI_NCCL_VERSION=${2:-v1.17.1}
EFA_INSTALLER_VERSION=${3:-1.44.0}

# Install NCCL
if [ ! -d "/opt/nccl" ]; then
  git clone  --single-branch --branch ${NCCL_VERSION} https://github.com/NVIDIA/nccl.git /opt/nccl
  cd /opt/nccl
  # Explicitly specify platforms since building for all takes ~10 minutes
  # It takes 6 min 7 sec for 70,80,90
  make -j src.build NVCC_GENCODE="-gencode=arch=compute_70,code=sm_70 -gencode=arch=compute_80,code=sm_80 -gencode=arch=compute_90,code=sm_90"
fi

# Install nccl-tests
if [ ! -d "/opt/nccl-tests" ]; then
  git clone --depth=1 --branch v2.16.9 https://github.com/NVIDIA/nccl-tests.git /opt/nccl-tests
  cd /opt/nccl-tests
  export LD_LIBRARY_PATH=/opt/amazon/efa/lib:$LD_LIBRARY_PATH
  make -j $(nproc) MPI=1 MPI_HOME=/opt/amazon/openmpi NCCL_HOME=/opt/nccl/build CUDA_HOME=/usr/local/cuda
fi

# Install AWS OFI NCCL
if [ ! -d "/opt/aws-ofi-nccl" ]; then
  git clone -b ${AWS_OFI_NCCL_VERSION} --depth=1 https://github.com/aws/aws-ofi-nccl.git /opt/aws-ofi-nccl
  cd /opt/aws-ofi-nccl
  ./autogen.sh
  ./configure --enable-platform-aws \
            --with-libfabric=/opt/amazon/efa \
            --with-mpi=/opt/amazon/openmpi \
            --with-cuda=/usr/local/cuda \
            --prefix=/opt/aws-ofi-nccl
  make -j $(nproc)
  make install
fi

# Install EFA Software
curl -O https://efa-installer.amazonaws.com/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz
tar -xf aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz && cd aws-efa-installer
sudo ./efa_installer.sh -y --mpi=openmpi4