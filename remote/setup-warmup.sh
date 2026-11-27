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

# The readiness check uses FRANKEN_BIND_ADDR when set, so validate it first.
source "$SCRIPT_DIR/unit-lib.sh"
FRANKEN_BIND_ADDR="${FRANKEN_BIND_ADDR:-}"
if [ -n "$FRANKEN_BIND_ADDR" ] && ! franken_valid_bind_addr "$FRANKEN_BIND_ADDR"; then
    echo "❌ FRANKEN_BIND_ADDR must be an IPv4 address (e.g. 192.0.2.10)"
    exit 1
fi

# The install directory ends up in remote commands and in unit directives, so it
# must be an absolute, normalized path with a conservative character set. The
# host must look like a host (never an ssh option).
REMOTE_DIR="$FRANKEN_INSTALL_DIR"
if ! franken_valid_install_dir "$REMOTE_DIR"; then
    echo "❌ FRANKEN_INSTALL_DIR must be an absolute path of letters, digits, . _ - and / only"
    echo "   (no empty, . or .. components; at most 200 characters)"
    exit 1
fi
if ! franken_valid_ssh_host "$FRANKEN_SERVER_IP"; then
    echo "❌ FRANKEN_SERVER_IP must be a host name or address (optionally user@host)"
    exit 1
fi

echo ""
echo "Creating remote directory structure..."
ssh -t -- "$FRANKEN_SERVER_IP" "$(franken_sh_quote bash -c \
    'sudo mkdir -p -- "$1/bin" && sudo chown "$(id -un):$(id -gn)" "$1" "$1/bin"' _ "$REMOTE_DIR")"

echo "Copying configuration files..."
scp -- "$SCRIPT_DIR/../.env" "$FRANKEN_SERVER_IP:$REMOTE_DIR/.env"
scp -- "$SCRIPT_DIR/../config.sh" "$FRANKEN_SERVER_IP:$REMOTE_DIR/config.sh"

echo "Copying warmup scripts..."
scp -- "$SCRIPT_DIR/../bin/warmup-models.sh" "$FRANKEN_SERVER_IP:$REMOTE_DIR/bin/"
scp -- "$SCRIPT_DIR/../bin/warmup-lib.sh" "$FRANKEN_SERVER_IP:$REMOTE_DIR/bin/"
scp -- "$SCRIPT_DIR/../bin/warmup-on-boot.sh" "$FRANKEN_SERVER_IP:$REMOTE_DIR/bin/"
scp -- "$SCRIPT_DIR/unit-lib.sh" "$FRANKEN_SERVER_IP:$REMOTE_DIR/bin/"

echo "Making scripts executable..."
ssh -- "$FRANKEN_SERVER_IP" "$(franken_sh_quote bash -c 'chmod +x -- "$1"/bin/*.sh' _ "$REMOTE_DIR")"

echo ""
echo "Creating systemd service on remote server..."
echo "You may be prompted for your sudo password..."

# The unit is rendered ON the server from the copied unit-lib.sh, which
# revalidates the directory and the account name (franken_render_warmup_unit),
# is checked with systemd-analyze when available, and is installed atomically.
RENDER_SCRIPT='set -e
d=$1
lib="$d/bin/unit-lib.sh"
if [ ! -f "$lib" ] || [ -L "$lib" ] || [ "$(stat -c %u "$lib")" != "$(id -u)" ]; then
    echo "unit-lib.sh is missing or not owned by you" >&2; exit 1
fi
. "$lib"
tmp=$(mktemp)
trap "rm -f \"$tmp\"" EXIT
franken_render_warmup_unit "$d" "$(id -un)" > "$tmp"
if command -v systemd-analyze > /dev/null 2>&1; then systemd-analyze verify "$tmp"; fi
sudo install -m 0644 -o root -g root "$tmp" /etc/systemd/system/.frankenllm-warmup.service.new
sudo mv -f /etc/systemd/system/.frankenllm-warmup.service.new /etc/systemd/system/frankenllm-warmup.service'
ssh -t -- "$FRANKEN_SERVER_IP" "$(franken_sh_quote bash -c "$RENDER_SCRIPT" _ "$REMOTE_DIR")"

echo ""
echo "Enabling warmup service..."
ssh -t -- "$FRANKEN_SERVER_IP" "sudo systemctl daemon-reload && sudo systemctl enable frankenllm-warmup.service"

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
