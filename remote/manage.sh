#!/bin/bash
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

case $ACTION in
  start)
    echo "Starting Ollama services on $FRANKEN_SERVER_IP..."
    echo ""
    echo "To start services, run these commands on the server:"
    echo "  ssh $FRANKEN_SERVER_IP"
    echo "  sudo systemctl start ollama-gpu0 ollama-gpu1"
    echo ""
    echo "Or run this one-liner:"
    echo "  ssh -t $FRANKEN_SERVER_IP 'sudo systemctl start ollama-gpu0 ollama-gpu1'"
    ;;
  stop)
    echo "Stopping Ollama services on $FRANKEN_SERVER_IP..."
    echo ""
    echo "To stop services, run these commands on the server:"
    echo "  ssh $FRANKEN_SERVER_IP"
    echo "  sudo systemctl stop ollama-gpu0 ollama-gpu1"
    echo ""
    echo "Or run this one-liner:"
    echo "  ssh -t $FRANKEN_SERVER_IP 'sudo systemctl stop ollama-gpu0 ollama-gpu1'"
    ;;
  restart)
    echo "Restarting Ollama services on $FRANKEN_SERVER_IP..."
    echo ""
    echo "To restart services, run these commands on the server:"
    echo "  ssh $FRANKEN_SERVER_IP"
    echo "  sudo systemctl restart ollama-gpu0 ollama-gpu1"
    echo ""
    echo "Or run this one-liner:"
    echo "  ssh -t $FRANKEN_SERVER_IP 'sudo systemctl restart ollama-gpu0 ollama-gpu1'"
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
    echo "  sudo systemctl status ollama-gpu0 ollama-gpu1"
    ;;
  logs)
    echo "=== Ollama Logs on $FRANKEN_SERVER_IP ==="
    echo ""
    echo "To view logs, run these commands on the server:"
    echo "  ssh $FRANKEN_SERVER_IP"
    echo "  sudo journalctl -u ollama-gpu0 -n 30"
    echo "  sudo journalctl -u ollama-gpu1 -n 30"
    echo ""
    echo "Or run these one-liners:"
    echo "  ssh -t $FRANKEN_SERVER_IP 'sudo journalctl -u ollama-gpu0 -n 30'"
    echo "  ssh -t $FRANKEN_SERVER_IP 'sudo journalctl -u ollama-gpu1 -n 30'"
    ;;
  enable)
    echo "Enabling Ollama services on boot on $FRANKEN_SERVER_IP..."
    echo ""
    echo "To enable services on boot, run:"
    echo "  ssh -t $FRANKEN_SERVER_IP 'sudo systemctl enable ollama-gpu0 ollama-gpu1'"
    ;;
  disable)
    echo "Disabling Ollama services on boot on $FRANKEN_SERVER_IP..."
    echo ""
    echo "To disable services on boot, run:"
    echo "  ssh -t $FRANKEN_SERVER_IP 'sudo systemctl disable ollama-gpu0 ollama-gpu1'"
    ;;
  *)
    echo "FrankenLLM - Remote Service Management"
    echo "Target: $FRANKEN_SERVER_IP"
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
    echo ""
    echo "Note: You'll be prompted for sudo password on the remote server"
    exit 1
    ;;
esac
