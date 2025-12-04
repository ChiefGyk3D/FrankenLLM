#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Configure Model Warmup
# Stitched-together GPUs, but it lives!

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

# Warmup config file location
if [ "$FRANKEN_IS_LOCAL" = true ]; then
    WARMUP_CONFIG="$HOME/.frankenllm-warmup"
else
    WARMUP_CONFIG="$SCRIPT_DIR/../.warmup-config"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

show_usage() {
    echo "FrankenLLM - Configure Model Warmup"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  show       - Show current warmup configuration"
    echo "  set        - Interactive: select models to warmup"
    echo "  warmup     - Warmup configured models now"
    echo "  clear      - Clear all models from GPU memory"
    echo "  status     - Show what's currently loaded in GPU memory"
    echo ""
    echo "Examples:"
    echo "  $0 show      # Show what's configured"
    echo "  $0 set       # Configure warmup models interactively"
    echo "  $0 warmup    # Load configured models into GPU memory"
    echo "  $0 clear     # Unload all models from memory"
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

get_models_on_gpu() {
    local gpu=$1
    local port=$(get_gpu_port $gpu)
    
    if [ "$FRANKEN_IS_LOCAL" = true ]; then
        OLLAMA_HOST="127.0.0.1:$port" ollama list 2>/dev/null | tail -n +2 | awk '{print $1}'
    else
        ssh "$FRANKEN_SERVER_IP" "OLLAMA_HOST=127.0.0.1:$port ollama list 2>/dev/null" | tail -n +2 | awk '{print $1}'
    fi
}

show_config() {
    echo "╔═══════════════════════════════════════════════╗"
    echo "║     🔥 FrankenLLM - Warmup Configuration      ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo ""
    
    if [ ! -f "$WARMUP_CONFIG" ]; then
        echo -e "${YELLOW}No warmup configuration found.${NC}"
        echo "Run '$0 set' to configure."
        echo ""
        
        # Show defaults from .env
        echo "Default models from .env:"
        for i in $(seq 0 $((FRANKEN_GPU_COUNT - 1))); do
            local model_var="FRANKEN_GPU${i}_MODEL"
            local model="${!model_var}"
            local name=$(get_gpu_name $i)
            if [ -n "$model" ]; then
                echo -e "  GPU $i ($name): ${CYAN}$model${NC}"
            else
                echo -e "  GPU $i ($name): ${YELLOW}(not set)${NC}"
            fi
        done
        return
    fi
    
    echo "Configured warmup models:"
    echo ""
    for i in $(seq 0 $((FRANKEN_GPU_COUNT - 1))); do
        local name=$(get_gpu_name $i)
        local model=$(grep "^GPU${i}=" "$WARMUP_CONFIG" 2>/dev/null | cut -d'=' -f2)
        if [ -n "$model" ]; then
            echo -e "  GPU $i ($name): ${GREEN}$model${NC}"
        else
            echo -e "  GPU $i ($name): ${YELLOW}(not configured)${NC}"
        fi
    done
    echo ""
}

set_config() {
    echo "╔═══════════════════════════════════════════════╗"
    echo "║     🔥 FrankenLLM - Configure Warmup          ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo ""
    
    # Create/clear config
    > "$WARMUP_CONFIG"
    
    for i in $(seq 0 $((FRANKEN_GPU_COUNT - 1))); do
        local name=$(get_gpu_name $i)
        local port=$(get_gpu_port $i)
        
        echo -e "${CYAN}GPU $i ($name):${NC}"
        echo "Available models:"
        
        # Get available models
        local models=$(get_models_on_gpu $i)
        
        if [ -z "$models" ]; then
            echo -e "  ${YELLOW}No models installed on this GPU${NC}"
            echo ""
            continue
        fi
        
        local idx=1
        declare -a model_array
        while IFS= read -r model; do
            echo "  $idx) $model"
            model_array[$idx]="$model"
            ((idx++))
        done <<< "$models"
        echo "  0) Skip (don't warmup this GPU)"
        echo ""
        
        echo -n "Select model for GPU $i [1-$((idx-1)), 0 to skip]: "
        read -r selection
        
        if [ "$selection" = "0" ] || [ -z "$selection" ]; then
            echo -e "${YELLOW}Skipping GPU $i${NC}"
        elif [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -lt "$idx" ]; then
            local selected_model="${model_array[$selection]}"
            echo "GPU${i}=${selected_model}" >> "$WARMUP_CONFIG"
            echo -e "${GREEN}✓ Selected: $selected_model${NC}"
        else
            echo -e "${RED}Invalid selection, skipping${NC}"
        fi
        echo ""
    done
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}Configuration saved!${NC}"
    echo ""
    show_config
    
    echo ""
    echo -n "Warmup models now? [y/N]: "
    read -r warmup_now
    if [[ "$warmup_now" =~ ^[Yy]$ ]]; then
        echo ""
        do_warmup
    fi
}

