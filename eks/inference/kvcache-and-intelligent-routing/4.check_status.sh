#!/bin/bash

export NAMESPACE="default"
export NAME="demo"

echo "🔍 Checking HyperPod Inference Deployment Status"
echo "================================================"

echo ""
echo "📋 1. InferenceEndpointConfig Status:"
kubectl get inferenceendpointconfig ${NAME} -n ${NAMESPACE}

echo ""
echo "📋 2. Detailed InferenceEndpointConfig Info:"
kubectl describe inferenceendpointconfig ${NAME} -n ${NAMESPACE} | grep -A 10 "Status:"

echo ""
echo "🤖 3. Router Pods (hyperpod-inference-system namespace):"
kubectl get pods -n hyperpod-inference-system -l app=${NAME}-default-router

echo ""
echo "👷 4. Worker Pods (default namespace):"
kubectl get pods -n ${NAMESPACE} -l app=${NAME}

echo ""
echo "📊 5. Router Logs (last 10 lines):"
ROUTER_POD=$(kubectl get pods -n hyperpod-inference-system -l app=${NAME}-default-router -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ ! -z "$ROUTER_POD" ]; then
    echo "Router Pod: $ROUTER_POD"
    kubectl logs $ROUTER_POD -n hyperpod-inference-system -c router-container --tail=10
else
    echo "❌ No router pod found"
fi

echo ""
echo "🔧 6. Worker Logs (if available):"
WORKER_POD=$(kubectl get pods -n ${NAMESPACE} -l app=${NAME} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ ! -z "$WORKER_POD" ]; then
    echo "Worker Pod: $WORKER_POD"
    kubectl logs $WORKER_POD -n ${NAMESPACE} --tail=10
else
    echo "⏳ Worker pod not ready yet"
fi

echo ""
echo "🌐 7. Services:"
kubectl get svc -n ${NAMESPACE} -l app=${NAME}
kubectl get svc -n hyperpod-inference-system -l app=${NAME}-default-router

echo ""
echo "📈 8. Events (last 10):"
kubectl get events -n ${NAMESPACE} --sort-by='.lastTimestamp' | tail -10

echo ""
echo "💡 Useful Commands:"
echo "   # Watch pods status:"
echo "   watch 'kubectl get pods -n default && kubectl get pods -n hyperpod-inference-system'"
echo ""
echo "   # Follow router logs:"
echo "   kubectl logs -l app=${NAME}-default-router -n hyperpod-inference-system -c router-container -f"
echo ""
echo "   # Follow worker logs (when available):"
echo "   kubectl logs -l app=${NAME} -n ${NAMESPACE} -f"
