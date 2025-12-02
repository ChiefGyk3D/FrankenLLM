#!/bin/bash
# FrankenLLM - Local Installation
# Stitched-together GPUs, but it lives!
#
# This script installs Ollama locally on THIS machine

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║            FrankenLLM - Local Installation                 ║"
echo "║        Stitched-together GPUs, but it lives!               ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    echo "❌ Please do not run this script as root"
    echo "   The script will ask for sudo password when needed"
    exit 1
fi

# Check for NVIDIA GPUs
echo "Checking for NVIDIA GPUs..."
if ! command -v nvidia-smi &> /dev/null; then
    echo "❌ nvidia-smi not found. Please install NVIDIA drivers first."
    exit 1
fi

GPU_COUNT=$(nvidia-smi --list-gpus | wc -l)
echo "✅ Found $GPU_COUNT NVIDIA GPU(s)"
nvidia-smi --list-gpus
echo ""

if [ "$GPU_COUNT" -lt 2 ]; then
    echo "⚠️  Warning: FrankenLLM is designed for 2 GPUs, but only $GPU_COUNT found."
    echo "   Installation will continue, but you'll only have one Ollama instance."
    echo ""
fi

# Install Ollama
echo "Installing Ollama..."
if command -v ollama &> /dev/null; then
    echo "✅ Ollama already installed: $(ollama --version)"
else
    curl -fsSL https://ollama.com/install.sh | sh
    echo "✅ Ollama installed"
fi
echo ""

# Create systemd service for GPU 0
echo "Creating systemd service for GPU 0..."
sudo tee /etc/systemd/system/ollama-gpu0.service > /dev/null << EOF
[Unit]
Description=Ollama Service for GPU 0
After=network-online.target

[Service]
Type=simple
User=$USER
Environment="CUDA_VISIBLE_DEVICES=0"
Environment="OLLAMA_HOST=0.0.0.0:11434"
ExecStart=/usr/local/bin/ollama serve
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

if [ "$GPU_COUNT" -ge 2 ]; then
    # Create systemd service for GPU 1
    echo "Creating systemd service for GPU 1..."
    sudo tee /etc/systemd/system/ollama-gpu1.service > /dev/null << EOF
[Unit]
Description=Ollama Service for GPU 1
After=network-online.target

[Service]
Type=simple
User=$USER
Environment="CUDA_VISIBLE_DEVICES=1"
Environment="OLLAMA_HOST=0.0.0.0:11435"
ExecStart=/usr/local/bin/ollama serve
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
fi

# Reload systemd
echo "Reloading systemd..."
sudo systemctl daemon-reload

# Start services
echo "Starting services..."
sudo systemctl start ollama-gpu0
if [ "$GPU_COUNT" -ge 2 ]; then
    sudo systemctl start ollama-gpu1
fi

# Enable on boot
echo "Enabling services on boot..."
sudo systemctl enable ollama-gpu0
if [ "$GPU_COUNT" -ge 2 ]; then
    sudo systemctl enable ollama-gpu1
fi

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                Installation Complete! ✅                    ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Services Status:"
sudo systemctl status ollama-gpu0 --no-pager -l | head -10
if [ "$GPU_COUNT" -ge 2 ]; then
    echo ""
    sudo systemctl status ollama-gpu1 --no-pager -l | head -10
fi

echo ""
echo "Services available at:"
echo "  - GPU 0: http://localhost:11434"
if [ "$GPU_COUNT" -ge 2 ]; then
    echo "  - GPU 1: http://localhost:11435"
fi
echo ""
echo "Next steps:"
echo "  1. Run: ./local/manage.sh status"
echo "  2. Pull models: ./bin/pull-dual-models.sh gemma3:12b gemma3:4b"
echo "  3. Test: ./bin/test-llm.sh"
