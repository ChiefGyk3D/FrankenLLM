#!/bin/bash
# FrankenLLM - Pull models on both GPUs
# Stitched-together GPUs, but it lives!

SERVER_IP="192.168.201.145"
MODEL="${1:-llama3.2}"

echo "=== FrankenLLM: Pulling model '$MODEL' on both GPUs ==="
echo ""

echo "Pulling on GPU 0 (RTX 5060 Ti - port 11434)..."
ssh $SERVER_IP "curl -X POST http://localhost:11434/api/pull -d '{\"name\": \"$MODEL\"}'"
echo ""

echo "Pulling on GPU 1 (RTX 3050 - port 11435)..."
ssh $SERVER_IP "curl -X POST http://localhost:11435/api/pull -d '{\"name\": \"$MODEL\"}'"
echo ""

echo "=== Model pull initiated ==="
echo "You can check status with: ./manage-services.sh logs"
