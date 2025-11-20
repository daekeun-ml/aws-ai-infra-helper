#!/bin/bash
# NCCL Test Script Generator

set -e

# Check if ParallelCluster
read -p "Is this a ParallelCluster environment? (y/n): " is_pcluster

if [[ "$is_pcluster" == "y" ]]; then
    # ParallelCluster environment
    if [ -f "/opt/nccl-tests/build/all_reduce_perf" ]; then
        ALL_REDUCE_BINARY="/opt/nccl-tests/build/all_reduce_perf"
    else
        echo "Warning: /opt/nccl-tests/build/all_reduce_perf not found."
        read -p "Enter all_reduce_perf path: " ALL_REDUCE_BINARY
    fi
    
    if [ -d "/opt/nccl/build/lib" ]; then
        ADDITIONAL_LD_LIBRARY_PATH="/opt/nccl/build/lib"
    elif [ -d "/opt/nccl/lib" ]; then
        ADDITIONAL_LD_LIBRARY_PATH="/opt/nccl/lib"
    else
        echo "Warning: NCCL library path not found."
        read -p "Enter NCCL library path: " ADDITIONAL_LD_LIBRARY_PATH
    fi
else
    # Auto-detect CUDA versions
    echo "Detecting installed CUDA versions..."
    cuda_versions=($(ls -d /usr/local/cuda-* 2>/dev/null | grep -oP 'cuda-\K[0-9.]+' | sort -V))
    
    if [ ${#cuda_versions[@]} -eq 0 ]; then
        echo "No CUDA found."
        read -p "Enter CUDA version (e.g., 12.4): " cuda_version
    else
        # Get current CUDA version from nvcc
        current_cuda=$(nvcc --version 2>/dev/null | grep -oP 'release \K[0-9.]+' || echo "")
        default_idx=0
        
        echo "Found CUDA versions:"
        for i in "${!cuda_versions[@]}"; do
            if [ "${cuda_versions[$i]}" == "$current_cuda" ]; then
                default_idx=$i
                echo "$((i+1)). ${cuda_versions[$i]} (default - current)"
            else
                echo "$((i+1)). ${cuda_versions[$i]}"
            fi
        done
        
        read -p "Select (1-${#cuda_versions[@]}, default: $((default_idx+1))): " choice
        choice=${choice:-$((default_idx+1))}
        cuda_version="${cuda_versions[$((choice-1))]}"
    fi
    
    # Check if EFA is installed
    if [ -d "/usr/local/cuda-${cuda_version}/efa" ]; then
        ALL_REDUCE_BINARY="/usr/local/cuda-${cuda_version}/efa/test-cuda-${cuda_version}/all_reduce_perf"
    else
        echo "EFA not found, using standard NCCL tests path"
        ALL_REDUCE_BINARY="/usr/local/cuda-${cuda_version}/nccl-tests/all_reduce_perf"
    fi
    
    ADDITIONAL_LD_LIBRARY_PATH="/usr/local/cuda-${cuda_version}/lib"
fi

# Ask about EFA
read -p "Use EFA (Elastic Fabric Adapter)? (y/n, default: y): " use_efa
use_efa=${use_efa:-y}
HAS_EFA=$( [ "$use_efa" == "y" ] && echo true || echo false )

# Node and GPU configuration
read -p "Number of nodes (default: 2): " nodes
nodes=${nodes:-2}

read -p "GPUs per node (default: 8): " gpus_per_node
gpus_per_node=${gpus_per_node:-8}

# NCCL parameters
read -p "NCCL_BUFFSIZE (default: 8388608): " buffsize
buffsize=${buffsize:-8388608}

read -p "NCCL_P2P_NET_CHUNKSIZE (default: 524288): " chunksize
chunksize=${chunksize:-524288}

# Test parameters
read -p "Start size -b (default: 8): " start_size
start_size=${start_size:-8}

read -p "End size -e (default: 16G): " end_size
end_size=${end_size:-16G}

# 스크립트 생성
output_file="nccl-test-${nodes}nodes.sh"

cat > "$output_file" << 'EOF'
#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

EOF

cat >> "$output_file" << EOF
#SBATCH --job-name=nccl-all_reduce_perf
#SBATCH --nodes=${nodes}
#SBATCH --ntasks-per-node ${gpus_per_node}
#SBATCH --output %x_%j.out
#SBATCH --error %x_%j.err
#SBATCH --exclusive

set -ex

ALL_REDUCE_BINARY=${ALL_REDUCE_BINARY}
ADDITIONAL_LD_LIBRARY_PATH=${ADDITIONAL_LD_LIBRARY_PATH}

# Get Hostname to Instance ID mapping
mpirun -N 1 bash -c 'echo \$(hostname) ➡️ \$(cat /sys/devices/virtual/dmi/id/board_asset_tag | tr -d " ")'

# run all_reduce test
EOF

if [ "$HAS_EFA" = true ]; then
cat >> "$output_file" << EOF
mpirun -n \$((${gpus_per_node} * SLURM_JOB_NUM_NODES)) -N ${gpus_per_node} \\
        -x FI_PROVIDER=efa \\
	-x FI_EFA_FORK_SAFE=1 \\
	-x LD_LIBRARY_PATH=\$ADDITIONAL_LD_LIBRARY_PATH:/opt/amazon/efa/lib:/opt/amazon/openmpi/lib:/opt/amazon/ofi-nccl/lib:/usr/local/lib:/usr/lib:\$LD_LIBRARY_PATH \\
	-x NCCL_DEBUG=INFO \\
	-x NCCL_SOCKET_IFNAME=^docker,lo,veth \\
	-x NCCL_BUFFSIZE=${buffsize} \\
	-x NCCL_P2P_NET_CHUNKSIZE=${chunksize} \\
	-x NCCL_TUNER_PLUGIN=/opt/amazon/ofi-nccl/lib/libnccl-ofi-tuner.so \\
	--mca pml ^ucx \\
	--mca btl tcp,self \\
	--mca btl_tcp_if_exclude lo,docker0,veth_def_agent \\
	--bind-to none \${ALL_REDUCE_BINARY} -b ${start_size} -e ${end_size} -f 2 -g 1 -c 1 -n 100
EOF
else
cat >> "$output_file" << EOF
mpirun -n \$((${gpus_per_node} * SLURM_JOB_NUM_NODES)) -N ${gpus_per_node} \\
	-x LD_LIBRARY_PATH=\$ADDITIONAL_LD_LIBRARY_PATH:/usr/local/lib:/usr/lib:\$LD_LIBRARY_PATH \\
	-x NCCL_DEBUG=INFO \\
	-x NCCL_SOCKET_IFNAME=^docker,lo,veth \\
	-x NCCL_BUFFSIZE=${buffsize} \\
	-x NCCL_P2P_NET_CHUNKSIZE=${chunksize} \\
	--mca pml ^ucx \\
	--mca btl tcp,self \\
	--mca btl_tcp_if_exclude lo,docker0,veth_def_agent \\
	--bind-to none \${ALL_REDUCE_BINARY} -b ${start_size} -e ${end_size} -f 2 -g 1 -c 1 -n 100
EOF
fi

chmod +x "$output_file"

echo "✅ NCCL test script generated: $output_file"
echo ""
echo "Configuration summary:"
echo "  - Environment: $([ "$is_pcluster" == "y" ] && echo "ParallelCluster" || echo "DLAMI")"
echo "  - EFA: $([ "$HAS_EFA" = true ] && echo "Enabled" || echo "Disabled (TCP only)")"
echo "  - Nodes: ${nodes}"
echo "  - GPUs per node: ${gpus_per_node}"
echo "  - BUFFSIZE: ${buffsize}"
echo "  - P2P_NET_CHUNKSIZE: ${chunksize}"
echo "  - Test size: ${start_size} ~ ${end_size}"
echo ""
echo "Run with: sbatch $output_file"