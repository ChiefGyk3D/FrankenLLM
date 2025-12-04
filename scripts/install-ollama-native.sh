#!/bin/bash
# FrankenLLM - Install Ollama natively (not in Docker)
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
echo "=== FrankenLLM: Installing Ollama (Native) on $FRANKEN_SERVER_IP ==="
echo ""

# Prepare the installation script
INSTALL_SCRIPT=$(cat << 'ENDSSH'
# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Disable default ollama service if it exists
sudo systemctl stop ollama.service 2>/dev/null || true
sudo systemctl disable ollama.service 2>/dev/null || true

# Create model directories for each GPU (isolated storage)
mkdir -p "$HOME/.ollama/models-gpu0"
mkdir -p "$HOME/.ollama/models-gpu1"

# Create systemd service for GPU 0
sudo tee /etc/systemd/system/ollama-gpu0.service > /dev/null << EOF
[Unit]
Description=Ollama Service for GPU 0 ($FRANKEN_GPU0_NAME)
After=network-online.target

[Service]
Type=simple
User=$USER
Environment="CUDA_VISIBLE_DEVICES=0"
Environment="OLLAMA_HOST=0.0.0.0:$FRANKEN_GPU0_PORT"
Environment="OLLAMA_MODELS=$HOME/.ollama/models-gpu0"
Environment="OLLAMA_KEEP_ALIVE=-1"
ExecStart=/usr/local/bin/ollama serve
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

# Create systemd service for GPU 1
sudo tee /etc/systemd/system/ollama-gpu1.service > /dev/null << EOF
[Unit]
Description=Ollama Service for GPU 1 ($FRANKEN_GPU1_NAME)
After=network-online.target

[Service]
Type=simple
User=$USER
Environment="CUDA_VISIBLE_DEVICES=1"
Environment="OLLAMA_HOST=0.0.0.0:$FRANKEN_GPU1_PORT"
Environment="OLLAMA_MODELS=$HOME/.ollama/models-gpu1"
Environment="OLLAMA_KEEP_ALIVE=-1"
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
)

# Execute the installation script
if [ "$FRANKEN_IS_LOCAL" = true ]; then
    echo "Installing locally..."
    eval "$INSTALL_SCRIPT"
else
    echo "Installing on remote server $FRANKEN_SERVER_IP..."
    echo "NOTE: You will be prompted for your sudo password on the remote server."
    echo ""
    ssh -t "$FRANKEN_SERVER_IP" "FRANKEN_GPU0_PORT=$FRANKEN_GPU0_PORT FRANKEN_GPU1_PORT=$FRANKEN_GPU1_PORT FRANKEN_GPU0_NAME='$FRANKEN_GPU0_NAME' FRANKEN_GPU1_NAME='$FRANKEN_GPU1_NAME' bash -s" << EOF
$INSTALL_SCRIPT
EOF
fi

echo ""
echo "=== Installation Complete ==="
echo "Services available at:"
echo "  - $FRANKEN_GPU0_NAME: http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT"
echo "  - $FRANKEN_GPU1_NAME: http://$FRANKEN_SERVER_IP:$FRANKEN_GPU1_PORT"
