#!/bin/bash
# FrankenLLM - Manage Ollama services on remote server
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

ACTION="${1:-status}"

case $ACTION in
  start)
    echo "Starting Ollama services on $FRANKEN_SERVER_IP..."
    franken_exec "sudo systemctl start ollama-gpu0 ollama-gpu1"
    ;;
  stop)
    echo "Stopping Ollama services on $FRANKEN_SERVER_IP..."
    franken_exec "sudo systemctl stop ollama-gpu0 ollama-gpu1"
    ;;
  restart)
    echo "Restarting Ollama services on $FRANKEN_SERVER_IP..."
    franken_exec "sudo systemctl restart ollama-gpu0 ollama-gpu1"
    ;;
  status)
    echo "=== Ollama Service Status on $FRANKEN_SERVER_IP ==="
    echo ""
    echo "GPU 0 ($FRANKEN_GPU0_NAME) - Port $FRANKEN_GPU0_PORT:"
    franken_exec "sudo systemctl status ollama-gpu0 --no-pager"
    echo ""
    echo "GPU 1 ($FRANKEN_GPU1_NAME) - Port $FRANKEN_GPU1_PORT:"
    franken_exec "sudo systemctl status ollama-gpu1 --no-pager"
    ;;
  logs)
    echo "=== Ollama Logs on $FRANKEN_SERVER_IP ==="
    echo ""
    echo "GPU 0 ($FRANKEN_GPU0_NAME):"
    franken_exec "sudo journalctl -u ollama-gpu0 -n 50 --no-pager"
    echo ""
    echo "GPU 1 ($FRANKEN_GPU1_NAME):"
    franken_exec "sudo journalctl -u ollama-gpu1 -n 50 --no-pager"
    ;;
  enable)
    echo "Enabling Ollama services on boot..."
    franken_exec "sudo systemctl enable ollama-gpu0 ollama-gpu1"
    ;;
  disable)
    echo "Disabling Ollama services on boot..."
    franken_exec "sudo systemctl disable ollama-gpu0 ollama-gpu1"
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|logs|enable|disable}"
    exit 1
    ;;
esac
