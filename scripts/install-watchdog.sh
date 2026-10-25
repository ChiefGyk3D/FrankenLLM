#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - install the watchdog
#
# Usage: sudo scripts/install-watchdog.sh <command>
#   install        copy scripts, install the systemd timer, create the env file
#   uninstall      stop the timer and remove the units (keeps the env file)
#   test           send a test alert through every configured channel
#   status         show the timer and what the checks say right now
#   hold-nvidia    apt-mark hold the installed NVIDIA driver packages
#   unhold-nvidia  undo hold-nvidia (do this before a deliberate driver upgrade)
#
# The scripts go to a root-owned directory and the unit runs as an unprivileged
# dynamic user. Nothing in the FrankenLLM checkout or /opt/frankenllm is ever
# executed or sourced by the timer, so write access to those cannot become root.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="/usr/local/lib/frankenllm"
ENV_FILE="/etc/frankenllm/watchdog.env"

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Run this as root:  sudo $0 $1" >&2
        exit 1
    fi
}

# The packages whose versions must move together: kernel module, userland
# libraries, utils, firmware. Not the CUDA toolkit, nvidia-settings or prime.
# A held package reports status "hi", not "ii", so match both or unhold would
# skip exactly the packages it exists to release.
nvidia_packages() {
    dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2> /dev/null |
        awk '$1 ~ /^(ii|hi)$/ && $2 ~ /^(nvidia-(driver|dkms|kernel-[a-z]+|utils|compute-utils|firmware)-|xserver-xorg-video-nvidia-|libnvidia-[a-z0-9-]+-)[0-9]/ {print $2}'
}

cmd_install() {
    need_root install
    local missing=() c
    for c in curl jq flock timeout nvidia-smi; do command -v "$c" > /dev/null || missing+=("$c"); done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Missing required commands: ${missing[*]}" >&2
        exit 1
    fi
    command -v python3 > /dev/null || echo "Note: python3 not found, email alerts will not work."

    install -d -m 0755 -o root -g root "$LIB_DIR" /etc/frankenllm
    install -m 0755 -o root -g root "$SCRIPT_DIR/watchdog.sh" "$SCRIPT_DIR/watchdog-notify.sh" "$LIB_DIR/"
    install -m 0644 -o root -g root "$SCRIPT_DIR/frankenllm-watchdog.service" "$SCRIPT_DIR/frankenllm-watchdog.timer" /etc/systemd/system/

    if [ ! -f "$ENV_FILE" ]; then
        install -m 0600 -o root -g root "$SCRIPT_DIR/watchdog.env.example" "$ENV_FILE"
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
    rm -f "$LIB_DIR/watchdog.sh" "$LIB_DIR/watchdog-notify.sh"
    systemctl daemon-reload
    echo "Removed. $ENV_FILE and /var/lib/frankenllm-watchdog were left in place."
}

cmd_test() {
    need_root test
    [ -f "$ENV_FILE" ] || { echo "No $ENV_FILE yet. Run install first." >&2; exit 1; }
    (
        set -a
        # shellcheck disable=SC1090  # operator-supplied env file, absent at lint time
        source "$ENV_FILE"
        set +a
        # shellcheck disable=SC1091  # installed copy, absent at lint time
        source "$LIB_DIR/watchdog-notify.sh"
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
    "$LIB_DIR/watchdog.sh" --print
}

cmd_hold() {
    need_root hold-nvidia
    local pkgs
    mapfile -t pkgs < <(nvidia_packages)
    [ "${#pkgs[@]}" -gt 0 ] || { echo "No NVIDIA driver packages installed." >&2; exit 1; }
    apt-mark hold "${pkgs[@]}"
}

cmd_unhold() {
    need_root unhold-nvidia
    local pkgs
    mapfile -t pkgs < <(nvidia_packages)
    [ "${#pkgs[@]}" -gt 0 ] || { echo "No NVIDIA driver packages installed." >&2; exit 1; }
    apt-mark unhold "${pkgs[@]}"
}

case "${1:-}" in
    install) cmd_install ;;
    uninstall) cmd_uninstall ;;
    test) cmd_test ;;
    status) cmd_status ;;
    hold-nvidia) cmd_hold ;;
    unhold-nvidia) cmd_unhold ;;
    *) sed -n '5,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
