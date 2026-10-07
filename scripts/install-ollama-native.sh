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

# Disable and MASK default ollama service to prevent it from ever starting
# (even after Ollama updates which may try to re-enable it)
sudo systemctl stop ollama.service 2>/dev/null || true
sudo systemctl disable ollama.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/ollama.service 2>/dev/null || true
sudo systemctl daemon-reload
sudo systemctl mask ollama.service 2>/dev/null || true

# Create model directories for each GPU (isolated storage)
mkdir -p "$HOME/.ollama/models-gpu0"
mkdir -p "$HOME/.ollama/models-gpu1"

# OLLAMA_VULKAN line for the units (see FRANKEN_OLLAMA_VULKAN in config.sh).
# Recent Ollama also finds GPUs through Vulkan, which ignores CUDA_VISIBLE_DEVICES,
# so on NVIDIA an instance can load models onto the other card.
#   auto   -> 0 when nvidia-smi lists a GPU on this machine, else leave Ollama's default
#   0 / 1  -> write exactly that
#   (empty) -> write nothing
case "$FRANKEN_OLLAMA_VULKAN" in
    auto)
        if command -v nvidia-smi > /dev/null 2>&1 && nvidia-smi -L 2> /dev/null | grep -q '^GPU '; then
            VULKAN_VALUE=0
        else
            VULKAN_VALUE=""
        fi
        ;;
    0|1|"") VULKAN_VALUE="$FRANKEN_OLLAMA_VULKAN" ;;
    *)
        echo "ERROR: FRANKEN_OLLAMA_VULKAN must be auto, 0, 1 or empty (got '$FRANKEN_OLLAMA_VULKAN')" >&2
        exit 1
        ;;
esac
if [ -n "$VULKAN_VALUE" ]; then
    VULKAN_LINE="Environment=\"OLLAMA_VULKAN=$VULKAN_VALUE\""
else
    VULKAN_LINE="# OLLAMA_VULKAN not set: Ollama's default applies"
fi

# Create systemd service for GPU 0
sudo tee /etc/systemd/system/ollama-gpu0.service > /dev/null << EOF
[Unit]
Description=Ollama Service for GPU 0 ($FRANKEN_GPU0_NAME)
After=network-online.target

[Service]
Type=simple
User=$USER
Environment="CUDA_VISIBLE_DEVICES=0"
$VULKAN_LINE
Environment="OLLAMA_HOST=0.0.0.0:$FRANKEN_GPU0_PORT"
Environment="OLLAMA_MODELS=$HOME/.ollama/models-gpu0"
Environment="OLLAMA_KEEP_ALIVE=-1"
Environment="OLLAMA_CONTEXT_LENGTH=$FRANKEN_GPU0_CONTEXT"
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
$VULKAN_LINE
Environment="OLLAMA_HOST=0.0.0.0:$FRANKEN_GPU1_PORT"
Environment="OLLAMA_MODELS=$HOME/.ollama/models-gpu1"
Environment="OLLAMA_KEEP_ALIVE=-1"
Environment="OLLAMA_CONTEXT_LENGTH=$FRANKEN_GPU1_CONTEXT"
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
    ssh -t "$FRANKEN_SERVER_IP" "FRANKEN_GPU0_PORT=$FRANKEN_GPU0_PORT FRANKEN_GPU1_PORT=$FRANKEN_GPU1_PORT FRANKEN_GPU0_NAME='$FRANKEN_GPU0_NAME' FRANKEN_GPU1_NAME='$FRANKEN_GPU1_NAME' FRANKEN_GPU0_CONTEXT=$FRANKEN_GPU0_CONTEXT FRANKEN_GPU1_CONTEXT=$FRANKEN_GPU1_CONTEXT FRANKEN_OLLAMA_VULKAN='$FRANKEN_OLLAMA_VULKAN' bash -s" << EOF
$INSTALL_SCRIPT
EOF
fi

echo ""
echo "=== Installation Complete ==="
echo "Services available at:"
echo "  - $FRANKEN_GPU0_NAME: http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT"
echo "  - $FRANKEN_GPU1_NAME: http://$FRANKEN_SERVER_IP:$FRANKEN_GPU1_PORT"
