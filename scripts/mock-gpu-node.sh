#!/bin/bash
# Patches the local kind/minikube node with the custom vgpu capacity
kubectl patch node $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') --status --type=strategic -p '{"status": {"capacity": {"infrastructure.pranav2910.com/vgpu-bytes": "85899345920"}}}'
echo "Node successfully mocked with 80GB VRAM capacity"
