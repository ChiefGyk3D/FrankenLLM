#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Manage Open WebUI on Remote Server
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

CONTAINER_NAME="open-webui"

if [ "$FRANKEN_SERVER_IP" = "localhost" ] || [ "$FRANKEN_SERVER_IP" = "127.0.0.1" ]; then
    echo "❌ This script is for remote server management"
    echo "Your configuration uses localhost. Run ./bin/manage-webui.sh instead"
    exit 1
fi

show_usage() {
    echo "Usage: $0 {start|stop|restart|status|logs|update|remove|url}"
    echo ""
    echo "Commands:"
    echo "  start    - Start Open WebUI on remote server"
    echo "  stop     - Stop Open WebUI on remote server"
    echo "  restart  - Restart Open WebUI on remote server"
    echo "  status   - Show Open WebUI status on remote server"
    echo "  logs     - Show Open WebUI logs from remote server"
    echo "  update   - Update to latest version on remote server"
    echo "  remove   - Remove Open WebUI from remote server (keeps data)"
    echo "  url      - Show access URLs"
}

check_container() {
    if ! ssh "$FRANKEN_SERVER_IP" "docker ps -a --format '{{.Names}}' | grep -q '^$CONTAINER_NAME$'"; then
        echo "❌ Open WebUI is not installed on remote server"
        echo "Run: ./remote/install-webui.sh"
        exit 1
    fi
}

show_url() {
    echo "🌐 Access URLs:"
    echo "   http://$FRANKEN_SERVER_IP:3000"
    echo ""
    echo "🔗 API Endpoint (for N8n, etc):"
    echo "   http://$FRANKEN_SERVER_IP:3000/api"
}

case "$1" in
    start)
        check_container
        echo "▶️  Starting Open WebUI on remote server..."
        ssh "$FRANKEN_SERVER_IP" "docker start $CONTAINER_NAME"
        echo "✅ Started"
        show_url
        ;;
    
    stop)
        check_container
        echo "⏸️  Stopping Open WebUI on remote server..."
        ssh "$FRANKEN_SERVER_IP" "docker stop $CONTAINER_NAME"
        echo "✅ Stopped"
        ;;
    
    restart)
        check_container
        echo "🔄 Restarting Open WebUI on remote server..."
        ssh "$FRANKEN_SERVER_IP" "docker restart $CONTAINER_NAME"
        echo "✅ Restarted"
        show_url
        ;;
    
    status)
        check_container
        echo "📊 Open WebUI Status on $FRANKEN_SERVER_IP:"
        echo ""
        ssh "$FRANKEN_SERVER_IP" "docker ps -a --filter 'name=$CONTAINER_NAME' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
        echo ""
        if ssh "$FRANKEN_SERVER_IP" "docker ps --filter 'name=$CONTAINER_NAME' --format '{{.Names}}' | grep -q '^$CONTAINER_NAME$'"; then
            echo "✅ Running"
            show_url
        else
            echo "⏸️  Stopped"
        fi
        ;;
    
    logs)
        check_container
        echo "📋 Open WebUI Logs from $FRANKEN_SERVER_IP (Ctrl+C to exit):"
        echo ""
        ssh "$FRANKEN_SERVER_IP" "docker logs -f $CONTAINER_NAME"
        ;;
    
    update)
        check_container
        echo "🔄 Updating Open WebUI on remote server..."
        echo ""
        ssh "$FRANKEN_SERVER_IP" "docker pull ghcr.io/open-webui/open-webui:main && \
            docker stop $CONTAINER_NAME && \
            docker rm $CONTAINER_NAME && \
            docker run -d \
                -p 3000:8080 \
                --add-host=host.docker.internal:host-gateway \
                -e OLLAMA_BASE_URL=http://host.docker.internal:$FRANKEN_GPU0_PORT \
                -v open-webui:/app/backend/data \
                --name open-webui \
                --restart always \
                ghcr.io/open-webui/open-webui:main"
        
        echo "✅ Updated successfully!"
        show_url
        ;;
    
    remove)
        check_container
        echo "⚠️  This will remove Open WebUI container but keep your data."
        echo -n "Continue? (y/n): "
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            ssh "$FRANKEN_SERVER_IP" "docker rm -f $CONTAINER_NAME"
            echo "✅ Removed from remote server"
            echo ""
            echo "💾 Your data is preserved in Docker volume 'open-webui'"
            echo "To remove data too: ssh $FRANKEN_SERVER_IP 'docker volume rm open-webui'"
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
