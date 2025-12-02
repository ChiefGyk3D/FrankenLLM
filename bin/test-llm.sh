#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Test both LLM servers
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

QUERY="${1:-What is your purpose?}"

echo "=== Testing FrankenLLM Servers ==="
echo "Query: $QUERY"
echo ""

# Use configured models if set, otherwise detect first available
echo "Determining models to use..."
if [ -n "$FRANKEN_GPU0_MODEL" ]; then
    MODEL_GPU0="$FRANKEN_GPU0_MODEL"
    echo "Using configured model for GPU 0: $MODEL_GPU0"
else
    MODEL_GPU0=$(curl -s "http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT/api/tags" | grep -o '"name":"[^"]*"' | head -1 | sed 's/"name":"//g' | sed 's/"//g')
    echo "Auto-detected model for GPU 0: $MODEL_GPU0"
fi

if [ -n "$FRANKEN_GPU1_MODEL" ]; then
    MODEL_GPU1="$FRANKEN_GPU1_MODEL"
    echo "Using configured model for GPU 1: $MODEL_GPU1"
else
    MODEL_GPU1=$(curl -s "http://$FRANKEN_SERVER_IP:$FRANKEN_GPU1_PORT/api/tags" | grep -o '"name":"[^"]*"' | head -1 | sed 's/"name":"//g' | sed 's/"//g')
    echo "Auto-detected model for GPU 1: $MODEL_GPU1"
fi

if [ -z "$MODEL_GPU0" ]; then
    echo "❌ No models found on GPU 0. Pull a model first:"
    echo "   ./bin/pull-model.sh $FRANKEN_GPU0_MODEL"
    exit 1
fi

if [ "$FRANKEN_GPU_COUNT" -ge 2 ] && [ -z "$MODEL_GPU1" ]; then
    echo "❌ No models found on GPU 1. Pull a model first:"
    echo "   ./bin/pull-model.sh $FRANKEN_GPU1_MODEL"
    exit 1
fi
echo ""

echo "--- GPU 0 ($FRANKEN_GPU0_NAME) Response ---"
curl -s "http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT/api/generate" -d "{
  \"model\": \"$MODEL_GPU0\",
  \"prompt\": \"$QUERY\",
  \"stream\": false
}" | grep -o '"response":"[^"]*"' | sed 's/"response":"//g' | sed 's/"//g' | sed 's/\\n/\n/g'

echo ""
echo ""

if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
    echo "--- GPU 1 ($FRANKEN_GPU1_NAME) Response ---"
    curl -s "http://$FRANKEN_SERVER_IP:$FRANKEN_GPU1_PORT/api/generate" -d "{
      \"model\": \"$MODEL_GPU1\",
      \"prompt\": \"$QUERY\",
      \"stream\": false
    }" | grep -o '"response":"[^"]*"' | sed 's/"response":"//g' | sed 's/"//g' | sed 's/\\n/\n/g'

    echo ""
    echo ""
    echo "✅ Both LLMs responding!"
else
    echo "✅ LLM responding!"
fi
