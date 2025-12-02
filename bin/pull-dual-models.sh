#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Pull different models on each GPU
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

MODEL_GPU0="${1}"
MODEL_GPU1="${2}"

# Check if we have enough arguments for the configured GPU count
if [ "$FRANKEN_GPU_COUNT" -ge 2 ] && ([ -z "$MODEL_GPU0" ] || [ -z "$MODEL_GPU1" ]); then
    echo "Usage: $0 <model-gpu0> <model-gpu1>"
    echo ""
    echo "Pull different models optimized for each GPU's VRAM."
    echo ""
    echo "Configured GPUs: $FRANKEN_GPU_COUNT"
    echo ""
    echo "Examples:"
    echo "  $0 gemma3:12b gemma3:4b        # Google Gemma 3 - PERFECT FIT!"
    echo "  $0 gemma3:12b gemma3:1b        # Google Gemma 3 - Fast combo"
    echo "  $0 gemma2:9b gemma2:2b         # Google Gemma 2 family"
    echo "  $0 llama3.2 llama3.2:3b        # Meta Llama family"
    echo "  $0 mistral:7b phi3:3.8b        # Mixed models"
    echo ""
    echo "GPU 0 ($FRANKEN_GPU0_NAME): Recommended for 16GB"
    echo "  - gemma3:12b (NEWEST!), gemma2:9b, llama3.2, mistral:7b-instruct, codellama:13b"
    echo ""
    if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
        echo "GPU 1 ($FRANKEN_GPU1_NAME): Recommended for 8GB"
        echo "  - gemma3:4b (NEWEST!), gemma3:1b, gemma2:2b, llama3.2:3b, phi3:3.8b"
    fi
    exit 1
elif [ "$FRANKEN_GPU_COUNT" -eq 1 ] && [ -z "$MODEL_GPU0" ]; then
    echo "Usage: $0 <model>"
    echo ""
    echo "Pull a model for single GPU setup."
    echo ""
    echo "Configured GPUs: 1"
    echo ""
    echo "Examples:"
    echo "  $0 gemma3:12b"
    echo "  $0 gemma2:9b"
    echo "  $0 llama3.2"
    exit 1
fi

echo "=== Pulling Models ==="
echo "GPU Count: $FRANKEN_GPU_COUNT"
echo ""

echo "GPU 0 ($FRANKEN_GPU0_NAME) - $MODEL_GPU0:"
franken_exec "OLLAMA_HOST=http://localhost:$FRANKEN_GPU0_PORT ollama pull $MODEL_GPU0"

if [ "$FRANKEN_GPU_COUNT" -ge 2 ] && [ -n "$MODEL_GPU1" ]; then
    echo ""
    echo "GPU 1 ($FRANKEN_GPU1_NAME) - $MODEL_GPU1:"
    franken_exec "OLLAMA_HOST=http://localhost:$FRANKEN_GPU1_PORT ollama pull $MODEL_GPU1"
fi

echo ""
echo "✅ Models pulled successfully!"
echo "  GPU 0: $MODEL_GPU0"
if [ "$FRANKEN_GPU_COUNT" -ge 2 ] && [ -n "$MODEL_GPU1" ]; then
    echo "  GPU 1: $MODEL_GPU1"
fi
