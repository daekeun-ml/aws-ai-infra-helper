#!/bin/bash

# Fine-tuning execution script
# Usage: ./2.run_training.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "🚀 DeepSeek-R1-Distill-Qwen-1.5B Fine-tuning"
echo "=========================================="
echo ""

# Check existing job
EXISTING_JOB=$(kubectl get pytorchjob deepseek-finetuning 2>/dev/null || true)
if [ -n "$EXISTING_JOB" ]; then
    echo "⚠️  Warning: Existing PyTorchJob found."
    echo "$EXISTING_JOB"
    echo ""
    read -p "Delete existing job and start new one? (y/N): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        echo "🗑️  Deleting existing job..."
        kubectl delete pytorchjob deepseek-finetuning --ignore-not-found
        sleep 5
    else
        echo "❌ Cancelled."
        exit 0
    fi
fi

echo "Step 1: Deploying PyTorchJob..."
kubectl apply -f "$SCRIPT_DIR/template/pytorchjob_finetuning.yaml"
echo "✅ PyTorchJob deployed"

echo ""
echo "Step 2: Waiting for Pod creation..."
sleep 5

# Pod status check loop
echo ""
echo "Step 3: Checking Pod status..."
for i in {1..60}; do
    PODS=$(kubectl get pods -l training.kubeflow.org/job-name=deepseek-finetuning --no-headers 2>/dev/null || true)
    if [ -n "$PODS" ]; then
        echo "$PODS"

        # Check if all pods are running
        RUNNING=$(echo "$PODS" | grep -c "Running" || true)
        TOTAL=$(echo "$PODS" | wc -l | tr -d ' ')

        if [ "$RUNNING" = "$TOTAL" ] && [ "$TOTAL" != "0" ]; then
            echo ""
            echo "✅ All Pods are Running!"
            break
        fi
    fi

    if [ $i -eq 60 ]; then
        echo ""
        echo "⚠️  Warning: Pod startup is taking longer than expected."
        echo "   Image download may be in progress (~10GB)."
        echo ""
        echo "   Check status: kubectl describe pod deepseek-finetuning-worker-0"
    else
        echo "⏳ Waiting... ($i/60)"
        sleep 5
    fi
done

echo ""
echo "=========================================="
echo "✅ Fine-tuning Job deployed successfully!"
echo "=========================================="
echo ""
echo "Monitor training: ./3.monitor_training.sh"
echo "Or: kubectl logs -f deepseek-finetuning-worker-0"
