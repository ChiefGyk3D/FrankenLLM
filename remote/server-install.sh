#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - server-side installer. NOT run directly: remote/install.sh joins
# remote/unit-lib.sh (the helper functions used below) and this file into one
# script, copies it into a private directory on the target and runs it there.
# Arguments: GPU0_PORT GPU1_PORT BIND_ADDR SERVICE_USER MEMORY_MAX TASKS_MAX
#            OLLAMA_PIN REQUIRE_GPU OLLAMA_SHA256 OLLAMA_SHA256_ASSET
#            ALLOW_UNVERIFIED_OLLAMA
set -e

GPU0_PORT="${1:-11434}"
GPU1_PORT="${2:-11435}"
BIND_ADDR="${3:-}"
SERVICE_USER="${4:-}"
MEMORY_MAX="${5:-}"
TASKS_MAX="${6:-}"
OLLAMA_PIN="${7:-}"
REQUIRE_GPU="${8:-}"
OLLAMA_SHA256="${9:-}"
OLLAMA_SHA256_ASSET="${10:-}"
ALLOW_UNVERIFIED_OLLAMA="${11:-}"

for v in "$BIND_ADDR:franken_valid_bind_addr" "$SERVICE_USER:franken_valid_service_user" \
         "$MEMORY_MAX:franken_valid_memory_max" "$TASKS_MAX:franken_valid_tasks_max" \
         "$OLLAMA_PIN:franken_valid_ollama_version" "$REQUIRE_GPU:franken_valid_require_gpu"; do
    if [ -n "${v%%:*}" ] && ! "${v##*:}" "${v%%:*}"; then
        echo "❌ Invalid value for ${v##*:}"
        exit 1
    fi
done
if [ -n "$OLLAMA_SHA256" ] && { ! franken_valid_sha256 "$OLLAMA_SHA256" || [ -z "$OLLAMA_PIN" ]; }; then
    echo "❌ The Ollama checksum must be a lowercase sha256 and needs a pinned version"
    exit 1
fi
if [ -n "$OLLAMA_SHA256_ASSET" ] && ! [[ "$OLLAMA_SHA256_ASSET" =~ ^ollama-linux-[a-z0-9]+\.tar\.zst$ ]]; then
    echo "❌ Invalid Ollama asset name"
    exit 1
fi
if [ -n "$ALLOW_UNVERIFIED_OLLAMA" ] && ! franken_valid_require_gpu "$ALLOW_UNVERIFIED_OLLAMA"; then
    echo "❌ FRANKEN_ALLOW_UNVERIFIED_OLLAMA must be true or false"
    exit 1
fi
for p in "$GPU0_PORT" "$GPU1_PORT"; do
    if ! franken_valid_port "$p"; then
        echo "❌ GPU ports must be decimal numbers from 1 to 65535"
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

# Absolute nvidia-smi path for the optional ExecStartPre guard (systemd needs
# an absolute path). Only resolved and checked when the guard is on.
NVIDIA_SMI_PATH=""
if [ "$REQUIRE_GPU" = "true" ]; then
    NVIDIA_SMI_PATH="$(command -v nvidia-smi || true)"
    if ! franken_valid_nvidia_smi_path "$NVIDIA_SMI_PATH"; then
        echo "❌ FRANKEN_REQUIRE_GPU=true but nvidia-smi has no usable absolute path (found: '${NVIDIA_SMI_PATH}')"
        echo "   It must match ^/[A-Za-z0-9/_.-]+$ ; install the NVIDIA driver tools or unset the guard."
        exit 1
    fi
    echo "✅ GPU guard on: units will run $NVIDIA_SMI_PATH -L before ollama starts"
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
# An existing install is kept unless a pin is set and it differs.
INSTALLED_VERSION=""
if command -v ollama &> /dev/null; then
    INSTALLED_VERSION="$(franken_ollama_parse_version "$(ollama --version 2>&1 || true)")"
fi
if [ -n "$INSTALLED_VERSION" ] && { [ -z "$OLLAMA_PIN" ] || [ "$INSTALLED_VERSION" = "$OLLAMA_PIN" ]; }; then
    echo "✅ Ollama already installed"
