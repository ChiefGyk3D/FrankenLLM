#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Update Components (Remote)
# Stitched-together GPUs, but it lives!

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

if [ "$FRANKEN_IS_LOCAL" = true ]; then
    echo "❌ Configuration is set for LOCAL installation."
    echo "   Use ./bin/update.sh instead"
    exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

show_usage() {
    echo "FrankenLLM - Update Components on Remote Server"
    echo "Target: $FRANKEN_SERVER_IP"
    echo ""
    echo "Usage: $0 {ollama|webui|all|check}"
    echo ""
    echo "Commands:"
    echo "  ollama   - Update Ollama to latest version"
    echo "  webui    - Update Open WebUI to latest version"
    echo "  all      - Update all components"
    echo "  check    - Check for available updates (no changes)"
    echo ""
    echo "Examples:"
    echo "  $0 ollama    # Update just Ollama"
    echo "  $0 all       # Update everything"
    echo "  $0 check     # See what's outdated"
}

check_ollama_update() {
    echo -e "${BLUE}🔍 Checking Ollama version on $FRANKEN_SERVER_IP...${NC}"
    
    # Get current version
    CURRENT_VERSION=$(ssh "$FRANKEN_SERVER_IP" "ollama --version 2>/dev/null | grep -oP 'version \K[0-9.]+'" 2>/dev/null || echo "unknown")
    echo "   Current: $CURRENT_VERSION"
    
    # Get latest version from GitHub
    LATEST_VERSION=$(curl -s https://api.github.com/repos/ollama/ollama/releases/latest 2>/dev/null | grep -oP '"tag_name": "v\K[0-9.]+' || echo "unknown")
    echo "   Latest:  $LATEST_VERSION"
    
    if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
        echo -e "   ${GREEN}✅ Up to date${NC}"
        return 0
    else
        echo -e "   ${YELLOW}⬆️  Update available${NC}"
        return 2
    fi
}

check_webui_update() {
    echo -e "${BLUE}🔍 Checking Open WebUI on $FRANKEN_SERVER_IP...${NC}"
    
    if ! ssh "$FRANKEN_SERVER_IP" "docker ps -a --format '{{.Names}}' | grep -q '^open-webui$'"; then
        echo -e "   ${YELLOW}Not installed${NC}"
        return 1
    fi
    
    # Get current image ID
    CURRENT_IMAGE=$(ssh "$FRANKEN_SERVER_IP" "docker inspect open-webui --format='{{.Image}}' 2>/dev/null | cut -c8-19")
    echo "   Current image: ${CURRENT_IMAGE:-unknown}"
    
    echo -e "   ${YELLOW}Run 'update webui' to pull latest${NC}"
    return 2
}

update_ollama() {
    echo -e "${BLUE}🔄 Updating Ollama on $FRANKEN_SERVER_IP...${NC}"
    echo ""
    echo "Note: You may be prompted for your sudo password on the remote server."
    echo ""
    
    # Build service list
    SERVICES="ollama-gpu0"
    if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
        SERVICES="$SERVICES ollama-gpu1"
    fi
    
    # Execute update on remote server
    ssh -t "$FRANKEN_SERVER_IP" "
        echo '⏸️  Stopping Ollama services...'
        sudo systemctl stop $SERVICES
        
        echo '📥 Downloading latest Ollama...'
        curl -fsSL https://ollama.com/install.sh | sh
        
        echo '▶️  Starting Ollama services...'
        sudo systemctl start $SERVICES
        
        echo '⏳ Waiting for services to start...'
        sleep 3
        
        echo ''
        NEW_VERSION=\$(ollama --version 2>/dev/null | grep -oP 'version \K[0-9.]+' || echo 'unknown')
        echo \"✅ Ollama updated to version \$NEW_VERSION\"
    "
    
    # Quick health check from local
    echo ""
    echo "🏥 Health check:"
    "$SCRIPT_DIR/../bin/health-check.sh" 2>/dev/null || echo "   Run ./bin/health-check.sh for details"
}

update_webui() {
    echo -e "${BLUE}🔄 Updating Open WebUI on $FRANKEN_SERVER_IP...${NC}"
    echo ""
    
    if ! ssh "$FRANKEN_SERVER_IP" "docker ps -a --format '{{.Names}}' | grep -q '^open-webui$'"; then
        echo -e "${RED}❌ Open WebUI is not installed on remote server${NC}"
        echo "Run: ./remote/install-webui.sh first"
        return 1
    fi
    
    # Build Ollama URLs for all GPUs
    OLLAMA_URLS="http://host.docker.internal:$FRANKEN_GPU0_PORT"
    if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
        OLLAMA_URLS="$OLLAMA_URLS;http://host.docker.internal:$FRANKEN_GPU1_PORT"
    fi
    
    # Execute update on remote server
    ssh "$FRANKEN_SERVER_IP" "
        echo '📥 Pulling latest Open WebUI image...'
        docker pull ghcr.io/open-webui/open-webui:main
        
        echo '⏸️  Stopping current container...'
        docker stop open-webui
        docker rm open-webui
        
        echo '▶️  Starting new container...'
        docker run -d \
            -p 3000:8080 \
            --add-host=host.docker.internal:host-gateway \
            -e OLLAMA_BASE_URLS='$OLLAMA_URLS' \
            -v open-webui:/app/backend/data \
            --name open-webui \
            --restart always \
            ghcr.io/open-webui/open-webui:main
        
        echo ''
        echo '🧹 Cleaning up old images...'
        docker image prune -f
    "
    
    echo ""
    echo -e "${GREEN}✅ Open WebUI updated successfully!${NC}"
    echo ""
    echo "🌐 Access at: http://${FRANKEN_SERVER_IP}:3000"
}

update_all() {
    echo "======================================"
    echo "   FrankenLLM - Full System Update"
    echo "   Target: $FRANKEN_SERVER_IP"
    echo "======================================"
    echo ""
    
    update_ollama
    echo ""
    echo "--------------------------------------"
    echo ""
    update_webui
    
    echo ""
    echo "======================================"
    echo -e "${GREEN}✅ All components updated!${NC}"
    echo "======================================"
}

check_updates() {
    echo "======================================"
    echo "   FrankenLLM - Update Check"
    echo "   Target: $FRANKEN_SERVER_IP"
    echo "======================================"
    echo ""
    
    check_ollama_update
    echo ""
    check_webui_update
    
    echo ""
    echo "--------------------------------------"
    echo "Run '$0 all' to update everything"
}

case "$1" in
    ollama)
        update_ollama
        ;;
    webui)
        update_webui
        ;;
    all)
        update_all
        ;;
    check)
        check_updates
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
