#!/bin/bash
# FrankenLLM - Pull different models on each GPU
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

GPU0_MODEL="${1}"
GPU1_MODEL="${2}"

if [ -z "$GPU0_MODEL" ] || [ -z "$GPU1_MODEL" ]; then
    echo "Usage: $0 <gpu0_model> <gpu1_model>"
    echo ""
    echo "Example recommended combinations:"
    echo "  $0 gemma3:12b gemma3:4b        # Google Gemma 3 - PERFECT FIT!"
    echo "  $0 gemma2:9b gemma2:2b         # Google Gemma 2 family"
    echo "  $0 llama3.2 llama3.2:3b        # Llama family"
    echo "  $0 codellama:13b phi3:3.8b     # Code + General"
    echo "  $0 mistral:7b-instruct gemma2:2b  # Mixed models"
    echo ""
    echo "GPU 0 ($FRANKEN_GPU0_NAME): Recommended for 16GB"
    echo "  - gemma3:12b (NEWEST!), gemma2:9b, llama3.2, mistral:7b-instruct, codellama:13b"
    echo ""
    echo "GPU 1 ($FRANKEN_GPU1_NAME): Recommended for 8GB"
    echo "  - gemma3:4b (NEWEST!), gemma3:1b, gemma2:2b, llama3.2:3b, phi3:3.8b"
    exit 1
fi

echo "=== FrankenLLM: Pulling Different Models on Each GPU ==="
echo ""

echo "GPU 0 ($FRANKEN_GPU0_NAME - port $FRANKEN_GPU0_PORT): $GPU0_MODEL"
franken_exec "OLLAMA_HOST=http://localhost:$FRANKEN_GPU0_PORT ollama pull $GPU0_MODEL"
echo ""

echo "GPU 1 ($FRANKEN_GPU1_NAME - port $FRANKEN_GPU1_PORT): $GPU1_MODEL"
franken_exec "OLLAMA_HOST=http://localhost:$FRANKEN_GPU1_PORT ollama pull $GPU1_MODEL"
echo ""

echo "=== Model pulls initiated ==="
echo "Check status with: ./manage-services.sh logs"
echo ""
echo "To use the models:"
echo "  GPU 0: curl -X POST http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT/api/generate -d '{\"model\": \"$GPU0_MODEL\", \"prompt\": \"Hello\"}'"
echo "  GPU 1: curl -X POST http://$FRANKEN_SERVER_IP:$FRANKEN_GPU1_PORT/api/generate -d '{\"model\": \"$GPU1_MODEL\", \"prompt\": \"Hello\"}'"
