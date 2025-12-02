#!/bin/bash
# FrankenLLM - Local Service Management
# Stitched-together GPUs, but it lives!

ACTION="${1:-status}"

case $ACTION in
  start)
    echo "Starting Ollama services..."
    sudo systemctl start ollama-gpu0 ollama-gpu1
    ;;
  stop)
    echo "Stopping Ollama services..."
    sudo systemctl stop ollama-gpu0 ollama-gpu1
    ;;
  restart)
    echo "Restarting Ollama services..."
    sudo systemctl restart ollama-gpu0 ollama-gpu1
    ;;
  status)
    echo "=== Ollama Service Status ==="
    echo ""
    echo "GPU 0 - Port 11434:"
    sudo systemctl status ollama-gpu0 --no-pager -l | head -15
    echo ""
    echo "GPU 1 - Port 11435:"
    sudo systemctl status ollama-gpu1 --no-pager -l | head -15
    ;;
  logs)
    echo "=== Ollama Logs ==="
    echo ""
    echo "GPU 0:"
    sudo journalctl -u ollama-gpu0 -n 30 --no-pager
    echo ""
    echo "GPU 1:"
    sudo journalctl -u ollama-gpu1 -n 30 --no-pager
    ;;
  enable)
    echo "Enabling Ollama services on boot..."
    sudo systemctl enable ollama-gpu0 ollama-gpu1
    ;;
  disable)
    echo "Disabling Ollama services on boot..."
    sudo systemctl disable ollama-gpu0 ollama-gpu1
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
