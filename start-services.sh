#!/bin/bash
# FrankenLLM - Start services via SSH with terminal
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

if [ "$FRANKEN_IS_LOCAL" = true ]; then
    echo "Starting services locally..."
    sudo systemctl start ollama-gpu0 ollama-gpu1
    sudo systemctl status ollama-gpu0 ollama-gpu1 --no-pager
else
    echo "=== Starting Ollama services on $FRANKEN_SERVER_IP ==="
    echo ""
    ssh -t "$FRANKEN_SERVER_IP" << 'ENDSSH'
sudo systemctl start ollama-gpu0 ollama-gpu1
echo ""
echo "Service Status:"
sudo systemctl status ollama-gpu0 --no-pager -l
echo ""
sudo systemctl status ollama-gpu1 --no-pager -l
ENDSSH
fi

echo ""
echo "Checking health..."
sleep 2
./health-check.sh
