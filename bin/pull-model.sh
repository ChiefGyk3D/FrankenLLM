#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Pull the same model on both GPUs
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

MODEL_NAME="${1}"

if [ -z "$MODEL_NAME" ]; then
    echo "Usage: $0 <model-name>"
    echo ""
    echo "Examples:"
    echo "  $0 gemma3:12b"
    echo "  $0 gemma2:9b"
    echo "  $0 llama3.2"
    exit 1
fi

echo "=== Pulling $MODEL_NAME on both GPUs ==="
echo ""

echo "GPU 0 ($FRANKEN_GPU0_NAME) - Port $FRANKEN_GPU0_PORT:"
franken_exec "OLLAMA_HOST=http://localhost:$FRANKEN_GPU0_PORT ollama pull $MODEL_NAME"

echo ""
echo "GPU 1 ($FRANKEN_GPU1_NAME) - Port $FRANKEN_GPU1_PORT:"
franken_exec "OLLAMA_HOST=http://localhost:$FRANKEN_GPU1_PORT ollama pull $MODEL_NAME"

echo ""
echo "✅ Model $MODEL_NAME pulled on both GPUs!"
