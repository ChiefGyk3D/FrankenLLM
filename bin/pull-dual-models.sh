#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Pull different models on each GPU
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

# Check if we have the right number of arguments
EXPECTED_ARGS=$FRANKEN_GPU_COUNT
ACTUAL_ARGS=$#

if [ $ACTUAL_ARGS -ne $EXPECTED_ARGS ]; then
    echo "Usage: $0 $(for i in $(seq 0 $(($FRANKEN_GPU_COUNT - 1))); do echo -n "<model-gpu$i> "; done)"
    echo ""
    echo "Pull different models optimized for each GPU's VRAM."
    echo ""
    echo "Configured GPUs: $FRANKEN_GPU_COUNT"
    echo ""
    
    case $FRANKEN_GPU_COUNT in
        1)
            echo "Examples:"
            echo "  $0 gemma3:12b"
            echo "  $0 gemma2:9b"
            echo "  $0 llama3.2"
            ;;
        2)
            echo "Examples:"
            echo "  $0 gemma3:12b gemma3:4b        # Google Gemma 3 - PERFECT FIT!"
            echo "  $0 gemma3:12b gemma3:1b        # Google Gemma 3 - Fast combo"
            echo "  $0 gemma2:9b gemma2:2b         # Google Gemma 2 family"
            echo "  $0 llama3.2 llama3.2:3b        # Meta Llama family"
            echo "  $0 mistral:7b phi3:3.8b        # Mixed models"
            ;;
        3)
            echo "Examples:"
            echo "  $0 gemma3:12b gemma3:4b gemma3:1b"
            echo "  $0 gemma2:9b gemma2:2b llama3.2:3b"
            ;;
        *)
            echo "Examples:"
            echo "  $0 $(for i in $(seq 1 $FRANKEN_GPU_COUNT); do echo -n "model$i "; done)"
            ;;
    esac
    
    echo ""
    echo "Configured GPUs:"
    for i in $(seq 0 $(($FRANKEN_GPU_COUNT - 1))); do
        gpu_name_var="FRANKEN_GPU${i}_NAME"
        gpu_port_var="FRANKEN_GPU${i}_PORT"
        gpu_name="${!gpu_name_var:-GPU $i}"
        gpu_port="${!gpu_port_var}"
        echo "  GPU $i ($gpu_name) - Port $gpu_port"
    done
    
    echo ""
    echo "Recommendations:"
    echo "  16GB GPUs: gemma3:12b, gemma2:9b, llama3.2, mistral:7b-instruct, codellama:13b"
    echo "  8GB GPUs:  gemma3:4b, gemma3:1b, gemma2:2b, llama3.2:3b, phi3:3.8b"
    exit 1
fi

echo "=== Pulling Models on $FRANKEN_GPU_COUNT GPU(s) ==="
echo ""

# Pull models on each GPU
for i in $(seq 0 $(($FRANKEN_GPU_COUNT - 1))); do
    model="${!i}"  # Get the argument at position $i (note: args are 1-indexed, we adjust below)
    model="${@:$(($i + 1)):1}"  # Correct way to get positional argument
    
    gpu_name_var="FRANKEN_GPU${i}_NAME"
    gpu_port_var="FRANKEN_GPU${i}_PORT"
    gpu_name="${!gpu_name_var:-GPU $i}"
    gpu_port="${!gpu_port_var}"
    
    if [ -z "$gpu_port" ]; then
        echo "⚠️  GPU $i port not configured, skipping..."
        continue
    fi
    
    echo "GPU $i ($gpu_name) - Port $gpu_port:"
    echo "  Pulling $model..."
    franken_exec "OLLAMA_HOST=http://localhost:$gpu_port ollama pull $model"
    echo ""
done

echo "✅ All models pulled successfully!"
for i in $(seq 0 $(($FRANKEN_GPU_COUNT - 1))); do
    model="${@:$(($i + 1)):1}"
    gpu_name_var="FRANKEN_GPU${i}_NAME"
    gpu_name="${!gpu_name_var:-GPU $i}"
    echo "  GPU $i ($gpu_name): $model"
done
