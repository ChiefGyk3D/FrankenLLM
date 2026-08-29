#!/bin/bash
# FrankenLLM Configuration
# Stitched-together GPUs, but it lives!

# Get the script directory
CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env file if it exists
if [ -f "$CONFIG_DIR/.env" ]; then
    set -a
    source "$CONFIG_DIR/.env"
    set +a
fi

# Server IP address - set to "localhost" or "127.0.0.1" for local installation
# Set to remote IP (e.g., "192.168.201.145") for remote installation
export FRANKEN_SERVER_IP="${FRANKEN_SERVER_IP:-192.168.201.145}"

# Installation directory on the target server
export FRANKEN_INSTALL_DIR="${FRANKEN_INSTALL_DIR:-/opt/frankenllm}"

# GPU Count
export FRANKEN_GPU_COUNT="${FRANKEN_GPU_COUNT:-2}"

# Port configuration
export FRANKEN_GPU0_PORT="${FRANKEN_GPU0_PORT:-11434}"
export FRANKEN_GPU1_PORT="${FRANKEN_GPU1_PORT:-11435}"

# GPU configuration
export FRANKEN_GPU0_NAME="${FRANKEN_GPU0_NAME:-"RTX 5060 Ti"}"
export FRANKEN_GPU1_NAME="${FRANKEN_GPU1_NAME:-"RTX 3050"}"

# Model configuration
# gemma4:12b requires Ollama >= 0.33
export FRANKEN_GPU0_MODEL="${FRANKEN_GPU0_MODEL:-gemma4:12b}"
export FRANKEN_GPU1_MODEL="${FRANKEN_GPU1_MODEL:-gemma3:4b}"

# Guard/moderation model kept resident on GPU 0 alongside the main model
# (e.g. llama-guard3:8b for AI moderation). Set empty to disable warmup for it.
export FRANKEN_GPU0_GUARD_MODEL="${FRANKEN_GPU0_GUARD_MODEL:-llama-guard3:8b}"

# Context length per Ollama instance (OLLAMA_CONTEXT_LENGTH in the systemd units).
# Ollama >= 0.33 defaults to 32768, which blows the KV-cache budget when two
# models share a GPU: on a 16GB card, gemma4:12b + llama-guard3:8b both stay
# resident at 8192 but the guard evicts the main model at 16384+.
export FRANKEN_GPU0_CONTEXT="${FRANKEN_GPU0_CONTEXT:-8192}"
export FRANKEN_GPU1_CONTEXT="${FRANKEN_GPU1_CONTEXT:-32768}"

# Detect if we're installing locally or remotely
if [[ "$FRANKEN_SERVER_IP" == "localhost" || "$FRANKEN_SERVER_IP" == "127.0.0.1" ]]; then
    export FRANKEN_IS_LOCAL=true
    export FRANKEN_SSH_PREFIX=""
else
    export FRANKEN_IS_LOCAL=false
    export FRANKEN_SSH_PREFIX="ssh $FRANKEN_SERVER_IP"
fi

# Helper function to run commands locally or remotely
franken_exec() {
    if [ "$FRANKEN_IS_LOCAL" = true ]; then
        bash -c "$1"
    else
        ssh "$FRANKEN_SERVER_IP" "$1"
    fi
}

# Helper function to copy files locally or remotely
franken_copy() {
    local source="$1"
    local dest="$2"
    
    if [ "$FRANKEN_IS_LOCAL" = true ]; then
        cp -r "$source" "$dest"
    else
        scp -r "$source" "$FRANKEN_SERVER_IP:$dest"
    fi
}

# Export the helper functions
export -f franken_exec
export -f franken_copy

echo "FrankenLLM Configuration Loaded"
echo "================================"
echo "Server IP:        $FRANKEN_SERVER_IP"
echo "Installation Dir: $FRANKEN_INSTALL_DIR"
echo "GPU 0 Port:       $FRANKEN_GPU0_PORT"
echo "GPU 1 Port:       $FRANKEN_GPU1_PORT"
echo "Install Mode:     $([ "$FRANKEN_IS_LOCAL" = true ] && echo "LOCAL" || echo "REMOTE")"
echo "================================"