else
    # Default path: a pinned version plus a known sha256. Network bytes are never
    # piped into a shell. Anything less fails closed unless the operator said,
    # explicitly, that an unverified install is acceptable.
    OLLAMA_ASSET="$(franken_ollama_asset)" || OLLAMA_ASSET=""
    if [ -n "$OLLAMA_PIN" ] && [ -n "$OLLAMA_SHA256" ]; then
        if [ -z "$OLLAMA_ASSET" ]; then
            echo "❌ Unsupported CPU architecture for the Ollama release: $(uname -m)"
            exit 1
        fi
        if [ -n "$OLLAMA_SHA256_ASSET" ] && [ "$OLLAMA_SHA256_ASSET" != "$OLLAMA_ASSET" ]; then
            echo "❌ The recorded checksum is for $OLLAMA_SHA256_ASSET but this server needs $OLLAMA_ASSET."
            echo "   Set FRANKEN_OLLAMA_SHA256 to the sha256 of $OLLAMA_ASSET for version $OLLAMA_PIN."
            exit 1
        fi
        echo "Installing Ollama $OLLAMA_PIN from the pinned release asset (sha256 checked before extraction)..."
        franken_ollama_install_verified "$OLLAMA_PIN" "$OLLAMA_SHA256" "$OLLAMA_ASSET" /usr/local sudo
    elif [ "$ALLOW_UNVERIFIED_OLLAMA" = "true" ]; then
        franken_ollama_unverified_install "$OLLAMA_PIN"
    else
        echo "❌ Refusing to install Ollama without a pinned version and a checksum."
        echo "   Set FRANKEN_OLLAMA_VERSION to a version listed in remote/ollama-checksums.txt (e.g. 0.33.2),"
        echo "   or set FRANKEN_OLLAMA_VERSION together with FRANKEN_OLLAMA_SHA256."
        echo "   To accept an unverified download of the upstream install script instead, set"
        echo "   FRANKEN_ALLOW_UNVERIFIED_OLLAMA=true (not recommended)."
        exit 1
    fi
    echo "✅ Ollama installed"
fi
FINAL_VERSION="$(franken_ollama_parse_version "$(ollama --version 2>&1 || true)")"
echo "Ollama version: ${FINAL_VERSION:-unknown}"
if [ -n "$OLLAMA_PIN" ] && [ "$FINAL_VERSION" != "$OLLAMA_PIN" ]; then
    echo "❌ Pinned Ollama $OLLAMA_PIN but the installed version is ${FINAL_VERSION:-unknown}"
    exit 1
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
    if [ "$(id -u "$SERVICE_USER")" -eq 0 ]; then
        echo "❌ Account $SERVICE_USER has uid 0; refusing to run the units as root"
        exit 1
    fi
    # GPU device nodes are often limited to the video or render group.
    GPU_GROUPS="$(franken_gpu_groups)"
    if [ -n "$GPU_GROUPS" ]; then
        sudo usermod -aG "$GPU_GROUPS" "$SERVICE_USER"
        echo "✅ Added $SERVICE_USER to groups: $GPU_GROUPS"
    else
        echo "⚠️  No video or render group found; GPU access for $SERVICE_USER is unchanged"
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
franken_render_unit 0 "$GPU0_PORT" "$MODELS_BASE/models-gpu0" "$UNIT_USER" "$BIND_ADDR" "$MEMORY_MAX" "$TASKS_MAX" "$REQUIRE_GPU" "$NVIDIA_SMI_PATH" \
    | sudo tee /etc/systemd/system/ollama-gpu0.service > /dev/null

if [ "$GPU_COUNT" -ge 2 ]; then
    # Create systemd service for GPU 1
    echo "Creating systemd service for GPU 1 (port $GPU1_PORT)..."
    franken_render_unit 1 "$GPU1_PORT" "$MODELS_BASE/models-gpu1" "$UNIT_USER" "$BIND_ADDR" "$MEMORY_MAX" "$TASKS_MAX" "$REQUIRE_GPU" "$NVIDIA_SMI_PATH" \
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
