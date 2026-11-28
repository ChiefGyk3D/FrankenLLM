#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - watchdog
#
# Runs on a timer, checks the things that silently turn a GPU inference box
# into a CPU one, and pushes an alert when one breaks. The boot-time
# auto-fix only looks once per boot, so a driver package upgraded mid-uptime
# (kernel module and userland drift apart) goes unnoticed until the next
# reboot while every model quietly runs on the CPU.
#
# Checks
#   gpu-nvml        nvidia-smi cannot talk to the driver
#   gpu-skew        loaded kernel module version differs from the userland libraries
#   gpu-cpu-<port>  a loaded model has no VRAM (it is running on the CPU)
#   ollama-<port>   an Ollama instance does not answer
#   reboot-pending  /run/reboot-required has been sitting longer than the grace period
#
# Behaviour: one alert when a problem appears, a reminder every
# WATCHDOG_REPEAT_HOURS while it lasts, one message when it clears. A failed
# delivery is retried on the next run.
#
# Usage: watchdog.sh [check|--print]
#   check    (default) run checks, notify, keep state
#   --print  run checks and print problems only: no state, no notifications
#
# Settings (environment, usually /etc/frankenllm/watchdog.env):
#   WATCHDOG_LABEL=FrankenLLM         name shown in alerts (never a hostname)
#   WATCHDOG_HOST=127.0.0.1           where Ollama listens (loopback only)
#   WATCHDOG_ALLOW_REMOTE_HOST=true   explicit opt-in to watch a non-loopback host
#   WATCHDOG_PORTS="11434 11435"      Ollama ports to check (default shown)
#   WATCHDOG_REPEAT_HOURS=24          reminder interval while a problem lasts
#   WATCHDOG_REBOOT_GRACE_HOURS=72    how long a pending reboot is tolerated
#   WATCHDOG_USE_DOPPLER=true         re-run under `doppler run --` for secrets
# Channel settings are documented in watchdog-notify.sh and docs/WATCHDOG.md.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Settings file: read as data by the restricted reader, never sourced. Under
# systemd it arrives as a credential; WATCHDOG_ENV_FILE is test-only.
# shellcheck source=watchdog-env.sh
source "$SCRIPT_DIR/watchdog-env.sh"
if [ "${WATCHDOG_TESTING:-}" = "1" ] && [ -n "${WATCHDOG_ENV_FILE:-}" ]; then
    wd_load_env "$WATCHDOG_ENV_FILE" || exit 2
elif [ -n "${CREDENTIALS_DIRECTORY:-}" ] && [ -f "$CREDENTIALS_DIRECTORY/watchdog.env" ]; then
    wd_load_env "$CREDENTIALS_DIRECTORY/watchdog.env" || exit 2
fi

# Secrets from Doppler instead of the env file, when asked for and available.
if [ "${WATCHDOG_USE_DOPPLER:-}" = "true" ] && [ -z "${WATCHDOG_IN_DOPPLER:-}" ] && command -v doppler > /dev/null; then
    export WATCHDOG_IN_DOPPLER=1
    exec doppler run -- "$0" "$@"
fi

# shellcheck source=watchdog-notify.sh
source "$SCRIPT_DIR/watchdog-notify.sh"

MODE="${1:-check}"
case "$MODE" in check | --print) ;; *)
    echo "Usage: $0 [check|--print]" >&2
    exit 2
    ;;
esac

LABEL="${WATCHDOG_LABEL:-FrankenLLM}"
HOST="${WATCHDOG_HOST:-127.0.0.1}"
REPEAT_HOURS="${WATCHDOG_REPEAT_HOURS:-24}"
REBOOT_GRACE_HOURS="${WATCHDOG_REBOOT_GRACE_HOURS:-72}"

