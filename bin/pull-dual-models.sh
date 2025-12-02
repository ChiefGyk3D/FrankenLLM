#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Pull different models on each GPU
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

MODEL_GPU0="${1}"
MODEL_GPU1="${2}"

if [ -z "$MODEL_GPU0" ] || [ -z "$MODEL_GPU1" ]; then
    echo "Usage: $0 <model-gpu0> <model-gpu1>"
    echo ""
    echo "Pull different models optimized for each GPU's VRAM."
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
    echo "GPU 1 ($FRANKEN_GPU1_NAME): Recommended for 8GB"
    echo "  - gemma3:4b (NEWEST!), gemma3:1b, gemma2:2b, llama3.2:3b, phi3:3.8b"
    exit 1
fi

echo "=== Pulling Different Models ==="
echo ""

echo "GPU 0 ($FRANKEN_GPU0_NAME) - $MODEL_GPU0:"
franken_exec "OLLAMA_HOST=http://localhost:$FRANKEN_GPU0_PORT ollama pull $MODEL_GPU0"

echo ""
echo "GPU 1 ($FRANKEN_GPU1_NAME) - $MODEL_GPU1:"
franken_exec "OLLAMA_HOST=http://localhost:$FRANKEN_GPU1_PORT ollama pull $MODEL_GPU1"

echo ""
echo "✅ Models pulled successfully!"
echo "  GPU 0: $MODEL_GPU0"
echo "  GPU 1: $MODEL_GPU1"
