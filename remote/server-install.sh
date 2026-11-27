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

# curl is the readiness probe for the new services (and the Ollama download): a
# missing probe tool must stop the install BEFORE anything is changed.
if ! command -v curl &> /dev/null; then
    echo "❌ curl is required (health check of the new services, release download) but was not found."
    echo "   Install it first (Debian/Ubuntu: sudo apt-get install curl); nothing was changed."
    exit 1
fi

# ---------------------------------------------------------------------------
# Failure handling, armed before the first change. On any non-zero exit:
#   - the previous Ollama files are put back if a replacement was swapped in
#   - the earlier unit files and enabled/active/masked states are restored once
#     the service swap has started (ROLLBACK_ARMED)
# Every restoration step is checked and recorded, and the result is read back.
# Success is only reported when everything was restored; otherwise the script
# says "ROLLBACK INCOMPLETE", lists the steps that failed and exits 70.
# ---------------------------------------------------------------------------
UNIT_DIR=/etc/systemd/system
UNITS=()
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/backup"
ROLLBACK_ARMED=0
OLLAMA_SWAPPED=0
RB_FAILS=()
declare -A WAS_ACTIVE=() WAS_ENABLED=() WAS_FILE=()
DEFAULT_WAS_ACTIVE=0
DEFAULT_WAS_ENABLED=0
DEFAULT_WAS_MASKED=0
DEFAULT_WAS_FILE=0

# rb DESCRIPTION CMD... - run one rollback step; remember it if it fails
rb() {
    local d="$1"
    shift
    "$@" || RB_FAILS+=("$d")
}

# restore_unit_file NAME - put the backed-up unit file back, atomically
restore_unit_file() {
    sudo install -m 0644 -o root -g root "$STAGE/backup/$1.service" "$UNIT_DIR/.$1.service.new" \
        && sudo mv -f "$UNIT_DIR/.$1.service.new" "$UNIT_DIR/$1.service"
}

# unit_state_is NAME active|enabled|masked yes|no - compare the live state
unit_state_is() {
    local got=no
    case "$2" in
        active) systemctl is-active --quiet "$1.service" 2> /dev/null && got=yes ;;
        enabled) [ "$(systemctl is-enabled "$1.service" 2> /dev/null || true)" = "enabled" ] && got=yes ;;
        masked) [ "$(systemctl is-enabled "$1.service" 2> /dev/null || true)" = "masked" ] && got=yes ;;
    esac
    [ "$got" = "$3" ]
}

# unit_file_is_original NAME HAD_FILE - the unit file equals the backup, or is absent if there was none
unit_file_is_original() {
    if [ "$2" = "1" ]; then
        sudo cmp -s "$STAGE/backup/$1.service" "$UNIT_DIR/$1.service"
    else
        ! sudo test -e "$UNIT_DIR/$1.service"
    fi
}

yn() { if [ "$1" = "1" ]; then echo yes; else echo no; fi; }

