#!/bin/bash
# FrankenLLM - Manage Ollama services on remote server
# Stitched-together GPUs, but it lives!

SERVER_IP="192.168.201.145"
ACTION="${1:-status}"

case $ACTION in
  start)
    echo "Starting Ollama services on $SERVER_IP..."
    ssh $SERVER_IP "sudo systemctl start ollama-gpu0 ollama-gpu1"
    ;;
  stop)
    echo "Stopping Ollama services on $SERVER_IP..."
    ssh $SERVER_IP "sudo systemctl stop ollama-gpu0 ollama-gpu1"
    ;;
  restart)
    echo "Restarting Ollama services on $SERVER_IP..."
    ssh $SERVER_IP "sudo systemctl restart ollama-gpu0 ollama-gpu1"
    ;;
  status)
    echo "=== Ollama Service Status on $SERVER_IP ==="
    echo ""
    echo "GPU 0 (RTX 5060 Ti) - Port 11434:"
    ssh $SERVER_IP "sudo systemctl status ollama-gpu0 --no-pager"
    echo ""
    echo "GPU 1 (RTX 3050) - Port 11435:"
    ssh $SERVER_IP "sudo systemctl status ollama-gpu1 --no-pager"
    ;;
  logs)
    echo "=== Ollama Logs on $SERVER_IP ==="
    echo ""
    echo "GPU 0 (RTX 5060 Ti):"
    ssh $SERVER_IP "sudo journalctl -u ollama-gpu0 -n 50 --no-pager"
    echo ""
    echo "GPU 1 (RTX 3050):"
    ssh $SERVER_IP "sudo journalctl -u ollama-gpu1 -n 50 --no-pager"
    ;;
  enable)
    echo "Enabling Ollama services on boot..."
    ssh $SERVER_IP "sudo systemctl enable ollama-gpu0 ollama-gpu1"
    ;;
  disable)
    echo "Disabling Ollama services on boot..."
    ssh $SERVER_IP "sudo systemctl disable ollama-gpu0 ollama-gpu1"
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|logs|enable|disable}"
    exit 1
    ;;
esac
