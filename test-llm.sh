#!/bin/bash
# FrankenLLM - Test LLM servers with a simple query
# Stitched-together GPUs, but it lives!

SERVER_IP="192.168.201.145"
PROMPT="${1:-Hello, how are you?}"

echo "=== FrankenLLM: Testing LLM Servers on $SERVER_IP ==="
echo "Prompt: $PROMPT"
echo ""

echo "1. Testing GPU 0 (RTX 5060 Ti - port 11434)..."
curl -s -X POST http://$SERVER_IP:11434/api/generate -d "{
  \"model\": \"llama3.2\",
  \"prompt\": \"$PROMPT\",
  \"stream\": false
}" | jq -r '.response' 2>/dev/null || echo "Service not responding or jq not installed"

echo ""
echo ""

echo "2. Testing GPU 1 (RTX 3050 - port 11435)..."
curl -s -X POST http://$SERVER_IP:11435/api/generate -d "{
  \"model\": \"llama3.2\",
  \"prompt\": \"$PROMPT\",
  \"stream\": false
}" | jq -r '.response' 2>/dev/null || echo "Service not responding or jq not installed"

echo ""
echo "=== Test Complete ==="
