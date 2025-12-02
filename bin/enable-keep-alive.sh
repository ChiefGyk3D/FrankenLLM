#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Enable OLLAMA_KEEP_ALIVE=-1 on existing Ollama services
# This keeps models loaded in GPU memory indefinitely

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load configuration
source "$PROJECT_ROOT/config.sh"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║     Enabling Keep-Alive for Ollama Services               ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "This will configure Ollama to keep models loaded in GPU memory"
echo "indefinitely, eliminating the 5-10 second lag on first query."
echo ""

# Function to update a service file
update_service() {
    local service_name=$1
    local service_file="/etc/systemd/system/${service_name}.service"
    
    echo "Updating $service_name..."
    
    # Check if service exists
    if ! sudo test -f "$service_file"; then
        echo "⚠️  $service_file not found, skipping..."
        return
    fi
    
    # Check if OLLAMA_KEEP_ALIVE is already set
    if sudo grep -q "OLLAMA_KEEP_ALIVE" "$service_file"; then
        echo "✅ $service_name already has OLLAMA_KEEP_ALIVE configured"
        return
    fi
    
    # Add OLLAMA_KEEP_ALIVE after OLLAMA_HOST line
    sudo sed -i '/Environment="OLLAMA_HOST/a Environment="OLLAMA_KEEP_ALIVE=-1"' "$service_file"
    echo "✅ Added OLLAMA_KEEP_ALIVE=-1 to $service_name"
}

# Determine if local or remote
if [ "$FRANKEN_IS_LOCAL" = "true" ]; then
    # Local installation
    echo "Mode: LOCAL"
    echo ""
    
    update_service "ollama-gpu0"
    
    if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
        update_service "ollama-gpu1"
    fi
    
    # Reload systemd and restart services
    echo ""
    echo "Reloading systemd daemon..."
    sudo systemctl daemon-reload
    
    echo "Restarting services..."
    sudo systemctl restart ollama-gpu0
    if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
        sudo systemctl restart ollama-gpu1
    fi
    
    echo ""
    echo "✅ Keep-alive enabled! Services restarted."
    echo ""
    echo "Next steps:"
    echo "  1. Run warmup: ./bin/warmup-models.sh"
    echo "  2. Models will now stay loaded indefinitely"
    echo "  3. Test: ./bin/test-llm.sh 'Hello'"
    
else
    # Remote installation - use franken_exec
    echo "Mode: REMOTE (${FRANKEN_SERVER_IP})"
    echo ""
    
    echo "Updating ollama-gpu0..."
    franken_exec "if sudo grep -q 'OLLAMA_KEEP_ALIVE' /etc/systemd/system/ollama-gpu0.service 2>/dev/null; then
        echo '✅ ollama-gpu0 already has OLLAMA_KEEP_ALIVE configured'
    else
        sudo sed -i '/Environment=\"OLLAMA_HOST/a Environment=\"OLLAMA_KEEP_ALIVE=-1\"' /etc/systemd/system/ollama-gpu0.service && echo '✅ Added OLLAMA_KEEP_ALIVE=-1 to ollama-gpu0'
    fi"
    
    if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
        echo ""
        echo "Updating ollama-gpu1..."
        franken_exec "if sudo grep -q 'OLLAMA_KEEP_ALIVE' /etc/systemd/system/ollama-gpu1.service 2>/dev/null; then
            echo '✅ ollama-gpu1 already has OLLAMA_KEEP_ALIVE configured'
        else
            sudo sed -i '/Environment=\"OLLAMA_HOST/a Environment=\"OLLAMA_KEEP_ALIVE=-1\"' /etc/systemd/system/ollama-gpu1.service && echo '✅ Added OLLAMA_KEEP_ALIVE=-1 to ollama-gpu1'
        fi"
    fi
    
    echo ""
    echo "Reloading systemd daemon..."
    franken_exec "sudo systemctl daemon-reload"
    
    echo "Restarting services..."
    franken_exec "sudo systemctl restart ollama-gpu0"
    if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
        franken_exec "sudo systemctl restart ollama-gpu1"
    fi
    
    echo ""
    echo "✅ Keep-alive enabled! Services restarted."
    echo ""
    echo "Next steps:"
    echo "  1. Run warmup: ./bin/warmup-models.sh"
    echo "  2. Models will now stay loaded indefinitely"
    echo "  3. Test: ./bin/test-llm.sh 'Hello'"
fi

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║              Keep-Alive Configuration Complete             ║"
echo "╚════════════════════════════════════════════════════════════╝"
