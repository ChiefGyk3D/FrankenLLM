#!/bin/bash
# FrankenLLM - List all models on both GPUs
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== FrankenLLM: Installed Models ==="
echo ""

echo "GPU 0 ($FRANKEN_GPU0_NAME - port $FRANKEN_GPU0_PORT):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
franken_exec "curl -s http://localhost:$FRANKEN_GPU0_PORT/api/tags | jq -r '.models[] | \"  ✓ \" + .name + \" (\" + (.size/1024/1024/1024|floor|tostring) + \"GB)\"' 2>/dev/null || curl -s http://localhost:$FRANKEN_GPU0_PORT/api/tags"
echo ""

echo "GPU 1 ($FRANKEN_GPU1_NAME - port $FRANKEN_GPU1_PORT):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
franken_exec "curl -s http://localhost:$FRANKEN_GPU1_PORT/api/tags | jq -r '.models[] | \"  ✓ \" + .name + \" (\" + (.size/1024/1024/1024|floor|tostring) + \"GB)\"' 2>/dev/null || curl -s http://localhost:$FRANKEN_GPU1_PORT/api/tags"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "To pull models:"
echo "  Same model on both:  ./pull-model.sh <model-name>"
echo "  Different models:    ./pull-dual-models.sh <gpu0-model> <gpu1-model>"
