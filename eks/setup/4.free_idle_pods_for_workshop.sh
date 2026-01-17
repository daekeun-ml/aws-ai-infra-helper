#!/bin/bash

echo "🔧 Freeing up idle pods for workshop environment..."

# Remove webhook configurations
echo "📝 Removing Kueue webhooks..."
kubectl delete mutatingwebhookconfiguration kueue-mutating-webhook-configuration 2>/dev/null || true
kubectl delete validatingwebhookconfiguration kueue-validating-webhook-configuration 2>/dev/null || true

# Scale down unnecessary deployments to free up pod slots
echo "📝 Scaling down Kueue..."
kubectl scale deployment -n kueue-system kueue-controller-manager --replicas=0 2>/dev/null || true

echo "📝 Deleting KEDA components (not needed for workshop)..."
kubectl delete deployment -n kube-system keda-operator 2>/dev/null || true
kubectl delete deployment -n kube-system keda-admission-webhooks 2>/dev/null || true
kubectl delete deployment -n kube-system keda-operator-metrics-apiserver 2>/dev/null || true

echo "📝 Scaling down inference operator..."
kubectl scale deployment -n hyperpod-inference-system hyperpod-inference-operator-controller-manager --replicas=0 2>/dev/null || true

# Clean up completed pods and observability pods
echo "📝 Cleaning up completed pods..."
kubectl delete pods --field-selector=status.phase=Succeeded --all-namespaces 2>/dev/null || true

echo "📝 Deleting observability controller if exists..."
kubectl delete deployment hyperpod-observability-controller-manager -n hyperpod-observability 2>/dev/null || true

# Scale down duplicate controllers to free up pod slots
echo "📝 Scaling down duplicate controllers..."
kubectl delete deployment fsx-csi-controller -n kube-system 2>/dev/null || true
kubectl scale deployment hyperpod-inference-operator-alb -n kube-system --replicas=1 2>/dev/null || true

# Scale down CoreDNS and inference operator metrics for workshop
echo "📝 Scaling down CoreDNS and inference metrics..."
kubectl scale deployment coredns -n kube-system --replicas=1 2>/dev/null || true
kubectl scale deployment hyperpod-inference-operator-metrics -n kube-system --replicas=0 2>/dev/null || true

# Delete FSx CSI node daemonset to free up pod slots
echo "📝 Deleting FSx CSI node daemonset..."
kubectl delete daemonset fsx-csi-node -n kube-system 2>/dev/null || true

# Fix PVC annotation if exists
if kubectl get pvc deepseek15b-model-pvc &>/dev/null; then
    echo "📝 Fixing PVC annotation..."
    kubectl annotate pvc deepseek15b-model-pvc pv.kubernetes.io/bind-completed=yes --overwrite
fi

# Show current node pod usage
echo "📊 Current node pod usage:"
for node in $(kubectl get nodes -o name | cut -d/ -f2); do
  max_pods=$(kubectl get node $node -o jsonpath='{.status.capacity.pods}')
  current_pods=$(kubectl get pods --all-namespaces --field-selector spec.nodeName=$node --no-headers | wc -l)
  echo "  $node: $current_pods/$max_pods pods"
done

echo "✅ Workshop pod cleanup complete! Now deploy with:"
echo "   kubectl apply -f deploy_S3_direct.yaml"
