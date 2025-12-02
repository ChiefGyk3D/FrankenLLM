#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Local Service Management
# Stitched-together GPUs, but it lives!

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load configuration
source "$PROJECT_ROOT/config.sh"

ACTION="${1:-status}"

# Build service list based on GPU count
SERVICES="ollama-gpu0"
if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
    SERVICES="$SERVICES ollama-gpu1"
fi

case $ACTION in
  start)
    echo "Starting Ollama services..."
    sudo systemctl start $SERVICES
    ;;
  stop)
    echo "Stopping Ollama services..."
    sudo systemctl stop $SERVICES
    ;;
  restart)
    echo "Restarting Ollama services..."
    sudo systemctl restart $SERVICES
    ;;
  status)
    echo "=== Ollama Service Status ==="
    echo ""
    echo "GPU 0 - Port $FRANKEN_GPU0_PORT:"
    sudo systemctl status ollama-gpu0 --no-pager -l | head -15
    if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
        echo ""
        echo "GPU 1 - Port $FRANKEN_GPU1_PORT:"
        sudo systemctl status ollama-gpu1 --no-pager -l | head -15
    fi
    ;;
  logs)
    echo "=== Ollama Logs ==="
    echo ""
    echo "GPU 0:"
    sudo journalctl -u ollama-gpu0 -n 30 --no-pager
    if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
        echo ""
        echo "GPU 1:"
        sudo journalctl -u ollama-gpu1 -n 30 --no-pager
    fi
    ;;
  enable)
    echo "Enabling Ollama services on boot..."
    sudo systemctl enable $SERVICES
    ;;
  disable)
    echo "Disabling Ollama services on boot..."
    sudo systemctl disable $SERVICES
    ;;
  *)
    echo "FrankenLLM - Local Service Management"
    echo ""
    echo "Usage: $0 {start|stop|restart|status|logs|enable|disable}"
    echo ""
    echo "Commands:"
    echo "  start    - Start both Ollama services"
    echo "  stop     - Stop both Ollama services"
    echo "  restart  - Restart both Ollama services"
    echo "  status   - Show service status"
    echo "  logs     - Show recent logs"
    echo "  enable   - Enable services on boot"
    echo "  disable  - Disable services on boot"
    exit 1
    ;;
esac
