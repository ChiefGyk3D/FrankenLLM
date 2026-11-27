#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - server-side installer. NOT run directly: remote/install.sh joins
# remote/unit-lib.sh (the helper functions used below) and this file into one
# script, copies it into a private directory on the target and runs it there.
# Arguments: GPU0_PORT GPU1_PORT BIND_ADDR SERVICE_USER MEMORY_MAX TASKS_MAX
#            OLLAMA_PIN REQUIRE_GPU OLLAMA_SHA256 OLLAMA_SHA256_ASSET
#            ALLOW_UNVERIFIED_OLLAMA
set -euo pipefail

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

# Service account: default is the invoking user. FRANKEN_SERVICE_USER names a
# dedicated system account (nologin shell, home under /var/lib) that is created
# when missing. An EXISTING account is adopted only when it already matches that
# policy, so a login or CI account can never become the service account. This
# check is read-only and runs before anything is installed or changed.
if [ -n "$SERVICE_USER" ] && id "$SERVICE_USER" &> /dev/null; then
    PW_LINE="$(getent passwd "$SERVICE_USER")"
    IFS=: read -r _ _ ACCT_UID _ _ ACCT_HOME ACCT_SHELL <<< "$PW_LINE"
    ACCT_GROUPS="$(id -Gn "$SERVICE_USER")"
    if ! ACCT_WHY="$(franken_check_service_account "$SERVICE_USER" "$ACCT_UID" "$ACCT_SHELL" "$ACCT_HOME" "$ACCT_GROUPS")"; then
        echo "❌ $ACCT_WHY"
        echo "   Refusing to run the services as an existing account that is not a dedicated"
        echo "   system account. Pick another FRANKEN_SERVICE_USER (it is created for you)."
        exit 1
    fi
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

# Service account: create it when it is missing (the policy check above covered
# an existing one).
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

# ---------------------------------------------------------------------------
# Replace the default ollama.service with one service per GPU, safely.
#   1. render the units into a private staging directory and verify them
#   2. remember the prior state (unit files, active, enabled, masked)
#   3. stop the default service (it holds port 11434), install the new units
#      atomically, start them and health-check them
#   4. only then retire the default service for good (disable, remove, mask)
# Any failure after step 2 restores the prior state (trap on EXIT).
# ---------------------------------------------------------------------------
UNIT_DIR=/etc/systemd/system
UNITS=(ollama-gpu0)
PORTS=("$GPU0_PORT")
if [ "$GPU_COUNT" -ge 2 ]; then
    UNITS+=(ollama-gpu1)
    PORTS+=("$GPU1_PORT")
fi

STAGE="$(mktemp -d)"
mkdir -p "$STAGE/backup"
ROLLBACK_ARMED=0

declare -A WAS_ACTIVE=() WAS_ENABLED=() WAS_FILE=()
DEFAULT_WAS_ACTIVE=0
DEFAULT_WAS_ENABLED=0
DEFAULT_WAS_MASKED=0
DEFAULT_WAS_FILE=0

# restore_unit_file NAME - put the backed-up unit file back, atomically
restore_unit_file() {
    sudo install -m 0644 -o root -g root "$STAGE/backup/$1.service" "$UNIT_DIR/.$1.service.new" \
        && sudo mv -f "$UNIT_DIR/.$1.service.new" "$UNIT_DIR/$1.service"
}

finish() {
    local rc=$? u
    trap - EXIT
    set +e
    if [ "$ROLLBACK_ARMED" -eq 1 ] && [ "$rc" -ne 0 ]; then
        echo ""
        echo "❌ Installation failed (exit $rc); restoring the previous service state..."
        for u in "${UNITS[@]}"; do
            sudo systemctl stop "$u.service" 2> /dev/null
            sudo systemctl disable "$u.service" 2> /dev/null
            if [ "${WAS_FILE[$u]}" = "1" ]; then
                restore_unit_file "$u"
            else
                sudo rm -f -- "${UNIT_DIR:?}/$u.service" "${UNIT_DIR:?}/.$u.service.new"
            fi
        done
        if [ "$DEFAULT_WAS_FILE" = "1" ]; then
            restore_unit_file ollama
        fi
        if [ "$DEFAULT_WAS_MASKED" -eq 0 ]; then
            sudo systemctl unmask ollama.service 2> /dev/null
        fi
        sudo systemctl daemon-reload
        for u in "${UNITS[@]}"; do
            [ "${WAS_ENABLED[$u]}" = "1" ] && sudo systemctl enable "$u.service" 2> /dev/null
            [ "${WAS_ACTIVE[$u]}" = "1" ] && sudo systemctl start "$u.service" 2> /dev/null
        done
        [ "$DEFAULT_WAS_ENABLED" -eq 1 ] && sudo systemctl enable ollama.service 2> /dev/null
        [ "$DEFAULT_WAS_ACTIVE" -eq 1 ] && sudo systemctl start ollama.service 2> /dev/null
        echo "   Previous state restored; see the error above."
    fi
    rm -rf -- "${STAGE:?}"
    exit "$rc"
}
trap finish EXIT

