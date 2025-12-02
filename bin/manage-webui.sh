#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Manage Open WebUI
# Stitched-together GPUs, but it lives!

CONTAINER_NAME="open-webui"

show_usage() {
    echo "Usage: $0 {start|stop|restart|status|logs|update|remove|url}"
    echo ""
    echo "Commands:"
    echo "  start    - Start Open WebUI"
    echo "  stop     - Stop Open WebUI"
    echo "  restart  - Restart Open WebUI"
    echo "  status   - Show Open WebUI status"
    echo "  logs     - Show Open WebUI logs (follow)"
    echo "  update   - Update to latest version"
    echo "  remove   - Remove Open WebUI (keeps data)"
    echo "  url      - Show access URLs"
}

check_container() {
    if ! docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
        echo "❌ Open WebUI is not installed"
        echo "Run: ./bin/install-webui.sh"
        exit 1
    fi
}

show_url() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$SCRIPT_DIR/../config.sh" ]; then
        source "$SCRIPT_DIR/../config.sh"
        echo "🌐 Access URLs:"
        echo "   Local: http://localhost:3000"
        if [ "$FRANKEN_SERVER_IP" != "localhost" ] && [ "$FRANKEN_SERVER_IP" != "127.0.0.1" ]; then
            echo "   Network: http://$FRANKEN_SERVER_IP:3000"
        fi
        echo ""
        echo "🔗 API Endpoint (for N8n, etc):"
        echo "   http://localhost:3000/api"
        if [ "$FRANKEN_SERVER_IP" != "localhost" ] && [ "$FRANKEN_SERVER_IP" != "127.0.0.1" ]; then
            echo "   http://$FRANKEN_SERVER_IP:3000/api"
        fi
    else
        echo "🌐 http://localhost:3000"
    fi
}

case "$1" in
    start)
        check_container
        echo "▶️  Starting Open WebUI..."
        docker start $CONTAINER_NAME
        echo "✅ Started"
        show_url
        ;;
    
    stop)
        check_container
        echo "⏸️  Stopping Open WebUI..."
        docker stop $CONTAINER_NAME
        echo "✅ Stopped"
        ;;
    
    restart)
        check_container
        echo "🔄 Restarting Open WebUI..."
        docker restart $CONTAINER_NAME
        echo "✅ Restarted"
        show_url
        ;;
    
    status)
        check_container
        echo "📊 Open WebUI Status:"
        echo ""
        docker ps -a --filter "name=$CONTAINER_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo ""
        if docker ps --filter "name=$CONTAINER_NAME" --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
            echo "✅ Running"
            show_url
        else
            echo "⏸️  Stopped"
        fi
        ;;
    
    logs)
        check_container
        echo "📋 Open WebUI Logs (Ctrl+C to exit):"
        echo ""
        docker logs -f $CONTAINER_NAME
        ;;
    
    update)
        check_container
        echo "🔄 Updating Open WebUI to latest version..."
        echo ""
        docker pull ghcr.io/open-webui/open-webui:main
        docker stop $CONTAINER_NAME
        docker rm $CONTAINER_NAME
        
        # Restart with same configuration
        echo "Restarting with new version..."
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [ -f "$SCRIPT_DIR/../config.sh" ]; then
            source "$SCRIPT_DIR/../config.sh"
            if [ "$FRANKEN_SERVER_IP" = "localhost" ] || [ "$FRANKEN_SERVER_IP" = "127.0.0.1" ]; then
                docker run -d \
                    -p 3000:8080 \
                    --add-host=host.docker.internal:host-gateway \
                    -e OLLAMA_BASE_URL=http://host.docker.internal:$FRANKEN_GPU0_PORT \
                    -v open-webui:/app/backend/data \
                    --name open-webui \
                    --restart always \
                    ghcr.io/open-webui/open-webui:main
            else
                docker run -d \
                    -p 3000:8080 \
                    -e OLLAMA_BASE_URL=http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT \
                    -v open-webui:/app/backend/data \
                    --name open-webui \
                    --restart always \
                    ghcr.io/open-webui/open-webui:main
            fi
        fi
        echo "✅ Updated successfully!"
        show_url
        ;;
    
    remove)
        check_container
        echo "⚠️  This will remove Open WebUI container but keep your data."
        echo -n "Continue? (y/n): "
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            docker rm -f $CONTAINER_NAME
            echo "✅ Removed"
            echo ""
            echo "💾 Your data is preserved in Docker volume 'open-webui'"
            echo "To remove data too: docker volume rm open-webui"
        else
            echo "Cancelled"
        fi
        ;;
    
    url)
        show_url
        ;;
    
    *)
        show_usage
        exit 1
        ;;
esac
