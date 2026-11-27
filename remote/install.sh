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
# Optional hardening settings (all unset by default = unchanged behavior).
# Validate here, before anything is copied to the server.
source "$SCRIPT_DIR/unit-lib.sh"
FRANKEN_BIND_ADDR="${FRANKEN_BIND_ADDR:-}"
FRANKEN_SERVICE_USER="${FRANKEN_SERVICE_USER:-}"
FRANKEN_MEMORY_MAX="${FRANKEN_MEMORY_MAX:-}"
FRANKEN_TASKS_MAX="${FRANKEN_TASKS_MAX:-}"
if [ -n "$FRANKEN_BIND_ADDR" ] && ! franken_valid_bind_addr "$FRANKEN_BIND_ADDR"; then
    echo "❌ FRANKEN_BIND_ADDR must be an IPv4 address (e.g. 192.0.2.10)"
    exit 1
fi
if [ -n "$FRANKEN_SERVICE_USER" ] && ! franken_valid_service_user "$FRANKEN_SERVICE_USER"; then
    echo "❌ FRANKEN_SERVICE_USER must match ^[a-z_][a-z0-9_-]{0,31}$"
    exit 1
fi
if [ -n "$FRANKEN_MEMORY_MAX" ] && ! franken_valid_memory_max "$FRANKEN_MEMORY_MAX"; then
    echo "❌ FRANKEN_MEMORY_MAX must be a number with optional K/M/G/T (e.g. 24G) or infinity"
    exit 1
fi
if [ -n "$FRANKEN_TASKS_MAX" ] && ! franken_valid_tasks_max "$FRANKEN_TASKS_MAX"; then
    echo "❌ FRANKEN_TASKS_MAX must be a positive integer or infinity"
    exit 1
fi

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
BIND_ADDR="${3:-}"
SERVICE_USER="${4:-}"
MEMORY_MAX="${5:-}"
TASKS_MAX="${6:-}"

# --- unit-lib.sh is appended here by remote/install.sh ---
ENDSCRIPT
cat "$SCRIPT_DIR/unit-lib.sh" >> /tmp/frankenllm-remote-install.sh
cat >> /tmp/frankenllm-remote-install.sh << 'ENDSCRIPT'

for v in "$BIND_ADDR:franken_valid_bind_addr" "$SERVICE_USER:franken_valid_service_user" \
         "$MEMORY_MAX:franken_valid_memory_max" "$TASKS_MAX:franken_valid_tasks_max"; do
    if [ -n "${v%%:*}" ] && ! "${v##*:}" "${v%%:*}"; then
        echo "❌ Invalid value for ${v##*:}"
        exit 1
    fi
done

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

# Disable and MASK default Ollama service to prevent it from ever starting
# (even after Ollama updates which may try to re-enable it)
echo "Disabling and masking default ollama service..."
sudo systemctl stop ollama.service 2>/dev/null || true
sudo systemctl disable ollama.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/ollama.service 2>/dev/null || true
sudo systemctl daemon-reload
sudo systemctl mask ollama.service 2>/dev/null || true
echo "✅ Default ollama.service masked (permanently prevented from starting)"

# Service account: default is the invoking user. FRANKEN_SERVICE_USER creates a
# system account (nologin shell, own home for models) when it is missing.
if [ -n "$SERVICE_USER" ]; then
    if ! id "$SERVICE_USER" &> /dev/null; then
        echo "Creating system account $SERVICE_USER..."
        sudo useradd --system --create-home --home-dir "/var/lib/$SERVICE_USER" \
            --shell /usr/sbin/nologin "$SERVICE_USER"
    fi
    UNIT_USER="$SERVICE_USER"
    MODELS_BASE="$(getent passwd "$SERVICE_USER" | cut -d: -f6)/.ollama"
    else
    UNIT_USER="$USER"
    MODELS_BASE="$HOME/.ollama"
fi

# Create isolated model directories for each GPU
echo "Creating isolated model directories..."
if [ -n "$SERVICE_USER" ]; then
    sudo install -d -o "$SERVICE_USER" -m 0750 "$MODELS_BASE" "$MODELS_BASE/models-gpu0" "$MODELS_BASE/models-gpu1"
else
    mkdir -p "$MODELS_BASE/models-gpu0"
    mkdir -p "$MODELS_BASE/models-gpu1"
fi

# Create systemd service for GPU 0
echo "Creating systemd service for GPU 0 (port $GPU0_PORT)..."
franken_render_unit 0 "$GPU0_PORT" "$MODELS_BASE/models-gpu0" "$UNIT_USER" "$BIND_ADDR" "$MEMORY_MAX" "$TASKS_MAX" \
    | sudo tee /etc/systemd/system/ollama-gpu0.service > /dev/null

if [ "$GPU_COUNT" -ge 2 ]; then
    # Create systemd service for GPU 1
    echo "Creating systemd service for GPU 1 (port $GPU1_PORT)..."
    franken_render_unit 1 "$GPU1_PORT" "$MODELS_BASE/models-gpu1" "$UNIT_USER" "$BIND_ADDR" "$MEMORY_MAX" "$TASKS_MAX" \
        | sudo tee /etc/systemd/system/ollama-gpu1.service > /dev/null
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
echo "  - GPU 0: http://${BIND_ADDR:-0.0.0.0}:$GPU0_PORT"
if [ "$GPU_COUNT" -ge 2 ]; then
    echo "  - GPU 1: http://${BIND_ADDR:-0.0.0.0}:$GPU1_PORT"
fi
echo ""
echo "⚠️  Note: Auto-warmup service will be configured from your local machine."
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

ssh -t "$FRANKEN_SERVER_IP" "bash /tmp/frankenllm-remote-install.sh $FRANKEN_GPU0_PORT $FRANKEN_GPU1_PORT '$FRANKEN_BIND_ADDR' '$FRANKEN_SERVICE_USER' '$FRANKEN_MEMORY_MAX' '$FRANKEN_TASKS_MAX' && rm /tmp/frankenllm-remote-install.sh"

# Cleanup local temp file
rm /tmp/frankenllm-remote-install.sh

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║              Remote Installation Complete! ✅              ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Next steps:"
echo "  1. Test connection: ./bin/health-check.sh"
echo "  2. Pull models: ./bin/pull-dual-models.sh gemma4:12b gemma3:4b"
echo "  3. Setup auto-warmup: ./remote/setup-warmup.sh"
echo "  4. Test LLMs: ./bin/test-llm.sh"
echo ""
echo "Manage services: ./remote/manage.sh {start|stop|restart|status}"
