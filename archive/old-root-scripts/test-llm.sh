#!/bin/bash
# FrankenLLM - Test LLM servers with a simple query
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

PROMPT="${1:-Hello, how are you?}"

echo "=== FrankenLLM: Testing LLM Servers on $FRANKEN_SERVER_IP ==="
echo "Prompt: $PROMPT"
echo ""

echo "1. Testing GPU 0 ($FRANKEN_GPU0_NAME - port $FRANKEN_GPU0_PORT)..."
curl -s -X POST http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT/api/generate -d "{
  \"model\": \"llama3.2\",
  \"prompt\": \"$PROMPT\",
  \"stream\": false
}" | jq -r '.response' 2>/dev/null || echo "Service not responding or jq not installed"

echo ""
echo ""

echo "2. Testing GPU 1 ($FRANKEN_GPU1_NAME - port $FRANKEN_GPU1_PORT)..."
curl -s -X POST http://$FRANKEN_SERVER_IP:$FRANKEN_GPU1_PORT/api/generate -d "{
  \"model\": \"llama3.2\",
  \"prompt\": \"$PROMPT\",
  \"stream\": false
}" | jq -r '.response' 2>/dev/null || echo "Service not responding or jq not installed"

echo ""
echo "=== Test Complete ==="
