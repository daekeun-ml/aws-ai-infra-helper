#!/bin/bash

# FSX filesystem explorer script

echo "🔍 FSX Filesystem Explorer"

# Check if fsx-explorer pod exists
if kubectl get pod fsx-explorer >/dev/null 2>&1; then
    echo "✅ FSX explorer pod already exists"
else
    echo "🚀 Creating FSX explorer pod..."
    
    # Get available PVC for FSX
    FSX_PVC=$(kubectl get pvc -o name | grep fsx | head -1 | cut -d'/' -f2)
    
    if [ -z "$FSX_PVC" ]; then
        echo "❌ No FSX PVC found!"
        echo "Available PVCs:"
        kubectl get pvc
        exit 1
    fi
    
    echo "📍 Using PVC: $FSX_PVC"
    
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: fsx-explorer
spec:
  containers:
  - name: explorer
    image: ubuntu:22.04
    command: ["sleep", "3600"]
    volumeMounts:
    - name: fsx-volume
      mountPath: /fsx
  volumes:
  - name: fsx-volume
    persistentVolumeClaim:
      claimName: $FSX_PVC
  restartPolicy: Never
EOF

    echo "⏳ Waiting for pod to be ready..."
    kubectl wait --for=condition=Ready pod/fsx-explorer --timeout=60s
    
    if [ $? -eq 0 ]; then
        echo "✅ FSX explorer pod is ready!"
    else
        echo "❌ Pod failed to start"
        kubectl describe pod fsx-explorer
        exit 1
    fi
fi

echo ""
echo "📋 FSX Filesystem Contents:"
echo "=========================="

# Show root directory
echo "📁 Root directory (/fsx):"
kubectl exec fsx-explorer -- ls -la /fsx

echo ""
echo "📁 Directory tree:"
kubectl exec fsx-explorer -- find /fsx -type d | head -20

echo ""
echo "📊 Disk usage summary:"
kubectl exec fsx-explorer -- sh -c 'du -sh /fsx/* 2>/dev/null || echo "No files found in /fsx"'

echo ""
echo "🔧 Available commands:"
echo "  kubectl exec fsx-explorer -- ls -la /fsx/path"
echo "  kubectl exec fsx-explorer -- cat /fsx/file"
echo "  kubectl exec fsx-explorer -- find /fsx -name '*.json'"
echo "  kubectl exec -it fsx-explorer -- bash  # Interactive shell"
echo ""
echo "🗑️  To cleanup: kubectl delete pod fsx-explorer"
