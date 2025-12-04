#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Add Model to Specific GPU
# Stitched-together GPUs, but it lives!

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

show_usage() {
    echo "FrankenLLM - Add Model to Specific GPU"
    echo ""
    echo "Usage: $0 [gpu] [model]"
    echo ""
    echo "Arguments:"
    echo "  gpu     - GPU number (0, 1, 2, etc.) or 'all' for all GPUs"
    echo "  model   - Model name (e.g., gemma3:12b, llama3.2:3b)"
    echo ""
    echo "Examples:"
    echo "  $0 0 gemma3:12b      # Add gemma3:12b to GPU 0"
    echo "  $0 1 gemma3:4b       # Add gemma3:4b to GPU 1"
    echo "  $0 all llama3.2:3b   # Add to all GPUs"
    echo "  $0                   # Interactive mode"
    echo ""
    echo "Current GPU Configuration:"
    show_gpu_info
}

show_gpu_info() {
    echo ""
    for i in $(seq 0 $((FRANKEN_GPU_COUNT - 1))); do
        local port_var="FRANKEN_GPU${i}_PORT"
        local name_var="FRANKEN_GPU${i}_NAME"
        local port="${!port_var}"
        local name="${!name_var:-GPU $i}"
        echo -e "  ${CYAN}GPU $i${NC}: $name (Port $port)"
    done
    echo ""
}

get_gpu_port() {
    local gpu=$1
    local port_var="FRANKEN_GPU${gpu}_PORT"
    echo "${!port_var}"
}

get_gpu_name() {
    local gpu=$1
    local name_var="FRANKEN_GPU${gpu}_NAME"
    echo "${!name_var:-GPU $gpu}"
}

list_models_on_gpu() {
    local gpu=$1
    local port=$(get_gpu_port $gpu)
    local name=$(get_gpu_name $gpu)
    
    echo -e "${CYAN}GPU $gpu ($name) - Port $port:${NC}"
    if [ "$FRANKEN_IS_LOCAL" = true ]; then
        OLLAMA_HOST="127.0.0.1:$port" ollama list 2>/dev/null || echo "  (no models or service not running)"
    else
        ssh "$FRANKEN_SERVER_IP" "OLLAMA_HOST=127.0.0.1:$port ollama list 2>/dev/null" || echo "  (no models or service not running)"
    fi
    echo ""
}

pull_model_to_gpu() {
    local gpu=$1
    local model=$2
    local port=$(get_gpu_port $gpu)
    local name=$(get_gpu_name $gpu)
    
    echo -e "${BLUE}📥 Pulling $model to GPU $gpu ($name)...${NC}"
    echo ""
    
    if [ "$FRANKEN_IS_LOCAL" = true ]; then
        OLLAMA_HOST="127.0.0.1:$port" ollama pull "$model"
    else
        ssh "$FRANKEN_SERVER_IP" "OLLAMA_HOST=127.0.0.1:$port ollama pull '$model'"
    fi
    
    if [ $? -eq 0 ]; then
        echo ""
        echo -e "${GREEN}✅ Successfully added $model to GPU $gpu ($name)${NC}"
        return 0
    else
        echo ""
        echo -e "${RED}❌ Failed to add $model to GPU $gpu${NC}"
        return 1
    fi
}

remove_model_from_gpu() {
    local gpu=$1
    local model=$2
    local port=$(get_gpu_port $gpu)
    local name=$(get_gpu_name $gpu)
    
    echo -e "${YELLOW}🗑️  Removing $model from GPU $gpu ($name)...${NC}"
    
    if [ "$FRANKEN_IS_LOCAL" = true ]; then
        OLLAMA_HOST="127.0.0.1:$port" ollama rm "$model"
    else
        ssh "$FRANKEN_SERVER_IP" "OLLAMA_HOST=127.0.0.1:$port ollama rm '$model'"
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Removed $model from GPU $gpu${NC}"
    else
        echo -e "${RED}❌ Failed to remove $model from GPU $gpu${NC}"
    fi
}

