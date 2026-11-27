#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - systemd unit rendering and validation for remote/install.sh.
# Pure functions: nothing here touches systemd, the filesystem or the network,
# so tests/test-unit-render.sh can source this file and check the unit text.
# install.sh appends this file to the script it copies to the target server.

# franken_valid_bind_addr ADDR - IPv4 dotted quad, each octet 0-255.
franken_valid_bind_addr() {
    local addr="$1" octet
    local -a octets
    [[ "$addr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$addr"
    for octet in "${octets[@]}"; do
        [ "$((10#$octet))" -le 255 ] || return 1
    done
}

# franken_valid_service_user NAME - lowercase account name, max 32 characters.
# "root" is refused: it would bypass the installer's non-root guard.
franken_valid_service_user() {
    [ "$1" = "root" ] && return 1
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

# franken_gpu_groups [GETENT_CMD] - comma list of the video and render groups
# that exist on this server (confirmed with getent), empty when neither does.
franken_gpu_groups() {
    local getent_cmd="${1:-getent}" g list=""
    for g in video render; do
        if "$getent_cmd" group "$g" > /dev/null 2>&1; then
            list="${list:+$list,}$g"
        fi
    done
    printf '%s' "$list"
}

# franken_ready_url BIND PORT - Ollama readiness URL for the warmup service.
# A valid specific BIND address is used; empty, 0.0.0.0 or invalid -> localhost.
franken_ready_url() {
    local host="localhost"
    if [ -n "$1" ] && [ "$1" != "0.0.0.0" ] && franken_valid_bind_addr "$1"; then
        host="$1"
    fi
    printf 'http://%s:%s/api/tags' "$host" "$2"
}

# franken_model_host DEFAULT_HOST BIND - host the model scripts (bin/pull-model.sh
# and friends) use to reach Ollama. A valid specific BIND address is used; empty
# or 0.0.0.0 -> DEFAULT_HOST; invalid -> DEFAULT_HOST plus a one-line warning on
# stderr (the invalid value is never returned or echoed to a command).
franken_model_host() {
    local default_host="$1" bind="${2:-}"
    if [ -z "$bind" ] || [ "$bind" = "0.0.0.0" ]; then
        printf '%s' "$default_host"
    elif franken_valid_bind_addr "$bind"; then
        printf '%s' "$bind"
    else
        echo "WARNING: FRANKEN_BIND_ADDR is not a valid IPv4 address; using $default_host" >&2
        printf '%s' "$default_host"
    fi
}

# franken_valid_memory_max VALUE - positive integer with optional K/M/G/T, or infinity.
franken_valid_memory_max() {
    [[ "$1" =~ ^[1-9][0-9]*[KMGT]?$ || "$1" == "infinity" ]]
}

# franken_valid_tasks_max VALUE - positive integer, or infinity.
franken_valid_tasks_max() {
    [[ "$1" =~ ^[1-9][0-9]*$ || "$1" == "infinity" ]]
}

# franken_valid_ollama_version VALUE - X.Y.Z with optional -rcN (e.g. 0.33.2, 0.34.0-rc1).
franken_valid_ollama_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]]
}

# franken_ollama_fetch_cmd [VERSION] - prints the command line that fetches and
# runs the upstream installer; nothing is executed here. A non-empty VERSION
# (validated, else return 1) is set as OLLAMA_VERSION for the piped shell.
# The upstream script has no checksum step: a pin gives a reproducible version,
# not integrity.
franken_ollama_fetch_cmd() {
    local url="https://ollama.com/install.sh"
    if [ -z "${1:-}" ]; then
        printf 'curl -fsSL %s | sh\n' "$url"
        return 0
    fi
    franken_valid_ollama_version "$1" || return 1
    printf 'curl -fsSL %s | OLLAMA_VERSION=%s sh\n' "$url" "$1"
}

# franken_ollama_parse_version TEXT - first X.Y.Z[-rcN] in `ollama --version`
# output (which may carry warning lines); empty when none.
franken_ollama_parse_version() {
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?' <<< "$1" | head -n 1
}

# franken_render_unit GPU PORT MODELS_DIR USER BIND MEMORY_MAX TASKS_MAX
# Prints the unit text. Empty BIND means all interfaces (0.0.0.0); empty
# MEMORY_MAX / TASKS_MAX write no limit line. Callers validate first.
franken_render_unit() {
    local gpu="$1" port="$2" models="$3" user="$4" bind="${5:-0.0.0.0}" mem="$6" tasks="$7"
    cat << UNIT
[Unit]
Description=Ollama Service for GPU $gpu
After=network-online.target

[Service]
Type=simple
User=$user
Environment="CUDA_VISIBLE_DEVICES=$gpu"
Environment="OLLAMA_HOST=$bind:$port"
Environment="OLLAMA_MODELS=$models"
Environment="OLLAMA_KEEP_ALIVE=-1"
ExecStart=/usr/local/bin/ollama serve
Restart=always
RestartSec=3
UNIT
    [ -n "$mem" ] && printf 'MemoryMax=%s\n' "$mem"
    [ -n "$tasks" ] && printf 'TasksMax=%s\n' "$tasks"
    cat << UNIT

[Install]
WantedBy=default.target
UNIT
    return 0
}
