#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Install Open WebUI on Remote Server
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

echo "╔═══════════════════════════════════════════════╗"
echo "║  🧟 FrankenLLM - Open WebUI Remote Installer  ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""

if [ "$FRANKEN_SERVER_IP" = "localhost" ] || [ "$FRANKEN_SERVER_IP" = "127.0.0.1" ]; then
    echo "❌ This script is for remote server installations"
    echo "Your configuration uses localhost. Run ./bin/install-webui.sh instead"
    exit 1
fi

echo "Installing Open WebUI on $FRANKEN_SERVER_IP..."
echo ""

# Check if Docker is installed on remote
echo "Checking Docker on remote server..."
if ! ssh "$FRANKEN_SERVER_IP" "command -v docker &> /dev/null"; then
    echo "❌ Docker is not installed on the remote server"
    echo "Please install Docker first on $FRANKEN_SERVER_IP"
    exit 1
fi

echo "✅ Docker found on remote server"
echo ""

echo "📋 Configuration:"
echo "   Primary Ollama:   http://localhost:$FRANKEN_GPU0_PORT ($FRANKEN_GPU0_NAME)"
if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
    echo "   Secondary Ollama: http://localhost:$FRANKEN_GPU1_PORT ($FRANKEN_GPU1_NAME)"
fi
echo "   WebUI Port:       3000"
echo "   Server:           $FRANKEN_SERVER_IP"
echo ""

# Check if container already exists
if ssh "$FRANKEN_SERVER_IP" "docker ps -a --format '{{.Names}}' | grep -q '^open-webui$'"; then
    echo "⚠️  Open WebUI container already exists on remote server."
    echo ""
    echo -n "Remove and reinstall? (y/n): "
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        echo "Removing existing container..."
        ssh "$FRANKEN_SERVER_IP" "docker rm -f open-webui"
        echo "✅ Removed"
    else
        echo "Installation cancelled."
        exit 0
    fi
    echo ""
fi

# Install Open WebUI on remote server
echo "🚀 Installing Open WebUI on remote server..."
echo ""

# Since Ollama is on localhost (from the container's perspective on the remote server),
# we use host.docker.internal
ssh "$FRANKEN_SERVER_IP" "docker run -d \
    -p 3000:8080 \
    --add-host=host.docker.internal:host-gateway \
    -e OLLAMA_BASE_URL=http://host.docker.internal:$FRANKEN_GPU0_PORT \
    -v open-webui:/app/backend/data \
    --name open-webui \
    --restart always \
    ghcr.io/open-webui/open-webui:main"

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Open WebUI installed successfully on remote server!"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📱 Access Open WebUI at: http://$FRANKEN_SERVER_IP:3000"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "🔧 Next Steps:"
    echo ""
    echo "1. Open http://$FRANKEN_SERVER_IP:3000 in your browser"
    echo "2. Create an admin account (first user becomes admin)"
    echo "3. Models from GPU 0 ($FRANKEN_GPU0_NAME) will be available"
    echo ""
    
    if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
        echo "4. To add GPU 1 ($FRANKEN_GPU1_NAME) models:"
        echo "   • Click Settings (gear icon) → Connections"
        echo "   • Add new Ollama API connection:"
        echo "     URL: http://host.docker.internal:$FRANKEN_GPU1_PORT"
        echo "     (or use http://localhost:$FRANKEN_GPU1_PORT)"
        echo "   • Now you can select models from both GPUs!"
        echo ""
    fi
    
    echo "💡 For N8n and other apps, use OpenAI-compatible API:"
    echo "   Base URL: http://$FRANKEN_SERVER_IP:3000/api"
    echo "   API Key: Get from Settings → Account → API Keys"
    echo ""
    echo "📚 Documentation: https://docs.openwebui.com/"
    echo ""
    echo "🔧 Manage with: ./remote/manage-webui.sh"
    echo ""
else
    echo ""
    echo "❌ Failed to install Open WebUI on remote server"
    echo "Check Docker logs with: ssh $FRANKEN_SERVER_IP 'docker logs open-webui'"
    exit 1
fi