interactive_mode() {
    echo "╔═══════════════════════════════════════════════╗"
    echo "║     🧟 FrankenLLM - Model Manager             ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo ""
    
    # Show current models on each GPU
    echo -e "${BLUE}Current Models:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    for i in $(seq 0 $((FRANKEN_GPU_COUNT - 1))); do
        list_models_on_gpu $i
    done
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "What would you like to do?"
    echo "  1) Add a model to a GPU"
    echo "  2) Remove a model from a GPU"
    echo "  3) List all models"
    echo "  4) Exit"
    echo ""
    echo -n "Select [1-4]: "
    read -r choice
    
    case $choice in
        1)
            echo ""
            echo "Available GPUs:"
            for i in $(seq 0 $((FRANKEN_GPU_COUNT - 1))); do
                echo "  $i) $(get_gpu_name $i)"
            done
            echo ""
            echo -n "Select GPU [0-$((FRANKEN_GPU_COUNT - 1))]: "
            read -r gpu
            
            if ! [[ "$gpu" =~ ^[0-9]+$ ]] || [ "$gpu" -ge "$FRANKEN_GPU_COUNT" ]; then
                echo -e "${RED}Invalid GPU selection${NC}"
                exit 1
            fi
            
            echo ""
            echo "Popular models:"
            echo "  • gemma3:27b (24GB+ VRAM)"
            echo "  • gemma3:12b (16GB VRAM)"
            echo "  • gemma3:4b (8GB VRAM)"
            echo "  • gemma3:1b (4GB VRAM)"
            echo "  • llama3.2:3b (8GB VRAM)"
            echo "  • llama3.1:8b (16GB VRAM)"
            echo "  • codellama:13b (16GB VRAM)"
            echo "  • mistral:7b (16GB VRAM)"
            echo "  • phi3:3.8b (8GB VRAM)"
            echo ""
            echo -n "Enter model name: "
            read -r model
            
            if [ -z "$model" ]; then
                echo -e "${RED}No model specified${NC}"
                exit 1
            fi
            
            echo ""
            pull_model_to_gpu "$gpu" "$model"
            ;;
        2)
            echo ""
            echo "Select GPU to remove model from:"
            for i in $(seq 0 $((FRANKEN_GPU_COUNT - 1))); do
                echo "  $i) $(get_gpu_name $i)"
            done
            echo ""
            echo -n "Select GPU [0-$((FRANKEN_GPU_COUNT - 1))]: "
            read -r gpu
            
            if ! [[ "$gpu" =~ ^[0-9]+$ ]] || [ "$gpu" -ge "$FRANKEN_GPU_COUNT" ]; then
                echo -e "${RED}Invalid GPU selection${NC}"
                exit 1
            fi
            
            echo ""
            echo "Models on GPU $gpu:"
            list_models_on_gpu $gpu
            
            echo -n "Enter model name to remove: "
            read -r model
            
            if [ -z "$model" ]; then
                echo -e "${RED}No model specified${NC}"
                exit 1
            fi
            
            echo ""
            remove_model_from_gpu "$gpu" "$model"
            ;;
        3)
            echo ""
            for i in $(seq 0 $((FRANKEN_GPU_COUNT - 1))); do
                list_models_on_gpu $i
            done
            ;;
        4)
            echo "Bye!"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid selection${NC}"
            exit 1
            ;;
    esac
}

# Main
if [ $# -eq 0 ]; then
    interactive_mode
elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_usage
elif [ "$1" = "list" ]; then
    for i in $(seq 0 $((FRANKEN_GPU_COUNT - 1))); do
        list_models_on_gpu $i
    done
elif [ "$1" = "all" ] && [ -n "$2" ]; then
    model="$2"
    for i in $(seq 0 $((FRANKEN_GPU_COUNT - 1))); do
        pull_model_to_gpu $i "$model"
        echo ""
    done
elif [ -n "$1" ] && [ -n "$2" ]; then
    gpu="$1"
    model="$2"
    
    if ! [[ "$gpu" =~ ^[0-9]+$ ]] || [ "$gpu" -ge "$FRANKEN_GPU_COUNT" ]; then
        echo -e "${RED}Invalid GPU: $gpu (must be 0-$((FRANKEN_GPU_COUNT - 1)))${NC}"
        exit 1
    fi
    
    pull_model_to_gpu "$gpu" "$model"
else
    show_usage
    exit 1
fi
