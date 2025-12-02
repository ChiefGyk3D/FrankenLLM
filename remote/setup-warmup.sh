#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Setup Remote Warmup Service
# This script configures automatic model warmup on boot for a remote server

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

if [ "$FRANKEN_IS_LOCAL" = true ]; then
    echo "❌ This script is for REMOTE installations only."
    echo "   For local installations, warmup is configured during install."
    exit 1
fi

echo "╔════════════════════════════════════════════════════════════╗"
echo "║     FrankenLLM - Setup Remote Warmup Service              ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Target Server: $FRANKEN_SERVER_IP"
echo ""
echo "This will:"
echo "  1. Copy warmup scripts to the remote server"
echo "  2. Create a systemd service for auto-warmup on boot"
echo "  3. Enable the service to run after Ollama starts"
echo ""
read -p "Continue? (y/N): " confirm
if [[ ! $confirm =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# Determine remote install directory
REMOTE_DIR="$FRANKEN_INSTALL_DIR"

echo ""
echo "Creating remote directory structure..."
ssh "$FRANKEN_SERVER_IP" "mkdir -p $REMOTE_DIR/bin"

echo "Copying configuration files..."
scp "$SCRIPT_DIR/../.env" "$FRANKEN_SERVER_IP:$REMOTE_DIR/.env"
scp "$SCRIPT_DIR/../config.sh" "$FRANKEN_SERVER_IP:$REMOTE_DIR/config.sh"

echo "Copying warmup scripts..."
scp "$SCRIPT_DIR/../bin/warmup-models.sh" "$FRANKEN_SERVER_IP:$REMOTE_DIR/bin/"
scp "$SCRIPT_DIR/../bin/warmup-on-boot.sh" "$FRANKEN_SERVER_IP:$REMOTE_DIR/bin/"

echo "Making scripts executable..."
ssh "$FRANKEN_SERVER_IP" "chmod +x $REMOTE_DIR/bin/*.sh"

echo ""
echo "Creating systemd service on remote server..."
echo "You may be prompted for your sudo password..."

ssh -t "$FRANKEN_SERVER_IP" "sudo tee /etc/systemd/system/frankenllm-warmup.service > /dev/null << 'EOF'
[Unit]
Description=FrankenLLM Model Warmup
After=ollama-gpu0.service ollama-gpu1.service
Wants=ollama-gpu0.service ollama-gpu1.service

[Service]
Type=oneshot
User=$USER
WorkingDirectory=$REMOTE_DIR
ExecStart=$REMOTE_DIR/bin/warmup-on-boot.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
"

echo ""
echo "Enabling warmup service..."
ssh -t "$FRANKEN_SERVER_IP" "sudo systemctl daemon-reload && sudo systemctl enable frankenllm-warmup.service"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║           Warmup Service Setup Complete! ✅                ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "The warmup service will:"
echo "  - Start automatically after system boot"
echo "  - Wait for Ollama services to be ready"
echo "  - Load your configured models into GPU memory"
echo ""
echo "To test warmup now:"
echo "  ssh $FRANKEN_SERVER_IP 'cd $REMOTE_DIR && ./bin/warmup-models.sh'"
echo ""
echo "To check service status:"
echo "  ssh $FRANKEN_SERVER_IP 'sudo systemctl status frankenllm-warmup'"
echo ""
echo "To view warmup logs:"
echo "  ssh $FRANKEN_SERVER_IP 'sudo journalctl -u frankenllm-warmup'"
