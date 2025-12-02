#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Remote Service Control Helper
# This script provides convenient one-liners for remote service management

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

if [ "$FRANKEN_IS_LOCAL" = true ]; then
    echo "❌ Configuration is set for LOCAL installation."
    exit 1
fi

ACTION="${1:-help}"

case $ACTION in
  start)
    echo "Starting services on $FRANKEN_SERVER_IP..."
    ssh -t "$FRANKEN_SERVER_IP" 'sudo systemctl start ollama-gpu0 ollama-gpu1 && echo "✅ Services started" && sudo systemctl status ollama-gpu0 ollama-gpu1 --no-pager | head -20'
    ;;
  stop)
    echo "Stopping services on $FRANKEN_SERVER_IP..."
    ssh -t "$FRANKEN_SERVER_IP" 'sudo systemctl stop ollama-gpu0 ollama-gpu1 && echo "✅ Services stopped"'
    ;;
  restart)
    echo "Restarting services on $FRANKEN_SERVER_IP..."
    ssh -t "$FRANKEN_SERVER_IP" 'sudo systemctl restart ollama-gpu0 ollama-gpu1 && echo "✅ Services restarted" && sudo systemctl status ollama-gpu0 ollama-gpu1 --no-pager | head -20'
    ;;
  status)
    echo "Checking status on $FRANKEN_SERVER_IP..."
    ssh -t "$FRANKEN_SERVER_IP" 'sudo systemctl status ollama-gpu0 ollama-gpu1 --no-pager'
    ;;
  logs0)
    echo "Viewing GPU 0 logs on $FRANKEN_SERVER_IP..."
    ssh -t "$FRANKEN_SERVER_IP" 'sudo journalctl -u ollama-gpu0 -n 50 -f'
    ;;
  logs1)
    echo "Viewing GPU 1 logs on $FRANKEN_SERVER_IP..."
    ssh -t "$FRANKEN_SERVER_IP" 'sudo journalctl -u ollama-gpu1 -n 50 -f'
    ;;
  logs)
    echo "Viewing recent logs on $FRANKEN_SERVER_IP..."
    ssh -t "$FRANKEN_SERVER_IP" 'echo "=== GPU 0 ===" && sudo journalctl -u ollama-gpu0 -n 20 --no-pager && echo "" && echo "=== GPU 1 ===" && sudo journalctl -u ollama-gpu1 -n 20 --no-pager'
    ;;
  *)
    echo "FrankenLLM - Remote Service Control"
    echo "Target: $FRANKEN_SERVER_IP"
    echo ""
    echo "Usage: $0 {start|stop|restart|status|logs|logs0|logs1}"
    echo ""
    echo "Commands:"
    echo "  start    - Start both services (requires terminal)"
    echo "  stop     - Stop both services"
    echo "  restart  - Restart both services"
    echo "  status   - Show systemctl status"
    echo "  logs     - Show recent logs from both"
    echo "  logs0    - Follow GPU 0 logs (real-time)"
    echo "  logs1    - Follow GPU 1 logs (real-time)"
    echo ""
    echo "Note: Run from a proper terminal (not VS Code integrated terminal)"
    echo "      The VS Code terminal doesn't support interactive SSH properly."
    exit 1
    ;;
esac
