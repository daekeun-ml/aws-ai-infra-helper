#!/bin/bash

echo "📊 Current node pod usage:"
for node in $(kubectl get nodes -o name | cut -d/ -f2); do
  max_pods=$(kubectl get node $node -o jsonpath='{.status.capacity.pods}')
  current_pods=$(kubectl get pods --all-namespaces --field-selector spec.nodeName=$node --no-headers | wc -l)
  echo "  $node: $current_pods/$max_pods pods"
done