rollback_units() {
    local u
    for u in "${UNITS[@]}"; do
        if sudo test -e "$UNIT_DIR/$u.service"; then
            rb "stop $u" sudo systemctl stop "$u.service"
            rb "disable $u" sudo systemctl disable "$u.service"
        fi
        if [ "${WAS_FILE[$u]}" = "1" ]; then
            rb "restore the unit file of $u" restore_unit_file "$u"
        else
            rb "remove the new unit file of $u" sudo rm -f -- "${UNIT_DIR:?}/$u.service" "${UNIT_DIR:?}/.$u.service.new"
        fi
    done
    if [ "$DEFAULT_WAS_FILE" = "1" ]; then
        rb "restore the unit file of ollama.service" restore_unit_file ollama
    fi
    if [ "$DEFAULT_WAS_MASKED" -eq 0 ]; then
        rb "unmask ollama.service" sudo systemctl unmask ollama.service
    fi
    rb "systemd daemon-reload" sudo systemctl daemon-reload
    for u in "${UNITS[@]}"; do
        if [ "${WAS_ENABLED[$u]}" = "1" ]; then rb "re-enable $u" sudo systemctl enable "$u.service"; fi
        if [ "${WAS_ACTIVE[$u]}" = "1" ]; then rb "restart $u" sudo systemctl start "$u.service"; fi
    done
    if [ "$DEFAULT_WAS_ENABLED" -eq 1 ]; then rb "re-enable ollama.service" sudo systemctl enable ollama.service; fi
    if [ "$DEFAULT_WAS_ACTIVE" -eq 1 ]; then rb "restart ollama.service" sudo systemctl start ollama.service; fi
    # read back: unit files, enabled/masked state and active state
    for u in "${UNITS[@]}"; do
        unit_file_is_original "$u" "${WAS_FILE[$u]}" || RB_FAILS+=("read-back: unit file of $u differs from before")
        unit_state_is "$u" enabled "$(yn "${WAS_ENABLED[$u]}")" || RB_FAILS+=("read-back: enabled state of $u differs from before")
        unit_state_is "$u" active "$(yn "${WAS_ACTIVE[$u]}")" || RB_FAILS+=("read-back: active state of $u differs from before")
    done
    unit_file_is_original ollama "$DEFAULT_WAS_FILE" || RB_FAILS+=("read-back: unit file of ollama.service differs from before")
    unit_state_is ollama masked "$(yn "$DEFAULT_WAS_MASKED")" || RB_FAILS+=("read-back: masked state of ollama.service differs from before")
    unit_state_is ollama enabled "$(yn "$DEFAULT_WAS_ENABLED")" || RB_FAILS+=("read-back: enabled state of ollama.service differs from before")
    unit_state_is ollama active "$(yn "$DEFAULT_WAS_ACTIVE")" || RB_FAILS+=("read-back: active state of ollama.service differs from before")
}

finish() {
    local rc=$? did=0
    trap - EXIT
    set +e
    if [ "$rc" -ne 0 ]; then
        if [ "$OLLAMA_SWAPPED" -eq 1 ]; then
            echo ""
            echo "❌ Installation failed (exit $rc); restoring the previous Ollama files..."
            did=1
            rb "restore the previous Ollama files" franken_ollama_undo_restore /usr/local sudo
        fi
        if [ "$ROLLBACK_ARMED" -eq 1 ]; then
            echo ""
            echo "❌ Installation failed (exit $rc); restoring the previous service state..."
            did=1
            rollback_units
        fi
        if [ "${#RB_FAILS[@]}" -gt 0 ]; then
            echo ""
            echo "❌ ROLLBACK INCOMPLETE: the server may be in a mixed state. These steps failed:"
            printf '   - %s\n' "${RB_FAILS[@]}"
            echo "   Inspect: systemctl status ollama ollama-gpu0 ollama-gpu1; ls $UNIT_DIR/ollama*; ls /usr/local/.franken-ollama-undo"
            rc=70
        elif [ "$did" -eq 1 ]; then
            echo "   Previous state restored and verified; see the error above."
        fi
    elif [ "$OLLAMA_SWAPPED" -eq 1 ]; then
        franken_ollama_undo_discard /usr/local sudo || echo "⚠️  Could not remove /usr/local/.franken-ollama-undo (old Ollama backup); remove it by hand"
    fi
    rm -rf -- "${STAGE:?}"
    exit "$rc"
}
trap finish EXIT

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
        OLLAMA_SWAPPED=1   # from here a failure restores the previous Ollama files
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
UNITS=(ollama-gpu0)
PORTS=("$GPU0_PORT")
if [ "$GPU_COUNT" -ge 2 ]; then
    UNITS+=(ollama-gpu1)
    PORTS+=("$GPU1_PORT")
fi

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
if [ "$DEFAULT_WAS_ACTIVE" -eq 1 ]; then
    sudo systemctl stop ollama.service
fi
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
if [ "$DEFAULT_WAS_ENABLED" -eq 1 ]; then
    sudo systemctl disable ollama.service
fi
sudo rm -f /etc/systemd/system/ollama.service
sudo systemctl daemon-reload
sudo systemctl mask ollama.service
if [ "$(systemctl is-enabled ollama.service 2> /dev/null || true)" != "masked" ]; then
    echo "❌ ollama.service is not masked after masking it; restoring the previous state"
    exit 1
fi
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
