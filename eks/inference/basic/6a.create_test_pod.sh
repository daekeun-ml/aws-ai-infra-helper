#!/bin/bash

# Interactive test pod creation script

echo "🚀 Creating test pod with requests pre-installed..."

# Delete existing pod if it exists
kubectl delete pod test-endpoint --ignore-not-found=true

kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-endpoint
spec:
  containers:
  - name: test
    image: python:3.11-slim
    command: ["/bin/bash", "-c"]
    args: ["pip install requests -q && echo 'Ready for testing!' && sleep 3600"]
  restartPolicy: Never
EOF

echo "⏳ Waiting for pod to be ready..."
kubectl wait --for=condition=Ready pod/test-endpoint --timeout=120s

# Show available endpoints (filter out system endpoints)
echo "🔍 Available inference endpoints:"
ENDPOINTS=($(kubectl get endpoints -o name | cut -d'/' -f2 | grep -v "kubernetes"))

if [ ${#ENDPOINTS[@]} -eq 0 ]; then
    echo "❌ No inference endpoints found!"
    exit 1
fi

# Display endpoints with numbers
for i in "${!ENDPOINTS[@]}"; do
    echo "  $((i+1)). ${ENDPOINTS[$i]}"
done

# Get user selection
echo ""
read -p "Select endpoint number (1-${#ENDPOINTS[@]}): " SELECTION

# Validate selection
if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt ${#ENDPOINTS[@]} ]; then
    echo "❌ Invalid selection!"
    exit 1
fi

# Get selected endpoint
SELECTED_ENDPOINT=${ENDPOINTS[$((SELECTION-1))]}

# Get endpoint details
ENDPOINT_IP=$(kubectl get endpoints $SELECTED_ENDPOINT -o jsonpath='{.subsets[0].addresses[0].ip}')
ENDPOINT_PORT=$(kubectl get endpoints $SELECTED_ENDPOINT -o jsonpath='{.subsets[0].ports[0].port}')

echo ""
echo "✅ Test pod is ready!"
echo "🎯 Selected endpoint: $SELECTED_ENDPOINT"
echo "📍 Address: $ENDPOINT_IP:$ENDPOINT_PORT"
echo ""
echo "🔧 You can now run:"
echo "   kubectl exec -it test-endpoint -- bash"
echo ""
echo "📋 Quick test command:"
echo "kubectl exec test-endpoint -- python3 -c \"
import requests
response = requests.post('http://$ENDPOINT_IP:$ENDPOINT_PORT/invocations', 
                        json={'inputs': 'Hello, how are you?'}, 
                        headers={'Content-Type': 'application/json'})
print(f'Status: {response.status_code}')
print(f'Response: {response.text}')
\""