do_warmup() {
    echo "╔═══════════════════════════════════════════════╗"
    echo "║     🔥 FrankenLLM - Warming Up Models         ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo ""
    
    local config_file="$WARMUP_CONFIG"
    
    # Fall back to .env if no config file
    if [ ! -f "$config_file" ]; then
        echo -e "${YELLOW}No warmup config found, using .env defaults...${NC}"
        echo ""
        
        for i in $(seq 0 $((FRANKEN_GPU_COUNT - 1))); do
            local model_var="FRANKEN_GPU${i}_MODEL"
            local model="${!model_var}"
            local port=$(get_gpu_port $i)
            local name=$(get_gpu_name $i)
            
            if [ -n "$model" ]; then
                echo -e "${BLUE}Loading $model on GPU $i ($name)...${NC}"
                
                if [ "$FRANKEN_IS_LOCAL" = true ]; then
                    curl -s "http://127.0.0.1:$port/api/generate" \
                        -d "{\"model\": \"$model\", \"prompt\": \"warmup\", \"stream\": false}" > /dev/null 2>&1
                else
                    curl -s "http://$FRANKEN_SERVER_IP:$port/api/generate" \
                        -d "{\"model\": \"$model\", \"prompt\": \"warmup\", \"stream\": false}" > /dev/null 2>&1
                fi
                
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}✓ $model loaded on GPU $i${NC}"
                else
                    echo -e "${RED}✗ Failed to load $model on GPU $i${NC}"
                fi
            fi
        done
    else
        for i in $(seq 0 $((FRANKEN_GPU_COUNT - 1))); do
            local model=$(grep "^GPU${i}=" "$config_file" 2>/dev/null | cut -d'=' -f2)
            local port=$(get_gpu_port $i)
            local name=$(get_gpu_name $i)
            
            if [ -n "$model" ]; then
                echo -e "${BLUE}Loading $model on GPU $i ($name)...${NC}"
                
                if [ "$FRANKEN_IS_LOCAL" = true ]; then
                    curl -s "http://127.0.0.1:$port/api/generate" \
                        -d "{\"model\": \"$model\", \"prompt\": \"warmup\", \"stream\": false}" > /dev/null 2>&1
                else
                    curl -s "http://$FRANKEN_SERVER_IP:$port/api/generate" \
                        -d "{\"model\": \"$model\", \"prompt\": \"warmup\", \"stream\": false}" > /dev/null 2>&1
                fi
                
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}✓ $model loaded on GPU $i${NC}"
                else
                    echo -e "${RED}✗ Failed to load $model on GPU $i${NC}"
                fi
            else
                echo -e "${YELLOW}No model configured for GPU $i, skipping${NC}"
            fi
        done
    fi
    
    echo ""
    echo -e "${GREEN}Warmup complete!${NC}"
    echo ""
    show_status
}