# 1. stage and verify
echo "Staging systemd units..."
for i in "${!UNITS[@]}"; do
    gpu="${UNITS[$i]#ollama-gpu}"
    franken_render_unit "$gpu" "${PORTS[$i]}" "$MODELS_BASE/models-gpu$gpu" "$UNIT_USER" "$BIND_ADDR" "$MEMORY_MAX" "$TASKS_MAX" "$REQUIRE_GPU" "$NVIDIA_SMI_PATH" \
        > "$STAGE/${UNITS[$i]}.service"
    if command -v systemd-analyze &> /dev/null; then
        if ! systemd-analyze verify "$STAGE/${UNITS[$i]}.service"; then
            echo "❌ systemd-analyze rejected the generated ${UNITS[$i]}.service; nothing was changed"
            exit 1
        fi
    else
        echo "⚠️  systemd-analyze not found; the generated units were not verified"
    fi
done

# 2. remember the prior state
if systemctl is-active --quiet ollama.service 2> /dev/null; then DEFAULT_WAS_ACTIVE=1; fi
DEFAULT_STATE="$(systemctl is-enabled ollama.service 2> /dev/null || true)"
if [ "$DEFAULT_STATE" = "enabled" ]; then DEFAULT_WAS_ENABLED=1; fi
if [ "$DEFAULT_STATE" = "masked" ]; then DEFAULT_WAS_MASKED=1; fi
if sudo test -f "$UNIT_DIR/ollama.service"; then
    DEFAULT_WAS_FILE=1
    sudo cp -p "$UNIT_DIR/ollama.service" "$STAGE/backup/ollama.service"
fi
for u in "${UNITS[@]}"; do
    WAS_ACTIVE[$u]=0
    WAS_ENABLED[$u]=0
    WAS_FILE[$u]=0
    if systemctl is-active --quiet "$u.service" 2> /dev/null; then WAS_ACTIVE[$u]=1; fi
    if [ "$(systemctl is-enabled "$u.service" 2> /dev/null || true)" = "enabled" ]; then WAS_ENABLED[$u]=1; fi
    if sudo test -f "$UNIT_DIR/$u.service"; then
        WAS_FILE[$u]=1
        sudo cp -p "$UNIT_DIR/$u.service" "$STAGE/backup/$u.service"
    fi
done
ROLLBACK_ARMED=1

# 3. swap in the replacements and prove they work
echo "Stopping the default ollama service (it uses port 11434)..."
sudo systemctl stop ollama.service 2> /dev/null || true
for u in "${UNITS[@]}"; do
    echo "Installing $u.service..."
    sudo install -m 0644 -o root -g root "$STAGE/$u.service" "$UNIT_DIR/.$u.service.new"
    sudo mv -f "$UNIT_DIR/.$u.service.new" "$UNIT_DIR/$u.service"
done
echo "Reloading systemd..."
sudo systemctl daemon-reload
echo "Starting services..."
for u in "${UNITS[@]}"; do
    sudo systemctl start "$u.service"
done
for i in "${!UNITS[@]}"; do
    echo "Waiting for ${UNITS[$i]} to answer..."
    if ! franken_wait_unit_ready "${UNITS[$i]}.service" "$(franken_ready_url "$BIND_ADDR" "${PORTS[$i]}")" 40; then
        echo "❌ ${UNITS[$i]} did not become ready"
        exit 1
    fi
done
echo "Enabling services on boot..."
for u in "${UNITS[@]}"; do
    sudo systemctl enable "$u.service"
done

# 4. the replacements work: retire the default service for good. Disable and MASK
# it so Ollama updates can never start it again.
echo "Disabling and masking default ollama service..."
sudo systemctl disable ollama.service 2> /dev/null || true
sudo rm -f /etc/systemd/system/ollama.service
sudo systemctl daemon-reload
sudo systemctl mask ollama.service 2> /dev/null || true
ROLLBACK_ARMED=0
echo "✅ Default ollama.service masked (permanently prevented from starting)"

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
