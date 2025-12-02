#!/bin/bash
# FrankenLLM - Test both LLM servers
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

QUERY="${1:-What is your purpose?}"

echo "=== Testing FrankenLLM Servers ==="
echo "Query: $QUERY"
echo ""

# Get first model from each GPU
echo "Detecting models..."
MODEL_GPU0=$(curl -s "http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT/api/tags" | grep -o '"name":"[^"]*"' | head -1 | sed 's/"name":"//g' | sed 's/"//g')
MODEL_GPU1=$(curl -s "http://$FRANKEN_SERVER_IP:$FRANKEN_GPU1_PORT/api/tags" | grep -o '"name":"[^"]*"' | head -1 | sed 's/"name":"//g' | sed 's/"//g')

if [ -z "$MODEL_GPU0" ]; then
    echo "❌ No models found on GPU 0. Pull a model first:"
    echo "   ./bin/pull-model.sh gemma3:12b"
    exit 1
fi

if [ -z "$MODEL_GPU1" ]; then
    echo "❌ No models found on GPU 1. Pull a model first:"
    echo "   ./bin/pull-model.sh gemma3:4b"
    exit 1
fi

echo "GPU 0 Model: $MODEL_GPU0"
echo "GPU 1 Model: $MODEL_GPU1"
echo ""

echo "--- GPU 0 ($FRANKEN_GPU0_NAME) Response ---"
curl -s "http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT/api/generate" -d "{
  \"model\": \"$MODEL_GPU0\",
  \"prompt\": \"$QUERY\",
  \"stream\": false
}" | grep -o '"response":"[^"]*"' | sed 's/"response":"//g' | sed 's/"//g' | sed 's/\\n/\n/g'

echo ""
echo ""
echo "--- GPU 1 ($FRANKEN_GPU1_NAME) Response ---"
curl -s "http://$FRANKEN_SERVER_IP:$FRANKEN_GPU1_PORT/api/generate" -d "{
  \"model\": \"$MODEL_GPU1\",
  \"prompt\": \"$QUERY\",
  \"stream\": false
}" | grep -o '"response":"[^"]*"' | sed 's/"response":"//g' | sed 's/"//g' | sed 's/\\n/\n/g'

echo ""
echo ""
echo "✅ Both LLMs responding!"
