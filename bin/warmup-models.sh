#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Warm up GPUs with their designated models
# This loads models into GPU memory so they're ready to use

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

echo "=== FrankenLLM: Warming up GPUs ==="
echo "GPU Count: $FRANKEN_GPU_COUNT"
echo ""

# Model to use on each GPU
# Priority: 1) Command line args, 2) Config file, 3) Default
GPU0_MODEL="${1:-${FRANKEN_GPU0_MODEL:-gemma4:12b}}"
GPU1_MODEL="${2:-${FRANKEN_GPU1_MODEL:-gemma3:4b}}"
GPU0_GUARD_MODEL="${FRANKEN_GPU0_GUARD_MODEL:-}"

# First load after an Ollama upgrade can take over a minute (runner init),
# so the timeout must be generous
WARMUP_TIMEOUT=180

echo "Loading models into GPU memory..."
echo ""

# Warm up GPU 0 by making a small request
echo "GPU 0 ($FRANKEN_GPU0_NAME) - Loading $GPU0_MODEL..."
RESPONSE_0=$(curl -s -m $WARMUP_TIMEOUT "http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT/api/generate" -d "{
  \"model\": \"$GPU0_MODEL\",
  \"prompt\": \"Hi\",
  \"stream\": false
}" 2>&1)

if echo "$RESPONSE_0" | grep -q "response"; then
    echo "  ✅ $GPU0_MODEL loaded and ready on GPU 0"
else
    echo "  ❌ Failed to load $GPU0_MODEL on GPU 0"
    echo "  Error: $RESPONSE_0"
fi

echo ""

# Warm up the guard/moderation model on GPU 0 so it's resident alongside
# the main model (e.g. llama-guard3:8b for AI moderation)
if [ -n "$GPU0_GUARD_MODEL" ]; then
    echo "GPU 0 ($FRANKEN_GPU0_NAME) - Loading guard model $GPU0_GUARD_MODEL..."
    RESPONSE_G=$(curl -s -m $WARMUP_TIMEOUT "http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT/api/generate" -d "{
      \"model\": \"$GPU0_GUARD_MODEL\",
      \"prompt\": \"Hi\",
      \"stream\": false
    }" 2>&1)

    if echo "$RESPONSE_G" | grep -q "response"; then
        echo "  ✅ $GPU0_GUARD_MODEL loaded and ready on GPU 0"
    else
        echo "  ❌ Failed to load $GPU0_GUARD_MODEL on GPU 0"
        echo "  Error: $RESPONSE_G"
    fi
    echo ""
fi

# Warm up GPU 1 if configured
if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
    echo "GPU 1 ($FRANKEN_GPU1_NAME) - Loading $GPU1_MODEL..."
    RESPONSE_1=$(curl -s -m 30 "http://$FRANKEN_SERVER_IP:$FRANKEN_GPU1_PORT/api/generate" -d "{
      \"model\": \"$GPU1_MODEL\",
      \"prompt\": \"Hi\",
      \"stream\": false
    }" 2>&1)

    if echo "$RESPONSE_1" | grep -q "response"; then
        echo "  ✅ $GPU1_MODEL loaded and ready on GPU 1"
    else
        echo "  ❌ Failed to load $GPU1_MODEL on GPU 1"
        echo "  Error: $RESPONSE_1"
    fi
    echo ""
fi

echo "=== GPU Warm-up Complete ==="
echo ""
echo "Models ready to use:"
echo "  GPU 0: $GPU0_MODEL at http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT"
if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
    echo "  GPU 1: $GPU1_MODEL at http://$FRANKEN_SERVER_IP:$FRANKEN_GPU1_PORT"
fi
