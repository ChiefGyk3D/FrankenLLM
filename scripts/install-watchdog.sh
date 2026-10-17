#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - install the watchdog
#
# Usage: sudo scripts/install-watchdog.sh <command>
#   install        copy scripts, install the systemd timer, create the env file
#   uninstall      stop the timer and remove the units (keeps env file and state)
#   test           send a test alert through every configured channel
#   status         show the timer and what the checks say right now
#   hold-nvidia    apt-mark hold every installed NVIDIA driver package
#   unhold-nvidia  undo hold-nvidia (do this before a deliberate driver upgrade)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
[ -f "$PROJECT_ROOT/config.sh" ] && source "$PROJECT_ROOT/config.sh" > /dev/null  # prints a banner; keep it out of the journal
INSTALL_DIR="${FRANKEN_INSTALL_DIR:-/opt/frankenllm}"
ENV_FILE="/etc/frankenllm/watchdog.env"
STATE_DIR="/var/lib/frankenllm"

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Run this as root:  sudo $0 $1" >&2
        exit 1
    fi
}

nvidia_packages() {
    dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2> /dev/null |
        awk '$1 == "ii" && $2 ~ /^(nvidia-|libnvidia-|xserver-xorg-video-nvidia)/ {print $2}'
}

cmd_install() {
    need_root install
    local missing=()
    for c in curl jq flock timeout nvidia-smi; do command -v "$c" > /dev/null || missing+=("$c"); done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Missing required commands: ${missing[*]}" >&2
        exit 1
    fi
    command -v python3 > /dev/null || echo "Note: python3 not found, email alerts will not work."

    mkdir -p "$INSTALL_DIR/scripts" "$STATE_DIR" /etc/frankenllm
    install -m 0755 "$SCRIPT_DIR/watchdog.sh" "$SCRIPT_DIR/watchdog-notify.sh" "$INSTALL_DIR/scripts/"
    [ -f "$PROJECT_ROOT/config.sh" ] && [ ! -f "$INSTALL_DIR/config.sh" ] && install -m 0644 "$PROJECT_ROOT/config.sh" "$INSTALL_DIR/config.sh"

    sed "s#/opt/frankenllm#$INSTALL_DIR#g" "$SCRIPT_DIR/frankenllm-watchdog.service" > /etc/systemd/system/frankenllm-watchdog.service
    install -m 0644 "$SCRIPT_DIR/frankenllm-watchdog.timer" /etc/systemd/system/frankenllm-watchdog.timer

    if [ ! -f "$ENV_FILE" ]; then
        install -m 0600 "$SCRIPT_DIR/watchdog.env.example" "$ENV_FILE"
        echo "Created $ENV_FILE. Fill in at least one channel, then run: sudo $0 test"
    else
        chmod 0600 "$ENV_FILE"
        echo "Kept your existing $ENV_FILE"
    fi

    systemctl daemon-reload
    systemctl enable --now frankenllm-watchdog.timer
    echo "Watchdog timer enabled."
}

cmd_uninstall() {
    need_root uninstall
    systemctl disable --now frankenllm-watchdog.timer 2> /dev/null || true
    rm -f /etc/systemd/system/frankenllm-watchdog.service /etc/systemd/system/frankenllm-watchdog.timer
    rm -f "$INSTALL_DIR/scripts/watchdog.sh" "$INSTALL_DIR/scripts/watchdog-notify.sh"
    systemctl daemon-reload
    echo "Removed. $ENV_FILE and $STATE_DIR/watchdog were left in place."
}

cmd_test() {
    need_root test
    [ -f "$ENV_FILE" ] || { echo "No $ENV_FILE yet. Run install first." >&2; exit 1; }
    (
        set -a
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        set +a
        # shellcheck source=watchdog-notify.sh
        source "$INSTALL_DIR/scripts/watchdog-notify.sh"
        notify_all recovery "[${WATCHDOG_LABEL:-FrankenLLM}] test alert" "If you can read this, this channel works."
    )
    case $? in
        0) echo "Delivered through at least one channel. Check where you expected it." ;;
        2) echo "No channel is configured in $ENV_FILE." >&2; exit 1 ;;
        *) echo "Every configured channel failed. See the messages above." >&2; exit 1 ;;
    esac
}

cmd_status() {
    systemctl list-timers frankenllm-watchdog.timer --no-pager 2> /dev/null | head -n 3
    echo
    (
        [ -f "$ENV_FILE" ] && [ -r "$ENV_FILE" ] && { set -a; source "$ENV_FILE"; set +a; }
        "$INSTALL_DIR/scripts/watchdog.sh" --print
    )
}

cmd_hold() {
    need_root hold-nvidia
    local pkgs
    pkgs=$(nvidia_packages)
    [ -n "$pkgs" ] || { echo "No NVIDIA driver packages installed." >&2; exit 1; }
    # shellcheck disable=SC2086
    apt-mark hold $pkgs
}

cmd_unhold() {
    need_root unhold-nvidia
    local pkgs
    pkgs=$(nvidia_packages)
    [ -n "$pkgs" ] || { echo "No NVIDIA driver packages installed." >&2; exit 1; }
    # shellcheck disable=SC2086
    apt-mark unhold $pkgs
}

case "${1:-}" in
    install) cmd_install ;;
    uninstall) cmd_uninstall ;;
    test) cmd_test ;;
    status) cmd_status ;;
    hold-nvidia) cmd_hold ;;
    unhold-nvidia) cmd_unhold ;;
    *) sed -n '5,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ; exit 2 ;;
esac