clear_models() {
    echo "╔═══════════════════════════════════════════════╗"
    echo "║     🧹 FrankenLLM - Clearing GPU Memory       ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo ""
    
    for i in $(seq 0 $((FRANKEN_GPU_COUNT - 1))); do
        local port=$(get_gpu_port $i)
        local name=$(get_gpu_name $i)
        
        echo -e "${BLUE}Unloading models from GPU $i ($name)...${NC}"
        
        # Get loaded models and unload them
        local models=$(get_models_on_gpu $i)
        
        while IFS= read -r model; do
            if [ -n "$model" ]; then
                if [ "$FRANKEN_IS_LOCAL" = true ]; then
                    curl -s "http://127.0.0.1:$port/api/generate" \
                        -d "{\"model\": \"$model\", \"keep_alive\": 0}" > /dev/null 2>&1
                else
                    curl -s "http://$FRANKEN_SERVER_IP:$port/api/generate" \
                        -d "{\"model\": \"$model\", \"keep_alive\": 0}" > /dev/null 2>&1
                fi
            fi
        done <<< "$models"
        
        echo -e "${GREEN}✓ GPU $i cleared${NC}"
    done
    
    echo ""
    echo "Waiting for memory to be released..."
    sleep 2
    
    show_status
}

show_status() {
    echo "╔═══════════════════════════════════════════════╗"
    echo "║     📊 FrankenLLM - GPU Memory Status         ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo ""
    
    if [ "$FRANKEN_IS_LOCAL" = true ]; then
        nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv,noheader | while IFS=',' read -r idx name used total util; do
            echo -e "${CYAN}GPU $idx:${NC} $name"
            echo "  Memory: $used /$total"
            echo "  Utilization: $util"
            echo ""
        done
    else
        ssh "$FRANKEN_SERVER_IP" "nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv,noheader" | while IFS=',' read -r idx name used total util; do
            echo -e "${CYAN}GPU $idx:${NC} $name"
            echo "  Memory: $used /$total"
            echo "  Utilization: $util"
            echo ""
        done
    fi
    
    echo "Loaded models per GPU:"
    echo ""
    
    if [ "$FRANKEN_IS_LOCAL" = true ]; then
        for i in $(seq 0 $((FRANKEN_GPU_COUNT - 1))); do
            local port=$(get_gpu_port $i)
            local name=$(get_gpu_name $i)
            echo -e "${CYAN}GPU $i ($name):${NC}"
            
            # Check running models via ps endpoint
            local running=$(curl -s "http://127.0.0.1:$port/api/ps" 2>/dev/null | jq -r '.models[]?.name // empty' 2>/dev/null)
            if [ -n "$running" ]; then
                echo "$running" | while read -r model; do
                    echo -e "  ${GREEN}● $model (loaded)${NC}"
                done
            else
                echo -e "  ${YELLOW}○ (no models loaded)${NC}"
            fi
            echo ""
        done
    else
        for i in $(seq 0 $((FRANKEN_GPU_COUNT - 1))); do
            local port=$(get_gpu_port $i)
            local name=$(get_gpu_name $i)
            echo -e "${CYAN}GPU $i ($name):${NC}"
            
            local running=$(curl -s "http://$FRANKEN_SERVER_IP:$port/api/ps" 2>/dev/null | jq -r '.models[]?.name // empty' 2>/dev/null)
            if [ -n "$running" ]; then
                echo "$running" | while read -r model; do
                    echo -e "  ${GREEN}● $model (loaded)${NC}"
                done
            else
                echo -e "  ${YELLOW}○ (no models loaded)${NC}"
            fi
            echo ""
        done
    fi
}

# Main
case "${1:-}" in
    show)
        show_config
        ;;
    set)
        set_config
        ;;
    warmup)
        do_warmup
        ;;
    clear)
        clear_models
        ;;
    status)
        show_status
        ;;
    -h|--help)
        show_usage
        ;;
    *)
        if [ -n "$1" ]; then
            echo -e "${RED}Unknown command: $1${NC}"
            echo ""
        fi
        show_usage
        exit 1
        ;;
esac
