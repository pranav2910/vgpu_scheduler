#!/bin/bash
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl proxy &
PROXY_PID=$!
sleep 2

echo "🔋 Holding fake 80GB A100 state open. Defeating Kubelet reconciliation..."
echo "Press Ctrl+C to stop the mock hardware."

# Infinite loop patching the K8s API every 3 seconds
while true; do
  curl -s --header "Content-Type: application/json-patch+json" \
    --request PATCH \
    --data '[{"op": "add", "path": "/status/capacity/infrastructure.pranav2910.com~1vgpu-bytes", "value": "85899345920"}, {"op": "add", "path": "/status/allocatable/infrastructure.pranav2910.com~1vgpu-bytes", "value": "85899345920"}]' \
    http://localhost:8001/api/v1/nodes/$NODE_NAME/status > /dev/null
  sleep 3
done
