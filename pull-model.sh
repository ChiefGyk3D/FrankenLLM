#!/bin/bash
# FrankenLLM - Pull models on both GPUs
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

MODEL="${1:-llama3.2}"

echo "=== FrankenLLM: Pulling model '$MODEL' on both GPUs ==="
echo ""

echo "Pulling on GPU 0 ($FRANKEN_GPU0_NAME - port $FRANKEN_GPU0_PORT)..."
franken_exec "curl -X POST http://localhost:$FRANKEN_GPU0_PORT/api/pull -d '{\"name\": \"$MODEL\"}'"
echo ""

echo "Pulling on GPU 1 ($FRANKEN_GPU1_NAME - port $FRANKEN_GPU1_PORT)..."
franken_exec "curl -X POST http://localhost:$FRANKEN_GPU1_PORT/api/pull -d '{\"name\": \"$MODEL\"}'"
echo ""

echo "=== Model pull initiated ==="
echo "You can check status with: ./manage-services.sh logs"
