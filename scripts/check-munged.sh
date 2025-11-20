#!/bin/bash

echo "=== Munged Status Summary ==="

# Current node
echo "[Local: $(hostname)]"
systemctl is-active munge

# Compute nodes
echo "[Compute Nodes]"
sinfo -N -h -o "%N" | xargs -I {} sh -c 'printf "{}: "; srun -w {} systemctl is-active munge 2>/dev/null'