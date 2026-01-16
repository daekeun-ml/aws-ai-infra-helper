#!/bin/bash

echo "🔧 Fixing deployment issues..."

# Remove webhook configurations
echo "📝 Removing Kueue webhooks..."
kubectl delete mutatingwebhookconfiguration kueue-mutating-webhook-configuration 2>/dev/null || true
kubectl delete validatingwebhookconfiguration kueue-validating-webhook-configuration 2>/dev/null || true

# Scale down unnecessary deployments to free up pod slots
echo "📝 Scaling down Kueue and KEDA..."
kubectl scale deployment -n kueue-system kueue-controller-manager --replicas=0 2>/dev/null || true
kubectl scale deployment -n kube-system keda-operator --replicas=0 2>/dev/null || true
kubectl scale deployment -n kube-system keda-admission-webhooks --replicas=0 2>/dev/null || true
kubectl scale deployment -n kube-system keda-operator-metrics-apiserver --replicas=0 2>/dev/null || true

# Clean up completed pods
echo "📝 Cleaning up completed pods..."
kubectl delete pods --field-selector=status.phase=Succeeded --all-namespaces 2>/dev/null || true

# Fix PVC annotation if exists
if kubectl get pvc deepseek15b-model-pvc &>/dev/null; then
    echo "📝 Fixing PVC annotation..."
    kubectl annotate pvc deepseek15b-model-pvc pv.kubernetes.io/bind-completed=yes --overwrite
fi

echo "✅ Done! Now deploy with:"
echo "   kubectl apply -f deploy_S3_direct.yaml"
