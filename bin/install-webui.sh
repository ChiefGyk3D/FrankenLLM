#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Install Open WebUI
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

echo "╔═══════════════════════════════════════════════╗"
echo "║     🧟 FrankenLLM - Open WebUI Installer      ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Please install Docker first:"
    echo "   https://docs.docker.com/engine/install/"
    exit 1
fi

echo "✅ Docker found"
echo ""

# Determine Ollama URLs
OLLAMA_URL_GPU0="http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT"
OLLAMA_URL_GPU1="http://$FRANKEN_SERVER_IP:$FRANKEN_GPU1_PORT"

echo "📋 Configuration:"
echo "   Primary Ollama:   $OLLAMA_URL_GPU0 ($FRANKEN_GPU0_NAME)"
if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
    echo "   Secondary Ollama: $OLLAMA_URL_GPU1 ($FRANKEN_GPU1_NAME)"
fi
echo "   WebUI Port:       3000"
echo ""

# Check if container already exists
if docker ps -a --format '{{.Names}}' | grep -q "^open-webui$"; then
    echo "⚠️  Open WebUI container already exists."
    echo ""
    echo -n "Remove and reinstall? (y/n): "
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        echo "Removing existing container..."
        docker rm -f open-webui
        echo "✅ Removed"
    else
        echo "Installation cancelled."
        exit 0
    fi
    echo ""
fi

# Install Open WebUI
echo "🚀 Installing Open WebUI..."
echo ""

# Build Ollama URLs for all GPUs
if [ "$FRANKEN_SERVER_IP" = "localhost" ] || [ "$FRANKEN_SERVER_IP" = "127.0.0.1" ]; then
    # Local installation - use host.docker.internal
    OLLAMA_URLS="http://host.docker.internal:$FRANKEN_GPU0_PORT"
    if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
        OLLAMA_URLS="$OLLAMA_URLS;http://host.docker.internal:$FRANKEN_GPU1_PORT"
    fi
    
    docker run -d \
        -p 3000:8080 \
        --add-host=host.docker.internal:host-gateway \
        -e OLLAMA_BASE_URLS="$OLLAMA_URLS" \
        -v open-webui:/app/backend/data \
        --name open-webui \
        --restart always \
        ghcr.io/open-webui/open-webui:main
else
    # Remote installation - use actual IP
    OLLAMA_URLS="$OLLAMA_URL_GPU0"
    if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
        OLLAMA_URLS="$OLLAMA_URLS;$OLLAMA_URL_GPU1"
    fi
    
    docker run -d \
        -p 3000:8080 \
        -e OLLAMA_BASE_URLS="$OLLAMA_URLS" \
        -v open-webui:/app/backend/data \
        --name open-webui \
        --restart always \
        ghcr.io/open-webui/open-webui:main
fi

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Open WebUI installed successfully!"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📱 Access Open WebUI at: http://localhost:3000"
    if [ "$FRANKEN_SERVER_IP" != "localhost" ] && [ "$FRANKEN_SERVER_IP" != "127.0.0.1" ]; then
        echo "   Or from other devices: http://$FRANKEN_SERVER_IP:3000"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "🔧 Next Steps:"
    echo ""
    echo "1. Open http://localhost:3000 in your browser"
    echo "2. Create an admin account (first user becomes admin)"
    if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
        echo "3. Models from BOTH GPUs are automatically configured!"
        echo "   • GPU 0 ($FRANKEN_GPU0_NAME): Port $FRANKEN_GPU0_PORT"
        echo "   • GPU 1 ($FRANKEN_GPU1_NAME): Port $FRANKEN_GPU1_PORT"
    else
        echo "3. Models from GPU 0 ($FRANKEN_GPU0_NAME) will be available"
    fi
    echo ""
    
    echo "💡 For N8n and other apps, use OpenAI-compatible API:"
    echo "   Base URL: http://localhost:3000/api"
    if [ "$FRANKEN_SERVER_IP" != "localhost" ] && [ "$FRANKEN_SERVER_IP" != "127.0.0.1" ]; then
        echo "   Or: http://$FRANKEN_SERVER_IP:3000/api"
    fi
    echo "   API Key: Get from Settings → Account → API Keys"
    echo ""
    echo "📚 Documentation: https://docs.openwebui.com/"
    echo ""
else
    echo ""
    echo "❌ Failed to install Open WebUI"
    echo "Check Docker logs with: docker logs open-webui"
    exit 1
fi
