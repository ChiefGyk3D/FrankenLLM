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
UNIT_DIR="/etc/systemd/system"

# The effective uid; a function so the test suite can stub it.
current_uid() { id -u; }

# The test seam (WATCHDOG_TESTING, WATCHDOG_ENV_FILE, WATCHDOG_INSTALLED_LIB) is
# honored only for a NON-root user. As root this script is a privilege boundary
# and an ambient variable must never redirect what it reads or sources.
testing_seam_ok() {
    [ "${WATCHDOG_TESTING:-}" = "1" ] && [ "$(current_uid)" -ne 0 ]
}

need_root() {
    if [ "$(current_uid)" -ne 0 ]; then
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

# step DESCRIPTION COMMAND...  runs one install step. On failure it names the
# step and returns non-zero so the caller stops. (No set -e: the test suite
# sources this file and must keep its own shell options.)
step() {
    local what="$1"
    shift
    "$@" || {
        echo "Install failed at: $what. Nothing further was done; fix the cause and run install again." >&2
        return 1
    }
}

cmd_install() {
    need_root install
    local missing=() c
    for c in curl jq flock timeout nvidia-smi; do command -v "$c" > /dev/null || missing+=("$c"); done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Missing required commands: ${missing[*]}" >&2
        return 1
    fi
    command -v python3 > /dev/null || echo "Note: python3 not found, email alerts will not work."

    step "create the directories" install -d -m 0755 -o root -g root "$LIB_DIR" "$(dirname "$ENV_FILE")" || return 1
    step "copy the watchdog scripts" install -m 0755 -o root -g root "$SCRIPT_DIR/watchdog.sh" "$SCRIPT_DIR/watchdog-notify.sh" "$SCRIPT_DIR/watchdog-env.sh" "$LIB_DIR/" || return 1
    step "install the systemd units" install -m 0644 -o root -g root "$SCRIPT_DIR/frankenllm-watchdog.service" "$SCRIPT_DIR/frankenllm-watchdog.timer" "$UNIT_DIR/" || return 1

    if [ ! -f "$ENV_FILE" ]; then
        step "create the settings file" install -m 0600 -o root -g root "$SCRIPT_DIR/watchdog.env.example" "$ENV_FILE" || return 1
        echo "Created $ENV_FILE. Fill in at least one channel, then run: sudo $0 test"
    else
        # Root-only: the file can hold secrets and `test` reads it as root.
        step "set the owner of the settings file" chown root:root "$ENV_FILE" || return 1
        step "set the mode of the settings file" chmod 0600 "$ENV_FILE" || return 1
        echo "Kept your existing $ENV_FILE (owner root:root, mode 0600)"
    fi

    step "reload systemd" systemctl daemon-reload || return 1
    step "enable the timer" systemctl enable --now frankenllm-watchdog.timer || return 1
    echo "Watchdog timer enabled."
}

cmd_uninstall() {
    need_root uninstall
    systemctl disable --now frankenllm-watchdog.timer 2> /dev/null || true
    rm -f "$UNIT_DIR/frankenllm-watchdog.service" "$UNIT_DIR/frankenllm-watchdog.timer"
    rm -f "$LIB_DIR/watchdog.sh" "$LIB_DIR/watchdog-notify.sh" "$LIB_DIR/watchdog-env.sh"
    systemctl daemon-reload
    echo "Removed. $ENV_FILE and /var/lib/frankenllm-watchdog were left in place."
}

# Sets ENV_FILE, LIB_DIR and the expected owner of the settings file. The test
# suite redirects them to scratch files, as a non-root user only.
resolve_paths() {
    EXPECT_UID=0
    EXPECT_GID=0
    if testing_seam_ok; then
        ENV_FILE="${WATCHDOG_ENV_FILE:-$ENV_FILE}"
        LIB_DIR="${WATCHDOG_INSTALLED_LIB:-$LIB_DIR}"
        EXPECT_UID="$(id -u)"
        EXPECT_GID="$(id -g)"
    fi
}

# check_settings_perms FILE UID GID  the settings file can hold secrets and is
# read as root: refuse one that someone else owns or that group or others can
# access, since they could swap it or read it.
check_settings_perms() {
    local file="$1" want_uid="$2" want_gid="$3" owner mode
    owner="$(stat -c '%u:%g' -- "$file" 2> /dev/null)" || {
        echo "Cannot inspect $file." >&2
        return 1
    }
    mode="$(stat -c '%a' -- "$file")"
    if [ "$owner" != "$want_uid:$want_gid" ]; then
        echo "Refusing to read $file: it must be owned by root (uid $want_uid, gid $want_gid). Fix: sudo chown root:root $file" >&2
        return 1
    fi
    if [ $((8#$mode & 8#077)) -ne 0 ]; then
        echo "Refusing to read $file: group or others can access it (mode $mode). Fix: sudo chmod 0600 $file" >&2
        return 1
    fi
    return 0
}

cmd_test() {
    if ! testing_seam_ok; then need_root test; fi
    resolve_paths
    [ -f "$ENV_FILE" ] || { echo "No $ENV_FILE yet. Run install first." >&2; exit 1; }
    check_settings_perms "$ENV_FILE" "$EXPECT_UID" "$EXPECT_GID" || exit 1
    (
        # The env file is data, never sourced: the restricted reader enforces
        # the same grammar the timer run uses.
        # shellcheck disable=SC1091  # installed copy, absent at lint time
        source "$LIB_DIR/watchdog-env.sh"
        wd_load_env "$ENV_FILE" || exit 1
        # Same secrets bootstrap as the timer run (watchdog.sh): with
        # WATCHDOG_USE_DOPPLER=true the channel settings come from Doppler and
        # values Doppler supplies win over the file.
        if [ "${WATCHDOG_USE_DOPPLER:-}" = "true" ] && [ -z "${WATCHDOG_IN_DOPPLER:-}" ]; then
            if command -v doppler > /dev/null; then
                export WATCHDOG_IN_DOPPLER=1
                exec doppler run -- bash -c '
                    source "$1/watchdog-env.sh"
                    wd_load_env "$2" || exit 1
                    source "$1/watchdog-notify.sh"
                    notify_all recovery "[${WATCHDOG_LABEL:-FrankenLLM}] test alert" "If you can read this, this channel works."
                ' _ "$LIB_DIR" "$ENV_FILE"
            fi
            echo "Note: WATCHDOG_USE_DOPPLER=true but doppler is not installed; using the settings file only." >&2
        fi
        # shellcheck disable=SC1091  # installed copy, absent at lint time
        source "$LIB_DIR/watchdog-notify.sh"
        notify_all recovery "[${WATCHDOG_LABEL:-FrankenLLM}] test alert" "If you can read this, this channel works."
    )
    case $? in
        0) echo "Delivered through at least one channel. Check where you expected it." ;;
        2) echo "No channel is configured in $ENV_FILE (or in Doppler, if enabled)." >&2; exit 1 ;;
        *) echo "Every configured channel failed. See the messages above." >&2; exit 1 ;;
    esac
}

cmd_status() {
    resolve_paths
    systemctl list-timers frankenllm-watchdog.timer --no-pager 2> /dev/null | head -n 3
    echo
    (
        # Load the same settings the timer run loads (host, ports, label), as
        # data through the restricted reader. Unreadable or unsafe: say so and
        # fall back to the defaults.
        if [ ! -r "$ENV_FILE" ]; then
            echo "Note: cannot read $ENV_FILE (run with sudo to use your settings); showing the defaults." >&2
        elif check_settings_perms "$ENV_FILE" "$EXPECT_UID" "$EXPECT_GID"; then
            # shellcheck disable=SC1091  # installed copy, absent at lint time
            source "$LIB_DIR/watchdog-env.sh"
            wd_load_env "$ENV_FILE" || echo "Note: the settings file was rejected; showing the defaults." >&2
        else
            echo "Note: showing the defaults." >&2
        fi
        # --print needs no secrets: never start the secrets manager for a look.
        unset WATCHDOG_USE_DOPPLER
        "$LIB_DIR/watchdog.sh" --print
    )
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

# Dispatch only when run, not when sourced (the tests source it to stub the uid).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        install) cmd_install || exit 1 ;;
        uninstall) cmd_uninstall ;;
        test) cmd_test ;;
        status) cmd_status ;;
        hold-nvidia) cmd_hold ;;
        unhold-nvidia) cmd_unhold ;;
        *) sed -n '5,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
    esac
fi
