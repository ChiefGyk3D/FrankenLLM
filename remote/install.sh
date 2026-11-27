#!/bin/bash
# FrankenLLM - Remote Installation
# Stitched-together GPUs, but it lives!
#
# This script copies the server-side installer (remote/server-install.sh, joined
# with remote/unit-lib.sh) to a private directory on the target server, checks
# the copy, and runs it there.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

if [ "$FRANKEN_IS_LOCAL" = true ]; then
    echo "❌ Configuration is set for LOCAL installation."
    echo "   Change FRANKEN_SERVER_IP in .env to your remote server's IP address."
    echo "   Or run: ./configure.sh"
    exit 1
fi

# Optional hardening settings (all unset by default = unchanged behavior).
# Validate here, before anything is copied to the server.
source "$SCRIPT_DIR/unit-lib.sh"
FRANKEN_BIND_ADDR="${FRANKEN_BIND_ADDR:-}"
FRANKEN_SERVICE_USER="${FRANKEN_SERVICE_USER:-}"
FRANKEN_MEMORY_MAX="${FRANKEN_MEMORY_MAX:-}"
FRANKEN_TASKS_MAX="${FRANKEN_TASKS_MAX:-}"
FRANKEN_OLLAMA_VERSION="${FRANKEN_OLLAMA_VERSION:-}"
FRANKEN_REQUIRE_GPU="${FRANKEN_REQUIRE_GPU:-}"
if ! franken_valid_ssh_host "$FRANKEN_SERVER_IP"; then
    echo "❌ FRANKEN_SERVER_IP must be a host name or address (optionally user@host)"
    exit 1
fi
if ! franken_valid_port "$FRANKEN_GPU0_PORT" || ! franken_valid_port "$FRANKEN_GPU1_PORT"; then
    echo "❌ FRANKEN_GPU0_PORT and FRANKEN_GPU1_PORT must be decimal numbers from 1 to 65535"
    exit 1
fi
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
if [ -n "$FRANKEN_OLLAMA_VERSION" ] && ! franken_valid_ollama_version "$FRANKEN_OLLAMA_VERSION"; then
    echo "❌ FRANKEN_OLLAMA_VERSION must look like 0.33.2 or 0.34.0-rc1"
    exit 1
fi
if [ -n "$FRANKEN_REQUIRE_GPU" ] && ! franken_valid_require_gpu "$FRANKEN_REQUIRE_GPU"; then
    echo "❌ FRANKEN_REQUIRE_GPU must be true or false"
    exit 1
fi

# Ollama download verification. A pinned version is downloaded from its GitHub
# release and checked against a sha256: FRANKEN_OLLAMA_SHA256 when set, else the
# entry in remote/ollama-checksums.txt. Without both, the server refuses to
# install Ollama (an existing matching install is kept) unless
# FRANKEN_ALLOW_UNVERIFIED_OLLAMA=true.
FRANKEN_OLLAMA_SHA256="${FRANKEN_OLLAMA_SHA256:-}"
FRANKEN_ALLOW_UNVERIFIED_OLLAMA="${FRANKEN_ALLOW_UNVERIFIED_OLLAMA:-}"
OLLAMA_SHA256=""
OLLAMA_SHA256_ASSET=""
if [ -n "$FRANKEN_OLLAMA_SHA256" ] && ! franken_valid_sha256 "$FRANKEN_OLLAMA_SHA256"; then
    echo "❌ FRANKEN_OLLAMA_SHA256 must be 64 lowercase hex characters"
    exit 1
fi
if [ -n "$FRANKEN_OLLAMA_SHA256" ] && [ -z "$FRANKEN_OLLAMA_VERSION" ]; then
    echo "❌ FRANKEN_OLLAMA_SHA256 needs FRANKEN_OLLAMA_VERSION (the checksum is for that version)"
    exit 1
fi
if [ -n "$FRANKEN_ALLOW_UNVERIFIED_OLLAMA" ] && ! franken_valid_require_gpu "$FRANKEN_ALLOW_UNVERIFIED_OLLAMA"; then
    echo "❌ FRANKEN_ALLOW_UNVERIFIED_OLLAMA must be true or false"
    exit 1
fi
if [ -n "$FRANKEN_OLLAMA_VERSION" ]; then
    if [ -n "$FRANKEN_OLLAMA_SHA256" ]; then
        OLLAMA_SHA256="$FRANKEN_OLLAMA_SHA256"
    elif OLLAMA_SHA256="$(franken_ollama_checksum_lookup "$FRANKEN_OLLAMA_VERSION" ollama-linux-amd64.tar.zst "$SCRIPT_DIR/ollama-checksums.txt")"; then
        OLLAMA_SHA256_ASSET="ollama-linux-amd64.tar.zst"
    else
        OLLAMA_SHA256=""
    fi
fi
if [ -n "$OLLAMA_SHA256" ]; then
    echo "✅ Ollama $FRANKEN_OLLAMA_VERSION will be downloaded from its GitHub release and verified (sha256 $OLLAMA_SHA256)"
