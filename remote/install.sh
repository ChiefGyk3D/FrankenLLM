#!/bin/bash
# FrankenLLM - Remote Installation
# Stitched-together GPUs, but it lives!
#
# This script copies the local installer to a remote server and runs it there

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

if [ "$FRANKEN_IS_LOCAL" = true ]; then
    echo "❌ Configuration is set for LOCAL installation."
    echo "   Change FRANKEN_SERVER_IP in .env to your remote server's IP address."
    echo "   Or run: ./configure.sh"
    exit 1
fi

echo "╔════════════════════════════════════════════════════════════╗"
echo "║           FrankenLLM - Remote Installation                 ║"
echo "║        Stitched-together GPUs, but it lives!               ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Target Server: $FRANKEN_SERVER_IP"
echo "GPU 0 Port: $FRANKEN_GPU0_PORT"
echo "GPU 1 Port: $FRANKEN_GPU1_PORT"
echo ""
echo "This will install Ollama on the remote server with separate"
echo "services for each GPU."
echo ""
echo "Press Ctrl+C to cancel, or Enter to continue..."
read

# Test SSH connection
echo "Testing SSH connection to $FRANKEN_SERVER_IP..."
if ! ssh -q "$FRANKEN_SERVER_IP" exit; then
    echo "❌ Cannot connect to $FRANKEN_SERVER_IP via SSH"
    echo "   Make sure:"
    echo "   1. The server is reachable"
    echo "   2. SSH keys are set up or you know the password"
    echo "   3. Your user has sudo access on the remote server"
    exit 1
fi
echo "✅ SSH connection successful"
echo ""

# Create the installation script
cat > /tmp/frankenllm-remote-install.sh << 'ENDSCRIPT'
#!/bin/bash
set -e

GPU0_PORT="${1:-11434}"
GPU1_PORT="${2:-11435}"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║         FrankenLLM Remote Installation Starting...         ║"
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
    echo "✅ Ollama already installed"
else
    curl -fsSL https://ollama.com/install.sh | sh
    echo "✅ Ollama installed"
fi
echo ""

# Create systemd service for GPU 0
echo "Creating systemd service for GPU 0 (port $GPU0_PORT)..."
sudo tee /etc/systemd/system/ollama-gpu0.service > /dev/null << EOF
[Unit]
Description=Ollama Service for GPU 0
After=network-online.target

[Service]
Type=simple
User=$USER
Environment="CUDA_VISIBLE_DEVICES=0"
Environment="OLLAMA_HOST=0.0.0.0:$GPU0_PORT"
ExecStart=/usr/local/bin/ollama serve
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

if [ "$GPU_COUNT" -ge 2 ]; then
    # Create systemd service for GPU 1
    echo "Creating systemd service for GPU 1 (port $GPU1_PORT)..."
    sudo tee /etc/systemd/system/ollama-gpu1.service > /dev/null << EOF
[Unit]
Description=Ollama Service for GPU 1
After=network-online.target

[Service]
Type=simple
User=$USER
Environment="CUDA_VISIBLE_DEVICES=1"
Environment="OLLAMA_HOST=0.0.0.0:$GPU1_PORT"
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
echo "Services available at:"
echo "  - GPU 0: http://0.0.0.0:$GPU0_PORT"
if [ "$GPU_COUNT" -ge 2 ]; then
    echo "  - GPU 1: http://0.0.0.0:$GPU1_PORT"
fi
echo ""
echo "Check status: sudo systemctl status ollama-gpu0 ollama-gpu1"
ENDSCRIPT

# Copy script to remote server
echo "Copying installation script to $FRANKEN_SERVER_IP..."
scp /tmp/frankenllm-remote-install.sh "$FRANKEN_SERVER_IP:/tmp/" > /dev/null 2>&1

# SSH into remote and run installation
echo ""
echo "Connecting to $FRANKEN_SERVER_IP and running installation..."
echo "You will be prompted for sudo password on the remote server."
echo ""

ssh -t "$FRANKEN_SERVER_IP" "bash /tmp/frankenllm-remote-install.sh $FRANKEN_GPU0_PORT $FRANKEN_GPU1_PORT && rm /tmp/frankenllm-remote-install.sh"

# Cleanup local temp file
rm /tmp/frankenllm-remote-install.sh

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║              Remote Installation Complete! ✅              ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Next steps:"
echo "  1. Test connection: ./bin/health-check.sh"
echo "  2. Pull models: ./bin/pull-dual-models.sh gemma3:12b gemma3:4b"
echo "  3. Test LLMs: ./bin/test-llm.sh"
echo ""
echo "Manage services: ./remote/manage.sh {start|stop|restart|status}"
