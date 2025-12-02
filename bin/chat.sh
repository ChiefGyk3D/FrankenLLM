#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Interactive Chat with GPU Selection
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

# Function to get available models for a GPU
get_models() {
    local port=$1
    curl -s "http://$FRANKEN_SERVER_IP:$port/api/tags" | grep -o '"name":"[^"]*"' | sed 's/"name":"//g' | sed 's/"//g'
}

# Function to send a message to the LLM
send_message() {
    local port=$1
    local model=$2
    local prompt=$3
    
    echo ""
    echo "🤖 Thinking..."
    response=$(curl -s "http://$FRANKEN_SERVER_IP:$port/api/generate" -d "{
      \"model\": \"$model\",
      \"prompt\": \"$prompt\",
      \"stream\": false
    }" | grep -o '"response":"[^"]*"' | sed 's/"response":"//g' | sed 's/"//g' | sed 's/\\n/\n/g')
    
    if [ -n "$response" ]; then
        echo ""
        echo "$response"
        echo ""
    else
        echo "❌ No response received"
    fi
}

# Clear screen and show banner
clear
echo "╔═══════════════════════════════════════════════╗"
echo "║        🧟 FrankenLLM Interactive Chat         ║"
echo "║     Stitched-together GPUs, but it lives!     ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""

# GPU Selection
echo "Available GPUs:"
echo ""

# Build GPU list
GPU_LIST=()
for i in $(seq 0 $((FRANKEN_GPU_COUNT - 1))); do
    port_var="FRANKEN_GPU${i}_PORT"
    name_var="FRANKEN_GPU${i}_NAME"
    port="${!port_var}"
    name="${!name_var}"
    
    # Test if GPU is responding
    if curl -s "http://$FRANKEN_SERVER_IP:$port/api/tags" > /dev/null 2>&1; then
        models=$(get_models "$port")
        if [ -n "$models" ]; then
            GPU_LIST+=("$i:$port:$name")
            model_count=$(echo "$models" | wc -l)
            echo "  [$i] $name (Port $port) - $model_count model(s) available"
        fi
    fi
done

if [ ${#GPU_LIST[@]} -eq 0 ]; then
    echo "❌ No GPUs with models are responding!"
    echo ""
    echo "Try running: ./bin/test-connection.sh"
    exit 1
fi

echo ""
echo -n "Select GPU [0-$((FRANKEN_GPU_COUNT - 1))]: "
read -r gpu_choice

# Validate GPU choice
SELECTED_GPU=""
SELECTED_PORT=""
SELECTED_NAME=""
for gpu_info in "${GPU_LIST[@]}"; do
    gpu_num=$(echo "$gpu_info" | cut -d':' -f1)
    if [ "$gpu_num" = "$gpu_choice" ]; then
        SELECTED_GPU="$gpu_num"
        SELECTED_PORT=$(echo "$gpu_info" | cut -d':' -f2)
        SELECTED_NAME=$(echo "$gpu_info" | cut -d':' -f3)
        break
    fi
done

if [ -z "$SELECTED_GPU" ]; then
    echo "❌ Invalid GPU selection"
    exit 1
fi

echo ""
echo "Loading models from GPU $SELECTED_GPU ($SELECTED_NAME)..."
MODELS=($(get_models "$SELECTED_PORT"))

if [ ${#MODELS[@]} -eq 0 ]; then
    echo "❌ No models found on this GPU"
    exit 1
fi

# Model Selection
echo ""
echo "Available models:"
echo ""
for i in "${!MODELS[@]}"; do
    echo "  [$i] ${MODELS[$i]}"
done

echo ""
if [ ${#MODELS[@]} -eq 1 ]; then
    echo "Using model: ${MODELS[0]}"
    SELECTED_MODEL="${MODELS[0]}"
else
    echo -n "Select model [0-$((${#MODELS[@]} - 1))]: "
    read -r model_choice
    
    if [ "$model_choice" -ge 0 ] && [ "$model_choice" -lt ${#MODELS[@]} ]; then
        SELECTED_MODEL="${MODELS[$model_choice]}"
    else
        echo "❌ Invalid model selection"
        exit 1
    fi
fi

# Chat loop
clear
echo "╔═══════════════════════════════════════════════╗"
echo "║        🧟 FrankenLLM Interactive Chat         ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""
echo "GPU:   $SELECTED_NAME (GPU $SELECTED_GPU)"
echo "Model: $SELECTED_MODEL"
echo "Port:  $SELECTED_PORT"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Type your messages below. Commands:"
echo "  'quit' or 'exit' - End chat"
echo "  'clear' - Clear screen"
echo "  'info' - Show current GPU/model info"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

while true; do
    echo -n "You: "
    read -r user_input
    
    # Handle empty input
    if [ -z "$user_input" ]; then
        continue
    fi
    
    # Handle commands
    case "$user_input" in
        quit|exit)
            echo ""
            echo "👋 Thanks for chatting with FrankenLLM!"
            exit 0
            ;;
        clear)
            clear
            echo "╔═══════════════════════════════════════════════╗"
            echo "║        🧟 FrankenLLM Interactive Chat         ║"
            echo "╚═══════════════════════════════════════════════╝"
            echo ""
            echo "GPU:   $SELECTED_NAME (GPU $SELECTED_GPU)"
            echo "Model: $SELECTED_MODEL"
            echo ""
            continue
            ;;
        info)
            echo ""
            echo "Current Session:"
            echo "  GPU:   $SELECTED_NAME (GPU $SELECTED_GPU)"
            echo "  Model: $SELECTED_MODEL"
            echo "  Port:  $SELECTED_PORT"
            echo "  Server: $FRANKEN_SERVER_IP"
            echo ""
            continue
            ;;
    esac
    
    # Send message to LLM
    send_message "$SELECTED_PORT" "$SELECTED_MODEL" "$user_input"
done
