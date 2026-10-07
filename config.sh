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
export FRANKEN_GPU1_MODEL="${FRANKEN_GPU1_MODEL:-qwen3.5:4b}"

# Guard/moderation model kept resident on GPU 0 alongside the main model
# (e.g. llama-guard3:8b for AI moderation). Set empty to disable warmup for it.
# Note "-" not ":-": an explicit empty value in .env must stay empty (with ":-"
# it silently fell back to llama-guard3:8b, so "set empty to disable" never worked).
export FRANKEN_GPU0_GUARD_MODEL="${FRANKEN_GPU0_GUARD_MODEL-llama-guard3:8b}"

# Context length per Ollama instance (OLLAMA_CONTEXT_LENGTH in the systemd units).
# Ollama >= 0.33 defaults to 32768, which blows the KV-cache budget when two
# models share a GPU: on a 16GB card, gemma4:12b + llama-guard3:8b both stay
# resident at 8192 but the guard evicts the main model at 16384+.
export FRANKEN_GPU0_CONTEXT="${FRANKEN_GPU0_CONTEXT:-8192}"
export FRANKEN_GPU1_CONTEXT="${FRANKEN_GPU1_CONTEXT:-32768}"

# Ollama's Vulkan backend (OLLAMA_VULKAN in the systemd units). Recent Ollama
# discovers every GPU through Vulkan as well as CUDA, and Vulkan ignores the
# CUDA_VISIBLE_DEVICES pin on each unit, so on an NVIDIA box an instance can load
# a model onto the OTHER card. Values:
#   auto   (default) writes OLLAMA_VULKAN=0 when nvidia-smi sees a GPU on the
#          install target, otherwise writes nothing (AMD/Intel keep Vulkan)
#   0 / 1  always write that value (use 1, or leave at the default (auto), for AMD/Intel cards)
#   empty  never write the line; Ollama's own default applies
# Note "-" not ":-": an explicit empty value in .env must stay empty.
# Re-run scripts/install-ollama-native.sh to apply. See docs/CONFIGURATION.md.
export FRANKEN_OLLAMA_VULKAN="${FRANKEN_OLLAMA_VULKAN-auto}"

# --- Optional per-model layout (all empty/unset by default = no change) -----
# Main models (FRANKEN_GPU0_MODEL / FRANKEN_GPU1_MODEL) are warmed with no num_ctx,
# so they run at the instance context above. A guard/extra model sends num_ctx
# at warm-up ONLY when its own *_CONTEXT below is set (empty = none sent, it uses
# the instance context too). Clients must send the SAME num_ctx or Ollama reloads
# the model (see docs/CONFIGURATION.md).

# Guard/moderation model on GPU 1 (e.g. llama-guard3:8b on the small card).
# Empty = not warmed. Ignored (with a warning) when FRANKEN_GPU_COUNT=1.
export FRANKEN_GPU1_GUARD_MODEL="${FRANKEN_GPU1_GUARD_MODEL:-}"

# num_ctx sent when warming the guard models (empty = send none).
export FRANKEN_GPU0_GUARD_CONTEXT="${FRANKEN_GPU0_GUARD_CONTEXT:-}"
export FRANKEN_GPU1_GUARD_CONTEXT="${FRANKEN_GPU1_GUARD_CONTEXT:-}"

# Optional second resident model on GPU 0 (e.g. a small cheap-task model next
# to the backbone). Empty = not warmed. EXTRA_CONTEXT empty = send no num_ctx.
export FRANKEN_GPU0_EXTRA_MODEL="${FRANKEN_GPU0_EXTRA_MODEL:-}"
export FRANKEN_GPU0_EXTRA_CONTEXT="${FRANKEN_GPU0_EXTRA_CONTEXT:-}"

# Warm-up request timeouts in seconds. A first load after an Ollama upgrade, or
# at a large context, can take over a minute.
export FRANKEN_GPU0_WARMUP_TIMEOUT="${FRANKEN_GPU0_WARMUP_TIMEOUT:-180}"
export FRANKEN_GPU1_WARMUP_TIMEOUT="${FRANKEN_GPU1_WARMUP_TIMEOUT:-120}"

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