elif [ "$FRANKEN_ALLOW_UNVERIFIED_OLLAMA" = "true" ]; then
    echo "⚠️  FRANKEN_ALLOW_UNVERIFIED_OLLAMA=true: if Ollama has to be installed, the upstream"
    echo "   install script is run WITHOUT any integrity check."
else
    echo "ℹ️  No checksum for Ollama ${FRANKEN_OLLAMA_VERSION:-(no version pinned)}: if Ollama is already installed"
    echo "   (and matches the pin) it is kept; otherwise the install stops. Set FRANKEN_OLLAMA_VERSION to a"
    echo "   version in remote/ollama-checksums.txt, or add FRANKEN_OLLAMA_SHA256."
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

echo "Press Ctrl+C to cancel, or Enter to continue..."
read -r _

# Test SSH connection
echo "Testing SSH connection to $FRANKEN_SERVER_IP..."
if ! ssh -q -- "$FRANKEN_SERVER_IP" exit; then
    echo "❌ Cannot connect to $FRANKEN_SERVER_IP via SSH"
    echo "   Make sure:"
    echo "   1. The server is reachable"
    echo "   2. SSH keys are set up or you know the password"
    echo "   3. Your user has sudo access on the remote server"
    exit 1
fi
echo "✅ SSH connection successful"
echo ""

# Build the script to run on the server in a private local file (mktemp: mode
# 0600, unpredictable name), never at a fixed path.
PAYLOAD="$(mktemp)"
REMOTE_DIR=""
cleanup() {
    rm -f -- "$PAYLOAD"
    if [ -n "$REMOTE_DIR" ]; then
        ssh -- "$FRANKEN_SERVER_IP" "$(franken_sh_quote rm -rf -- "$REMOTE_DIR")" > /dev/null 2>&1 || true
    fi
}
trap cleanup EXIT
{
    echo '#!/bin/bash'
    cat "$SCRIPT_DIR/unit-lib.sh" "$SCRIPT_DIR/server-install.sh"
} > "$PAYLOAD"
LOCAL_SHA="$(franken_sha256_file "$PAYLOAD")"

# A private directory on the server: unpredictable name, mode 0700, owned by
# the operator. Another local account can neither pre-create nor swap the file.
echo "Preparing a private directory on $FRANKEN_SERVER_IP..."
REMOTE_DIR="$(ssh -- "$FRANKEN_SERVER_IP" "$(franken_sh_quote sh -c 'd=$(mktemp -d) && chmod 700 "$d" && printf "%s\n" "$d"')")"
if ! [[ "$REMOTE_DIR" =~ ^/[A-Za-z0-9/_.-]+$ ]]; then
    REMOTE_DIR=""
    echo "❌ Unexpected reply while creating the remote directory"
    exit 1
fi

echo "Copying installation script to $FRANKEN_SERVER_IP..."
scp -q -- "$PAYLOAD" "$FRANKEN_SERVER_IP:$REMOTE_DIR/install.sh"

# Verify the copy before running it: directory and file are regular, owned by
# the operator, private; and the content hash matches the local one.
VERIFY_SCRIPT='d=$1; f=$d/install.sh; me=$(id -u)
[ -d "$d" ] && [ ! -L "$d" ] && [ "$(stat -c %u "$d")" = "$me" ] && [ "$(stat -c %a "$d")" = 700 ] &&
[ -f "$f" ] && [ ! -L "$f" ] && [ "$(stat -c %u "$f")" = "$me" ] &&
chmod 700 "$f" && [ "$(stat -c %a "$f")" = 700 ] &&
[ "$(sha256sum "$f" | cut -d" " -f1)" = "$2" ]'
if ! ssh -- "$FRANKEN_SERVER_IP" "$(franken_sh_quote bash -c "$VERIFY_SCRIPT" _ "$REMOTE_DIR" "$LOCAL_SHA")"; then
    echo "❌ The copy on $FRANKEN_SERVER_IP failed verification (owner, mode, type or hash); not running it"
    exit 1
fi
echo "✅ Copy verified"

# SSH into remote and run installation. Every value is passed as one quoted
# argument; the remote directory is removed when the script ends.
echo ""
echo "Connecting to $FRANKEN_SERVER_IP and running installation..."
echo "You will be prompted for sudo password on the remote server."
echo ""

RUN_SCRIPT='d=$1; shift; trap "rm -rf -- \"\$d\"" EXIT; bash "$d/install.sh" "$@"'
ssh -t -- "$FRANKEN_SERVER_IP" "$(franken_sh_quote bash -c "$RUN_SCRIPT" _ "$REMOTE_DIR" \
    "$FRANKEN_GPU0_PORT" "$FRANKEN_GPU1_PORT" "$FRANKEN_BIND_ADDR" "$FRANKEN_SERVICE_USER" \
    "$FRANKEN_MEMORY_MAX" "$FRANKEN_TASKS_MAX" "$FRANKEN_OLLAMA_VERSION" "$FRANKEN_REQUIRE_GPU" \
    "$OLLAMA_SHA256" "$OLLAMA_SHA256_ASSET" "$FRANKEN_ALLOW_UNVERIFIED_OLLAMA")"
REMOTE_DIR=""

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
