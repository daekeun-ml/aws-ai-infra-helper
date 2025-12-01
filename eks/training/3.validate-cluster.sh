#!/bin/bash

echo "=== EKS Cluster Validation ==="
echo ""

# Helm 설치 확인 및 설치
echo "0. Checking helm installation..."
if ! command -v helm &> /dev/null; then
    echo "⚠️  helm not found, installing..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    if command -v helm &> /dev/null; then
        echo "✅ helm installed successfully"
    else
        echo "❌ helm installation failed"
    fi
else
    echo "✅ helm is already installed ($(helm version --short))"
fi
echo ""

# 클러스터 연결 확인
echo "1. Checking cluster connectivity..."
if kubectl cluster-info | head -n 1 > /dev/null 2>&1; then
    echo "✅ Cluster is accessible"
    kubectl cluster-info | head -n 1
else
    echo "❌ Cannot connect to cluster"
    exit 1
fi
echo ""

# 노드 상태 및 GPU/EFA 확인
echo "2. Checking nodes, GPU, and EFA availability..."
kubectl get nodes "-o=custom-columns=NAME:.metadata.name,STATUS:.status.conditions[?(@.type=='Ready')].status,INSTANCETYPE:.metadata.labels.node\.kubernetes\.io/instance-type,GPU:.status.allocatable.nvidia\.com/gpu,EFA:.status.allocatable.vpc\.amazonaws\.com/efa"
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
if [ "$NODE_COUNT" -gt 0 ]; then
    echo "✅ Found $NODE_COUNT node(s)"
else
    echo "❌ No nodes found"
fi
echo ""

# Kubeflow Training Operator 확인
echo "3. Verifying Kubeflow Training Operator..."
if kubectl get pods -n kubeflow 2>/dev/null | grep -q "Running"; then
    echo "✅ Kubeflow Training Operator is running"
    kubectl get pods -n kubeflow
else
    echo "❌ Kubeflow Training Operator not found or not running"
    kubectl get pods -n kubeflow 2>/dev/null || echo "Namespace 'kubeflow' may not exist"
fi
echo ""

# GPU device plugin 확인
echo "4. Checking NVIDIA GPU device plugin..."
if kubectl get daemonset -n kube-system 2>/dev/null | grep -q nvidia; then
    echo "✅ NVIDIA device plugin found"
    kubectl get daemonset -n kube-system | grep nvidia
else
    echo "❌ NVIDIA device plugin not found"
fi
echo ""

# EFA device plugin 확인
echo "5. Checking AWS EFA device plugin..."
if kubectl get daemonset -n kube-system 2>/dev/null | grep -q aws-efa; then
    echo "✅ EFA device plugin found"
    kubectl get daemonset -n kube-system | grep aws-efa
else
    echo "❌ EFA device plugin not found"
fi
echo ""

# 권한 확인
echo "6. Verifying permissions..."
PYTORCH_PERM=$(kubectl auth can-i create pytorchjobs 2>/dev/null)
POD_PERM=$(kubectl auth can-i create pods 2>/dev/null)
SVC_PERM=$(kubectl auth can-i create services 2>/dev/null)

[ "$PYTORCH_PERM" = "yes" ] && echo "  ✅ Can create PyTorchJobs" || echo "  ❌ Cannot create PyTorchJobs"
[ "$POD_PERM" = "yes" ] && echo "  ✅ Can create pods" || echo "  ❌ Cannot create pods"
[ "$SVC_PERM" = "yes" ] && echo "  ✅ Can create services" || echo "  ❌ Cannot create services"
echo ""

# StorageClass 확인
echo "7. Checking StorageClasses..."
if kubectl get storageclass --no-headers 2>/dev/null | wc -l | grep -q -v "^0$"; then
    echo "✅ StorageClasses found"
    kubectl get storageclass
else
    echo "❌ No StorageClasses found"
fi
echo ""

# Persistent Volume 확인
echo "8. Checking Persistent Volumes..."
PV_COUNT=$(kubectl get pv --no-headers 2>/dev/null | wc -l)
if [ "$PV_COUNT" -gt 0 ]; then
    echo "✅ Found $PV_COUNT PV(s)"
    kubectl get pv
else
    echo "⚠️  No PVs found (may be normal)"
fi
echo ""

# Namespace 확인
echo "9. Listing namespaces..."
kubectl get namespaces
echo ""

echo "=== Validation Complete ==="
