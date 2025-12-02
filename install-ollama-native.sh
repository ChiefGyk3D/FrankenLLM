#!/bin/bash
# FrankenLLM - Native installation without Docker - using Ollama binary
# Stitched-together GPUs, but it lives!

SERVER_IP="192.168.201.145"

echo "=== FrankenLLM: Installing Ollama (Native) on $SERVER_IP ==="
echo ""

ssh $SERVER_IP 'bash -s' << 'ENDSSH'
# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Create systemd service for GPU 0 (5060 Ti)
sudo tee /etc/systemd/system/ollama-gpu0.service > /dev/null << 'EOF'
[Unit]
Description=Ollama Service for GPU 0 (RTX 5060 Ti)
After=network-online.target

[Service]
Type=simple
User=chiefgyk3d
Environment="CUDA_VISIBLE_DEVICES=0"
Environment="OLLAMA_HOST=0.0.0.0:11434"
ExecStart=/usr/local/bin/ollama serve
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

# Create systemd service for GPU 1 (3050)
sudo tee /etc/systemd/system/ollama-gpu1.service > /dev/null << 'EOF'
[Unit]
Description=Ollama Service for GPU 1 (RTX 3050)
After=network-online.target

[Service]
Type=simple
User=chiefgyk3d
Environment="CUDA_VISIBLE_DEVICES=1"
Environment="OLLAMA_HOST=0.0.0.0:11435"
ExecStart=/usr/local/bin/ollama serve
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

# Reload systemd
sudo systemctl daemon-reload

echo ""
echo "Ollama installed! Services created but not started."
echo "To start services, run:"
echo "  sudo systemctl start ollama-gpu0"
echo "  sudo systemctl start ollama-gpu1"
echo ""
echo "To enable on boot:"
echo "  sudo systemctl enable ollama-gpu0"
echo "  sudo systemctl enable ollama-gpu1"
ENDSSH

echo ""
echo "=== Installation Complete ==="
echo "Services available at:"
echo "  - RTX 5060 Ti: http://$SERVER_IP:11434"
echo "  - RTX 3050:    http://$SERVER_IP:11435"
