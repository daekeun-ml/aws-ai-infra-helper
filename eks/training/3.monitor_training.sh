#!/bin/bash

# Training monitoring script
# Usage: ./3.monitor_training.sh

echo "=========================================="
echo "📊 Fine-tuning Monitoring"
echo "=========================================="
echo ""

# PyTorchJob status check
echo "[PyTorchJob Status]"
kubectl get pytorchjob deepseek-finetuning 2>/dev/null || echo "❌ PyTorchJob not found."

echo ""
echo "[Pod Status]"
kubectl get pods -l training.kubeflow.org/job-name=deepseek-finetuning 2>/dev/null || echo "❌ Pods not found."

# Get job state
JOB_STATE=$(kubectl get pytorchjob deepseek-finetuning -o jsonpath='{.status.conditions[-1].type}' 2>/dev/null || echo "Unknown")

echo ""
echo "=========================================="
echo "📍 Current State: $JOB_STATE"
echo "=========================================="

if [ "$JOB_STATE" = "Succeeded" ]; then
    echo ""
    echo "✅ [Training Completed - Final Results]"
    echo ""
    kubectl logs deepseek-finetuning-worker-0 --tail=30 2>/dev/null || echo "❌ Cannot retrieve logs."

elif [ "$JOB_STATE" = "Failed" ]; then
    echo ""
    echo "❌ [Training Failed - Error Logs]"
    echo ""
    kubectl logs deepseek-finetuning-worker-0 --tail=50 2>/dev/null || echo "❌ Cannot retrieve logs."

elif [ "$JOB_STATE" = "Running" ]; then
    echo ""
    echo "🔄 [Live Logs - Worker 0]"
    echo "(Press Ctrl+C to exit)"
    echo ""
    kubectl logs -f deepseek-finetuning-worker-0 2>/dev/null || echo "❌ Cannot retrieve logs."

else
    echo ""
    echo "📋 [Pod Events]"
    kubectl describe pod deepseek-finetuning-worker-0 2>/dev/null | grep -A10 "Events:" || echo "❌ Cannot retrieve events."
fi

echo ""
echo "=========================================="
echo "📖 Useful Commands"
echo "=========================================="
echo "Full logs:      kubectl logs deepseek-finetuning-worker-0"
echo "Live logs:      kubectl logs -f deepseek-finetuning-worker-0"
echo "GPU status:     kubectl exec deepseek-finetuning-worker-0 -- nvidia-smi"
echo "Job details:    kubectl describe pytorchjob deepseek-finetuning"
