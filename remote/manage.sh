#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Remote Service Management
# Stitched-together GPUs, but it lives!

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

if [ "$FRANKEN_IS_LOCAL" = true ]; then
    echo "❌ Configuration is set for LOCAL installation."
    echo "   Use ./local/manage.sh instead"
    exit 1
fi

ACTION="${1:-status}"

# Build service list based on GPU count
SERVICES="ollama-gpu0"
if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
    SERVICES="$SERVICES ollama-gpu1"
fi

case $ACTION in
  start)
    echo "Starting Ollama services on $FRANKEN_SERVER_IP..."
    echo ""
    echo "To start services, run these commands on the server:"
    echo "  ssh $FRANKEN_SERVER_IP"
    echo "  sudo systemctl start $SERVICES"
    echo ""
    echo "Or run this one-liner:"
    echo "  ssh -t $FRANKEN_SERVER_IP 'sudo systemctl start $SERVICES'"
    ;;
  stop)
    echo "Stopping Ollama services on $FRANKEN_SERVER_IP..."
    echo ""
    echo "To stop services, run these commands on the server:"
    echo "  ssh $FRANKEN_SERVER_IP"
    echo "  sudo systemctl stop $SERVICES"
    echo ""
    echo "Or run this one-liner:"
    echo "  ssh -t $FRANKEN_SERVER_IP 'sudo systemctl stop $SERVICES'"
    ;;
  restart)
    echo "Restarting Ollama services on $FRANKEN_SERVER_IP..."
    echo ""
    echo "To restart services, run these commands on the server:"
    echo "  ssh $FRANKEN_SERVER_IP"
    echo "  sudo systemctl restart $SERVICES"
    echo ""
    echo "Or run this one-liner:"
    echo "  ssh -t $FRANKEN_SERVER_IP 'sudo systemctl restart $SERVICES'"
    ;;
  status)
    echo "=== Ollama Service Status on $FRANKEN_SERVER_IP ==="
    echo ""
    echo "Note: Using health check instead of systemctl (no sudo needed)"
    echo ""
    "$SCRIPT_DIR/../bin/health-check.sh"
    echo ""
    echo "For detailed systemctl status, SSH into the server and run:"
    echo "  ssh $FRANKEN_SERVER_IP"
    echo "  sudo systemctl status $SERVICES"
    ;;
  logs)
    echo "=== Ollama Logs on $FRANKEN_SERVER_IP ==="
    echo ""
    echo "To view logs, SSH into the server:"
    echo "  ssh -t $FRANKEN_SERVER_IP 'sudo journalctl -u ollama-gpu0 -n 30'"
    if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
        echo "  ssh -t $FRANKEN_SERVER_IP 'sudo journalctl -u ollama-gpu1 -n 30'"
    fi
    ;;
  enable)
    echo "Enabling Ollama services on boot on $FRANKEN_SERVER_IP..."
    echo ""
    echo "To enable services on boot, run:"
    echo "  ssh -t $FRANKEN_SERVER_IP 'sudo systemctl enable $SERVICES'"
    ;;
  disable)
    echo "Disabling Ollama services on boot on $FRANKEN_SERVER_IP..."
    echo ""
    echo "To disable services on boot, run:"
    echo "  ssh -t $FRANKEN_SERVER_IP 'sudo systemctl disable $SERVICES'"
    ;;
  health|check)
    echo "=== Health Check on $FRANKEN_SERVER_IP ==="
    echo ""
    MODE="${2:-full}"
    if [ "$MODE" = "quick" ] || [ "$MODE" = "-q" ]; then
        ssh "$FRANKEN_SERVER_IP" 'nvidia-smi &>/dev/null && echo "✓ Quick check passed" || echo "✗ GPU check failed"'
    else
        echo "Running health check via SSH..."
        echo "  ssh -t $FRANKEN_SERVER_IP '$FRANKEN_INSTALL_DIR/scripts/health-check.sh'"
        echo ""
        ssh -t "$FRANKEN_SERVER_IP" "$FRANKEN_INSTALL_DIR/scripts/health-check.sh" 2>/dev/null || \
            echo "Note: Health check script may not be installed on remote. Copy it with:"
            echo "  scp scripts/health-check.sh $FRANKEN_SERVER_IP:$FRANKEN_INSTALL_DIR/scripts/"
    fi
    ;;
  *)
    echo "FrankenLLM - Remote Service Management"
    echo "Target: $FRANKEN_SERVER_IP"
    echo ""
    echo "Usage: $0 {start|stop|restart|status|logs|enable|disable|health}"
    echo ""
    echo "Commands:"
    echo "  start    - Start both Ollama services"
    echo "  stop     - Stop both Ollama services"
    echo "  restart  - Restart both Ollama services"
    echo "  status   - Show service status"
    echo "  logs     - Show recent logs"
    echo "  enable   - Enable services on boot"
    echo "  disable  - Disable services on boot"
    echo "  health   - Run system health check (use 'health quick' for quick check)"
    echo ""
    echo "Note: You'll be prompted for sudo password on the remote server"
    exit 1
    ;;
esac
