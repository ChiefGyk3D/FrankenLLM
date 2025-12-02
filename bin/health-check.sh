#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Simple health check (no sudo required)
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

echo "=== FrankenLLM Health Check ==="
echo ""

# Check GPU 0
echo "GPU 0 ($FRANKEN_GPU0_NAME) - http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT"
RESPONSE_0=$(curl -s -m 5 "http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT/api/tags" 2>&1)
if echo "$RESPONSE_0" | grep -q "models"; then
    echo "  ✅ ONLINE"
    MODEL_COUNT_0=$(echo "$RESPONSE_0" | grep -o '"name"' | wc -l)
    echo "  📦 Models installed: $MODEL_COUNT_0"
    if [ $MODEL_COUNT_0 -gt 0 ]; then
        echo "  Models:"
        echo "$RESPONSE_0" | grep -o '"name":"[^"]*"' | sed 's/"name":"//g' | sed 's/"//g' | sed 's/^/    - /'
    fi
else
    echo "  ❌ OFFLINE or not responding"
fi

echo ""

# Check GPU 1
echo "GPU 1 ($FRANKEN_GPU1_NAME) - http://$FRANKEN_SERVER_IP:$FRANKEN_GPU1_PORT"
RESPONSE_1=$(curl -s -m 5 "http://$FRANKEN_SERVER_IP:$FRANKEN_GPU1_PORT/api/tags" 2>&1)
if echo "$RESPONSE_1" | grep -q "models"; then
    echo "  ✅ ONLINE"
    MODEL_COUNT_1=$(echo "$RESPONSE_1" | grep -o '"name"' | wc -l)
    echo "  📦 Models installed: $MODEL_COUNT_1"
    if [ $MODEL_COUNT_1 -gt 0 ]; then
        echo "  Models:"
        echo "$RESPONSE_1" | grep -o '"name":"[^"]*"' | sed 's/"name":"//g' | sed 's/"//g' | sed 's/^/    - /'
    fi
else
    echo "  ❌ OFFLINE or not responding"
fi

echo ""
