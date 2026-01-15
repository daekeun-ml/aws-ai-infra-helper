#!/bin/bash

# Resource cleanup script
# Usage: ./4.cleanup.sh

echo "=========================================="
echo "🗑️  Fine-tuning Resource Cleanup"
echo "=========================================="
echo ""

echo "[Current Resource Status]"
kubectl get pytorchjob,pods -l training.kubeflow.org/job-name=deepseek-finetuning 2>/dev/null || echo "✅ No resources found."

echo ""
read -p "Delete all Fine-tuning resources? (y/N): " confirm

if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
    echo ""
    echo "🗑️  Deleting PyTorchJob..."
    kubectl delete pytorchjob deepseek-finetuning --ignore-not-found

    echo ""
    echo "⏳ Waiting for cleanup..."
    sleep 5

    echo ""
    echo "[Status After Cleanup]"
    kubectl get pytorchjob,pods -l training.kubeflow.org/job-name=deepseek-finetuning 2>/dev/null || echo "✅ All resources deleted."

    echo ""
    echo "=========================================="
    echo "✅ Cleanup completed!"
    echo "=========================================="
else
    echo "❌ Cancelled."
fi