# Paths and the clock can be overridden only by the test suite, which sets
# WATCHDOG_TESTING=1. In production the environment cannot move them.
STATE_DIR=/var/lib/frankenllm-watchdog
PROC_VERSION=/proc/driver/nvidia/version
LIB_DIR=/usr/lib/x86_64-linux-gnu
REBOOT_FILE=/run/reboot-required
NOW="$(date +%s)"
if [ "${WATCHDOG_TESTING:-}" = "1" ]; then
    STATE_DIR="${WATCHDOG_STATE_DIR:-$STATE_DIR}"
    PROC_VERSION="${WATCHDOG_PROC_NVIDIA_VERSION:-$PROC_VERSION}"
    LIB_DIR="${WATCHDOG_LIBDIR:-$LIB_DIR}"
    REBOOT_FILE="${WATCHDOG_REBOOT_FILE:-$REBOOT_FILE}"
    NOW="${WATCHDOG_NOW:-$NOW}"
fi

# Every value that reaches Bash arithmetic is checked first: Bash evaluates
# x[$(cmd)] inside $(( )), so a numeric setting must be plain bounded digits.
check_uint() { # check_uint NAME VALUE MIN MAX  -> prints the normalized number
    local v="$2"
    if ! [[ "$v" =~ ^[0-9]{1,11}$ ]] || [ $((10#$v)) -lt "$3" ] || [ $((10#$v)) -gt "$4" ]; then
        echo "watchdog: $1 must be a whole number from $3 to $4" >&2
        return 1
    fi
    printf '%d' $((10#$v))
}
REPEAT_HOURS=$(check_uint WATCHDOG_REPEAT_HOURS "$REPEAT_HOURS" 1 8760) || exit 2
REBOOT_GRACE_HOURS=$(check_uint WATCHDOG_REBOOT_GRACE_HOURS "$REBOOT_GRACE_HOURS" 0 8760) || exit 2
NOW=$(check_uint WATCHDOG_NOW "$NOW" 0 99999999999) || exit 2

# The watched Ollama stays on loopback unless the operator opts in.
if ! [[ "$HOST" =~ ^[A-Za-z0-9.:-]{1,253}$ ]]; then
    echo "watchdog: WATCHDOG_HOST has characters that are not allowed" >&2
    exit 2
fi
if ! [[ "$HOST" =~ ^(127(\.[0-9]{1,3}){3}|localhost|::1)$ ]] && [ "${WATCHDOG_ALLOW_REMOTE_HOST:-}" != "true" ]; then
    echo "watchdog: WATCHDOG_HOST must be a loopback address; set WATCHDOG_ALLOW_REMOTE_HOST=true to watch another host" >&2
    exit 2
fi
HOST_URL="$HOST"
case "$HOST" in *:*) HOST_URL="[$HOST]" ;; esac

# Deliberately does not source config.sh or any .env from the checkout: this
# runs on a timer and must not execute files other users can write.
read -r -a PORTS <<< "${WATCHDOG_PORTS:-11434 11435}"
if [ "${#PORTS[@]}" -lt 1 ] || [ "${#PORTS[@]}" -gt 16 ]; then
    echo "watchdog: WATCHDOG_PORTS must list 1 to 16 ports" >&2
    exit 2
fi
for i in "${!PORTS[@]}"; do
    PORTS[i]=$(check_uint "WATCHDOG_PORTS entry" "${PORTS[$i]}" 1 65535) || exit 2
done

MAX_BODY=1048576 # largest local HTTP answer we will read

PROB_KEYS=()
PROB_MSGS=()

problem() {
    local m="${2//[[:cntrl:]]/ }"
    PROB_MSGS+=("${m//|//}") # '|' separates the state file fields
    PROB_KEYS+=("$1")
}

# --- checks ------------------------------------------------------------------

check_gpu() {
    local out module userland
    if ! command -v nvidia-smi > /dev/null; then
        problem gpu-nvml "nvidia-smi is not installed or not on PATH. Check the NVIDIA driver packages."
        return
    fi
    if ! out=$(timeout 20 nvidia-smi -L 2>&1); then
        problem gpu-nvml "The NVIDIA driver is not answering: $(printf '%s' "$out" | head -n 1). Reboot the machine to reload the driver."
    fi

    [ -r "$PROC_VERSION" ] || {
        problem gpu-skew "No NVIDIA kernel module is loaded ($PROC_VERSION is missing). Check the driver install and reboot."
        return
    }
    module=$(head -n 1 "$PROC_VERSION" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1)
    userland=$(find "$LIB_DIR" -maxdepth 1 -name 'libnvidia-ml.so.*.*' 2> /dev/null |
        sed -n 's/.*libnvidia-ml\.so\.\([0-9][0-9.]*\)$/\1/p' | sort -V | tail -n 1)
    if [ -n "$module" ] && [ -n "$userland" ] && [ "$module" != "$userland" ]; then
        problem gpu-skew "NVIDIA kernel module is $module but the userland libraries are $userland. Ollama falls back to the CPU until the machine is rebooted."
    fi
}

check_ollama() {
    local port ps_json cpu_models
    for port in "${PORTS[@]}"; do
        if ! curl -s -m 5 --proto '=http' --max-filesize "$MAX_BODY" -o /dev/null -f "http://${HOST_URL}:${port}/api/version"; then
            problem "ollama-${port}" "Ollama on port ${port} is not answering. Check: systemctl status ollama-gpu*."
            continue
        fi
        # Bounded read: a hostile endpoint cannot make us buffer more than MAX_BODY.
        ps_json=$(
            curl -s -f -m 5 --proto '=http' --max-filesize "$MAX_BODY" "http://${HOST_URL}:${port}/api/ps" | head -c $((MAX_BODY + 1))
            exit "${PIPESTATUS[0]}"
        ) || continue
        [ "${#ps_json}" -le "$MAX_BODY" ] || continue
        cpu_models=$(printf '%s' "$ps_json" |
            jq -r '[.models[]? | select((.size // 0) > 0 and (.size_vram // 0) == 0) | .name] | join(", ")' 2> /dev/null) || continue
        if [ -n "$cpu_models" ]; then
            problem "gpu-cpu-${port}" "On port ${port}, ${cpu_models} has no VRAM and is running on the CPU. Requests will be 10x to 50x slower. Check nvidia-smi and the Ollama startup log."
        fi
    done
}

check_reboot() {
    local age_hours mtime
    [ -e "$REBOOT_FILE" ] || return 0
    mtime=$(stat -c %Y "$REBOOT_FILE" 2> /dev/null) || mtime="$NOW"
    [[ "$mtime" =~ ^[0-9]{1,11}$ ]] || mtime="$NOW"
    age_hours=$(((NOW - 10#$mtime) / 3600))
    if [ "$age_hours" -ge "$REBOOT_GRACE_HOURS" ]; then
        problem reboot-pending "A reboot has been pending for ${age_hours}h (grace is ${REBOOT_GRACE_HOURS}h). Updated drivers or kernel are not active yet."
    fi
}

# --- state and notification --------------------------------------------------

duration() {
    local s="$1"
    if [ "$s" -ge 86400 ]; then
        printf '%dd %dh' $((s / 86400)) $((s % 86400 / 3600))
    elif [ "$s" -ge 3600 ]; then
        printf '%dh %dm' $((s / 3600)) $((s % 3600 / 60))
    else
        printf '%dm' $((s / 60))
    fi
}

run_checks() {
    check_gpu
    check_ollama
    check_reboot
}

if [ "$MODE" = "--print" ]; then
    run_checks
    if [ "${#PROB_KEYS[@]}" -eq 0 ]; then
        echo "[$LABEL] all checks passed"
        exit 0
    fi
    for i in "${!PROB_KEYS[@]}"; do echo "- ${PROB_KEYS[$i]}: ${PROB_MSGS[$i]}"; done
    exit 1
fi

mkdir -p "$STATE_DIR" || {
    echo "cannot create $STATE_DIR" >&2
    exit 1
}
exec 9> "$STATE_DIR/.lock"
flock -n 9 || exit 0

run_checks

new_keys=() remind_keys=() recovered_keys=()
lines_new="" lines_remind="" lines_recovered=""

for i in "${!PROB_KEYS[@]}"; do
    key="${PROB_KEYS[$i]}"
    msg="${PROB_MSGS[$i]}"
    echo "problem: $key: $msg"
    if [ ! -f "$STATE_DIR/$key" ]; then
        new_keys+=("$key|$msg")
        lines_new+="- ${msg}"$'\n'
    else
        IFS='|' read -r first last _ < "$STATE_DIR/$key"
        # a damaged state file counts as "never told you", so you hear about it again
        [[ "$first" =~ ^[0-9]{1,11}$ ]] || first="$NOW"
        [[ "$last" =~ ^[0-9]{1,11}$ ]] || last=0
        first=$((10#$first))
        last=$((10#$last))
        if [ $((NOW - last)) -ge $((REPEAT_HOURS * 3600)) ]; then
            remind_keys+=("$key|$msg|$first")
            lines_remind+="- ${msg} (since $(duration $((NOW - first))) ago)"$'\n'
        fi
    fi
done

# Anything with a state file that is no longer a problem has recovered.
for f in "$STATE_DIR"/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    key=$(basename "$f")
    still=0
    for k in "${PROB_KEYS[@]}"; do [ "$k" = "$key" ] && still=1; done
    if [ "$still" -eq 0 ]; then
        IFS='|' read -r first _ msg < "$f"
        [[ "$first" =~ ^[0-9]{1,11}$ ]] || first="$NOW"
        first=$((10#$first))
        recovered_keys+=("$key")
        lines_recovered+="- ${msg} (was broken for $(duration $((NOW - first))))"$'\n'
    fi
done

# Delivery is tracked per channel: a channel that already got this message
# (marker per key and channel) is not sent it again on the retry, and the
# problem counts as notified only when every configured channel delivered.
MARK_DIR="$STATE_DIR/.sent"
send_keys=()
for entry in "${new_keys[@]}" "${remind_keys[@]}"; do
    IFS='|' read -r key _ <<< "$entry"
    send_keys+=("$key")
done
for key in "${recovered_keys[@]}"; do send_keys+=("recovered-$key"); done
# Markers that belong to nothing in this run's message are stale (the problem
# went away before the retry): drop them, even when there is nothing to send.
for m in "$MARK_DIR"/*; do
    [ -f "$m" ] || continue
    mk=$(basename "$m")
    mk="${mk%.*}"
    keep=0
    for k in "${send_keys[@]}"; do [ "$k" = "$mk" ] && keep=1; done
    [ "$keep" -eq 1 ] || rm -f -- "$m"
done

if [ -z "$lines_new$lines_remind$lines_recovered" ]; then
    [ "${#PROB_KEYS[@]}" -eq 0 ] && echo "[$LABEL] all checks passed"
    exit 0
fi

body=""
[ -n "$lines_new" ] && body+="NEW"$'\n'"$lines_new"
[ -n "$lines_remind" ] && body+="STILL BROKEN"$'\n'"$lines_remind"
[ -n "$lines_recovered" ] && body+="RECOVERED"$'\n'"$lines_recovered"

if [ -n "$lines_new$lines_remind" ]; then
    level=problem
    title="[$LABEL] needs attention"
else
    level=recovery
    title="[$LABEL] recovered"
fi

if ! notify_all "$level" "$title" "$body" "$MARK_DIR" "${send_keys[@]}"; then
    echo "alert was not delivered to every channel, will retry the missing ones on the next run" >&2
    exit 1
fi
for k in "${send_keys[@]}"; do rm -f -- "$MARK_DIR/$k".*; done

for entry in "${new_keys[@]}"; do
    IFS='|' read -r key msg <<< "$entry"
    printf '%s|%s|%s\n' "$NOW" "$NOW" "$msg" > "$STATE_DIR/$key"
done
for entry in "${remind_keys[@]}"; do
    IFS='|' read -r key msg first <<< "$entry"
    printf '%s|%s|%s\n' "$first" "$NOW" "$msg" > "$STATE_DIR/$key"
done
for key in "${recovered_keys[@]}"; do
    rm -f "$STATE_DIR/$key"
done
exit 0
