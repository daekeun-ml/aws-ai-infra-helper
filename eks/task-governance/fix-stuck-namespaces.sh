#!/bin/bash

set -e

echo "Checking for stuck hyperpod namespaces..."

# Check if namespaces exist and are stuck in Terminating state
STUCK_NS=$(kubectl get namespaces | grep "hyperpod-ns.*Terminating" | awk '{print $1}' || true)

if [ -z "$STUCK_NS" ]; then
    echo "No stuck hyperpod namespaces found."
    exit 0
fi

echo "Found stuck namespaces: $STUCK_NS"

for ns in $STUCK_NS; do
    echo "Force deleting namespace: $ns"
    kubectl get namespace $ns -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f -
done

echo "✅ Stuck namespaces have been force deleted."
