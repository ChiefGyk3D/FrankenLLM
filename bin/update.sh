#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Update Components (Local)
# Stitched-together GPUs, but it lives!

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$PROJECT_ROOT/config.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

show_usage() {
    echo "FrankenLLM - Update Components"
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
    echo -e "${BLUE}🔍 Checking Ollama version...${NC}"
    
    # Get current version
    if command -v ollama &> /dev/null; then
        CURRENT_VERSION=$(ollama --version 2>/dev/null | grep -oP 'version \K[0-9.]+' || echo "unknown")
        echo "   Current: $CURRENT_VERSION"
    else
        echo -e "   ${RED}Ollama not installed${NC}"
        return 1
    fi
    
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
    echo -e "${BLUE}🔍 Checking Open WebUI...${NC}"
    
    if ! docker ps -a --format '{{.Names}}' | grep -q "^open-webui$"; then
        echo -e "   ${YELLOW}Not installed${NC}"
        return 1
    fi
    
    # Get current image ID
    CURRENT_IMAGE=$(docker inspect open-webui --format='{{.Image}}' 2>/dev/null | cut -c8-19)
    echo "   Current image: ${CURRENT_IMAGE:-unknown}"
    
    # Check for updates by pulling (dry run not possible, so just inform)
    echo -e "   ${YELLOW}Run 'update webui' to pull latest${NC}"
    return 2
}

update_ollama() {
    echo -e "${BLUE}🔄 Updating Ollama...${NC}"
    echo ""
    
    # Stop services first
    echo "⏸️  Stopping Ollama services..."
    sudo systemctl stop ollama-gpu0 2>/dev/null
    if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
        sudo systemctl stop ollama-gpu1 2>/dev/null
    fi
    
    # Run the official installer (it handles updates too)
    echo "📥 Downloading latest Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    
    # Restart services
    echo "▶️  Starting Ollama services..."
    sudo systemctl start ollama-gpu0
    if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
        sudo systemctl start ollama-gpu1
    fi
    
    # Wait for services to be ready
    echo "⏳ Waiting for services to start..."
    sleep 3
    
    # Verify
    NEW_VERSION=$(ollama --version 2>/dev/null | grep -oP 'version \K[0-9.]+' || echo "unknown")
    echo ""
    echo -e "${GREEN}✅ Ollama updated to version $NEW_VERSION${NC}"
    
    # Quick health check
    echo ""
    echo "🏥 Health check:"
    "$SCRIPT_DIR/health-check.sh" 2>/dev/null || echo "   Run ./bin/health-check.sh for details"
}

update_webui() {
    echo -e "${BLUE}🔄 Updating Open WebUI...${NC}"
    echo ""
    
    if ! docker ps -a --format '{{.Names}}' | grep -q "^open-webui$"; then
        echo -e "${RED}❌ Open WebUI is not installed${NC}"
        echo "Run: ./bin/install-webui.sh first"
        return 1
    fi
    
    # Pull latest image
    echo "📥 Pulling latest Open WebUI image..."
    docker pull ghcr.io/open-webui/open-webui:main
    
    # Stop and remove old container
    echo "⏸️  Stopping current container..."
    docker stop open-webui
    docker rm open-webui
    
    # Restart with same configuration
    echo "▶️  Starting new container..."
    
    # Build Ollama URLs for all GPUs
    if [ "$FRANKEN_SERVER_IP" = "localhost" ] || [ "$FRANKEN_SERVER_IP" = "127.0.0.1" ]; then
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
        OLLAMA_URLS="http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT"
        if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
            OLLAMA_URLS="$OLLAMA_URLS;http://$FRANKEN_SERVER_IP:$FRANKEN_GPU1_PORT"
        fi
        
        docker run -d \
            -p 3000:8080 \
            -e OLLAMA_BASE_URLS="$OLLAMA_URLS" \
            -v open-webui:/app/backend/data \
            --name open-webui \
            --restart always \
            ghcr.io/open-webui/open-webui:main
    fi
    fi
    
    echo ""
    echo -e "${GREEN}✅ Open WebUI updated successfully!${NC}"
    echo ""
    echo "🌐 Access at: http://localhost:3000"
    if [ "$FRANKEN_SERVER_IP" != "localhost" ] && [ "$FRANKEN_SERVER_IP" != "127.0.0.1" ]; then
        echo "             http://$FRANKEN_SERVER_IP:3000"
    fi
    
    # Cleanup old images
    echo ""
    echo "🧹 Cleaning up old images..."
    docker image prune -f
}

update_all() {
    echo "======================================"
    echo "   FrankenLLM - Full System Update"
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
