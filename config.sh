#!/bin/bash
# FrankenLLM Configuration
# Stitched-together GPUs, but it lives!

# Get the script directory
CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# franken_load_env FILE - read FILE as DATA (never sourced, never eval'd).
# Accepted lines: blank, "# comment", and [export ]FRANKEN_NAME=VALUE where VALUE
# is unquoted (letters, digits and _ @ % + = : , . / -), "double quoted" or
# 'single quoted'. Quoted values are literal: no backslash, $, backtick or
# nested quote of the same kind. Duplicate keys, control characters (tab and CR
# included) and any other syntax are errors and nothing is loaded (fail closed).
# Keys that are not FRANKEN_* are ignored with a warning. A variable already set
# in the environment (even empty) wins over the file.
franken_load_env() {
    local file="$1" line key val lineno=0 seen=" " n i
    local -a keys=() vals=()
    local re_key='^(export[[:space:]]+)?(FRANKEN_[A-Z0-9_]+)=(.*)$'
    local re_other='^(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*='
    local re_dq='^"([^"\\$`]*)"[[:space:]]*$'
    local re_sq="^'([^']*)'[[:space:]]*\$"
    local re_bare='^[A-Za-z0-9_@%+=:,./-]*$'
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        if [[ "$line" =~ [[:cntrl:]] ]]; then
            echo "ERROR: $file line $lineno: control characters are not allowed" >&2
            return 1
        fi
        [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
        if [[ "$line" =~ $re_key ]]; then
            key="${BASH_REMATCH[2]}"
            val="${BASH_REMATCH[3]}"
        elif [[ "$line" =~ $re_other ]]; then
            echo "WARNING: $file line $lineno: ignoring a setting that is not FRANKEN_*" >&2
            continue
        else
            echo "ERROR: $file line $lineno: not a KEY=VALUE line" >&2
            return 1
        fi
        if [[ "$seen" == *" $key "* ]]; then
            echo "ERROR: $file line $lineno: duplicate key $key" >&2
            return 1
        fi
        seen="$seen$key "
        if [[ "$val" =~ $re_dq ]]; then
            val="${BASH_REMATCH[1]}"
        elif [[ "$val" =~ $re_sq ]]; then
            val="${BASH_REMATCH[1]}"
        elif [[ ! "$val" =~ $re_bare ]]; then
            echo "ERROR: $file line $lineno: unsupported value syntax for $key (use plain quotes; no backslash, dollar or backtick)" >&2
            return 1
        fi
        keys+=("$key")
        vals+=("$val")
    done < "$file"
    n=${#keys[@]}
    for ((i = 0; i < n; i++)); do
        key="${keys[$i]}"
        if [ -z "${!key+x}" ]; then
            printf -v "$key" '%s' "${vals[$i]}"
            export "${key?}"
        fi
    done
    return 0
}

# Load .env if it exists (as data, see franken_load_env). A bad file stops the
# calling script: running with a half-read configuration is worse than failing.
franken_load_env "$CONFIG_DIR/.env" || exit 1

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

# --- Optional remote-install hardening (all unset by default = no change) ---
# Read by remote/install.sh and validated there before anything is written.
# FRANKEN_BIND_ADDR   IPv4 address Ollama binds to (e.g. 192.0.2.10), written with
#                     the port into OLLAMA_HOST. Unset = all interfaces (0.0.0.0).
# FRANKEN_SERVICE_USER  Account the units run as. Unset = the invoking user. When
#                     set, install.sh creates it as a system account (nologin
#                     shell, home /var/lib/<name> holds the models) if missing.
#                     Must match ^[a-z_][a-z0-9_-]{0,31}$ .
# FRANKEN_MEMORY_MAX  systemd MemoryMax for each unit (e.g. 24G, 512M, infinity).
# FRANKEN_TASKS_MAX   systemd TasksMax for each unit (e.g. 512, infinity).
# Unset or empty MemoryMax/TasksMax writes no line. See docs/CONFIGURATION.md.
# FRANKEN_OLLAMA_VERSION  Pin the Ollama version the remote install fetches, as
#                     X.Y.Z or X.Y.Z-rcN (e.g. 0.33.2); passed to the upstream
#                     installer as OLLAMA_VERSION and checked after install.
#                     Unset = latest, with a warning. The upstream script has no
#                     checksum step: a pin is reproducible, not integrity-checked.
# FRANKEN_REQUIRE_GPU  true or false (unset/empty = false). When true, each unit
#                     gets ExecStartPre=<nvidia-smi> -L, so a missing driver
#                     (e.g. after a kernel update) makes the unit FAIL instead of
#                     Ollama quietly running on the CPU. With Restart=always the
#                     unit then fails and restarts in a loop: the failing unit is
#                     the signal, there is no CPU fallback. Anything else is rejected.
export FRANKEN_BIND_ADDR="${FRANKEN_BIND_ADDR:-}"
export FRANKEN_SERVICE_USER="${FRANKEN_SERVICE_USER:-}"
export FRANKEN_MEMORY_MAX="${FRANKEN_MEMORY_MAX:-}"
export FRANKEN_TASKS_MAX="${FRANKEN_TASKS_MAX:-}"
export FRANKEN_OLLAMA_VERSION="${FRANKEN_OLLAMA_VERSION:-}"
export FRANKEN_REQUIRE_GPU="${FRANKEN_REQUIRE_GPU:-}"

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
