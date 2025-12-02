#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Test connection to Ollama servers
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

echo "=== Testing FrankenLLM Server Connections ==="
echo ""

# Test GPU 0
echo "Testing GPU 0 ($FRANKEN_GPU0_NAME) on port $FRANKEN_GPU0_PORT..."
if curl -s "http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT/api/tags" > /dev/null 2>&1; then
    MODELS_GPU0=$(curl -s "http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT/api/tags" | grep -o '"name":"[^"]*"' | sed 's/"name":"//g' | sed 's/"//g' | tr '\n' ', ' | sed 's/,$//')
    if [ -n "$MODELS_GPU0" ]; then
        echo "✅ GPU 0 responding with models: $MODELS_GPU0"
        GPU0_MODEL=$(echo "$MODELS_GPU0" | cut -d',' -f1)
    else
        echo "⚠️  GPU 0 responding but no models loaded"
    fi
else
    echo "❌ GPU 0 not responding at http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT"
    GPU0_FAIL=1
fi
echo ""

# Test GPU 1 if configured
if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
    echo "Testing GPU 1 ($FRANKEN_GPU1_NAME) on port $FRANKEN_GPU1_PORT..."
    if curl -s "http://$FRANKEN_SERVER_IP:$FRANKEN_GPU1_PORT/api/tags" > /dev/null 2>&1; then
        MODELS_GPU1=$(curl -s "http://$FRANKEN_SERVER_IP:$FRANKEN_GPU1_PORT/api/tags" | grep -o '"name":"[^"]*"' | sed 's/"name":"//g' | sed 's/"//g' | tr '\n' ', ' | sed 's/,$//')
        if [ -n "$MODELS_GPU1" ]; then
            echo "✅ GPU 1 responding with models: $MODELS_GPU1"
            GPU1_MODEL=$(echo "$MODELS_GPU1" | cut -d',' -f1)
        else
            echo "⚠️  GPU 1 responding but no models loaded"
        fi
    else
        echo "❌ GPU 1 not responding at http://$FRANKEN_SERVER_IP:$FRANKEN_GPU1_PORT"
        GPU1_FAIL=1
    fi
    echo ""
fi

# Test additional GPUs if configured
if [ "$FRANKEN_GPU_COUNT" -ge 3 ]; then
    for gpu_num in $(seq 2 $((FRANKEN_GPU_COUNT - 1))); do
        port_var="FRANKEN_GPU${gpu_num}_PORT"
        name_var="FRANKEN_GPU${gpu_num}_NAME"
        port="${!port_var}"
        name="${!name_var}"
        
        echo "Testing GPU $gpu_num ($name) on port $port..."
        if curl -s "http://$FRANKEN_SERVER_IP:$port/api/tags" > /dev/null 2>&1; then
            models=$(curl -s "http://$FRANKEN_SERVER_IP:$port/api/tags" | grep -o '"name":"[^"]*"' | sed 's/"name":"//g' | sed 's/"//g' | tr '\n' ', ' | sed 's/,$//')
            if [ -n "$models" ]; then
                echo "✅ GPU $gpu_num responding with models: $models"
            else
                echo "⚠️  GPU $gpu_num responding but no models loaded"
            fi
        else
            echo "❌ GPU $gpu_num not responding at http://$FRANKEN_SERVER_IP:$port"
        fi
        echo ""
    done
fi

# Summary
if [ -n "$GPU0_FAIL" ] || [ -n "$GPU1_FAIL" ]; then
    echo "❌ Some servers not responding. Check with:"
    if [ "$FRANKEN_INSTALL_MODE" = "LOCAL" ]; then
        echo "   ./local/manage.sh status"
    else
        echo "   ./remote/manage.sh status"
    fi
    exit 1
fi

echo "✅ All configured servers responding!"
echo ""

# Interactive test prompt
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Would you like to test with a prompt? (y/n)"
read -r response

if [[ "$response" =~ ^[Yy]$ ]]; then
    echo ""
    echo "Enter your prompt (or press Enter for default):"
    read -r user_prompt
    
    # Use default if empty
    if [ -z "$user_prompt" ]; then
        user_prompt="Hello! Please respond briefly to confirm you're working."
    fi
    
    echo ""
    echo "=== Testing LLMs with your prompt ==="
    echo "Prompt: $user_prompt"
    echo ""
    
    # Test GPU 0 if model available
    if [ -n "$GPU0_MODEL" ]; then
        echo "--- GPU 0 ($FRANKEN_GPU0_NAME) Response ---"
        response=$(curl -s "http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT/api/generate" -d "{
          \"model\": \"$GPU0_MODEL\",
          \"prompt\": \"$user_prompt\",
          \"stream\": false
        }" | grep -o '"response":"[^"]*"' | sed 's/"response":"//g' | sed 's/"//g' | sed 's/\\n/\n/g')
        
        if [ -n "$response" ]; then
            echo "$response"
        else
            echo "❌ No response received"
        fi
        echo ""
    fi
    
    # Test GPU 1 if available and model loaded
    if [ "$FRANKEN_GPU_COUNT" -ge 2 ] && [ -n "$GPU1_MODEL" ]; then
        echo "--- GPU 1 ($FRANKEN_GPU1_NAME) Response ---"
        response=$(curl -s "http://$FRANKEN_SERVER_IP:$FRANKEN_GPU1_PORT/api/generate" -d "{
          \"model\": \"$GPU1_MODEL\",
          \"prompt\": \"$user_prompt\",
          \"stream\": false
        }" | grep -o '"response":"[^"]*"' | sed 's/"response":"//g' | sed 's/"//g' | sed 's/\\n/\n/g')
        
        if [ -n "$response" ]; then
            echo "$response"
        else
            echo "❌ No response received"
        fi
        echo ""
    fi
    
    echo "✅ Test complete!"
fi
