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
#   WATCHDOG_HOST=127.0.0.1           where Ollama listens
#   WATCHDOG_PORTS="11434 11435"      defaults to FRANKEN_GPU*_PORT from config.sh
#   WATCHDOG_REPEAT_HOURS=24          reminder interval while a problem lasts
#   WATCHDOG_REBOOT_GRACE_HOURS=72    how long a pending reboot is tolerated
#   WATCHDOG_USE_DOPPLER=true         re-run under `doppler run --` for secrets
# Channel settings are documented in watchdog-notify.sh and docs/WATCHDOG.md.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Secrets from Doppler instead of the env file, when asked for and available.
if [ "${WATCHDOG_USE_DOPPLER:-}" = "true" ] && [ -z "${WATCHDOG_IN_DOPPLER:-}" ] && command -v doppler > /dev/null; then
    export WATCHDOG_IN_DOPPLER=1
    exec doppler run -- "$0" "$@"
fi

[ -f "$PROJECT_ROOT/config.sh" ] && source "$PROJECT_ROOT/config.sh" > /dev/null  # prints a banner; keep it out of the journal
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
STATE_DIR="${WATCHDOG_STATE_DIR:-/var/lib/frankenllm}/watchdog"
PROC_VERSION="${WATCHDOG_PROC_NVIDIA_VERSION:-/proc/driver/nvidia/version}"
LIB_DIR="${WATCHDOG_LIBDIR:-/usr/lib/x86_64-linux-gnu}"
REBOOT_FILE="${WATCHDOG_REBOOT_FILE:-/run/reboot-required}"
NOW="${WATCHDOG_NOW:-$(date +%s)}"

if [ -n "${WATCHDOG_PORTS:-}" ]; then
    read -r -a PORTS <<< "$WATCHDOG_PORTS"
else
    PORTS=("${FRANKEN_GPU0_PORT:-11434}")
    [ "${FRANKEN_GPU_COUNT:-2}" -ge 2 ] && PORTS+=("${FRANKEN_GPU1_PORT:-11435}")
fi

PROB_KEYS=()
PROB_MSGS=()

problem() {
    PROB_KEYS+=("$1")
    PROB_MSGS+=("${2//|//}") # '|' separates the state file fields
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
        if ! curl -s -m 5 -o /dev/null -f "http://${HOST}:${port}/api/version"; then
            problem "ollama-${port}" "Ollama on port ${port} is not answering. Check: systemctl status ollama-gpu*."
            continue
        fi
        ps_json=$(curl -s -m 5 "http://${HOST}:${port}/api/ps") || continue
        cpu_models=$(printf '%s' "$ps_json" |
            jq -r '[.models[]? | select((.size // 0) > 0 and (.size_vram // 0) == 0) | .name] | join(", ")' 2> /dev/null) || continue
        if [ -n "$cpu_models" ]; then
            problem "gpu-cpu-${port}" "On port ${port}, ${cpu_models} has no VRAM and is running on the CPU. Requests will be 10x to 50x slower. Check nvidia-smi and the Ollama startup log."
        fi
    done
}

check_reboot() {
    local age_hours
    [ -e "$REBOOT_FILE" ] || return 0
    age_hours=$(((NOW - $(stat -c %Y "$REBOOT_FILE" 2> /dev/null || echo "$NOW")) / 3600))
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
        [[ "$first" =~ ^[0-9]+$ ]] || first="$NOW"
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        if [ $((NOW - last)) -ge $((REPEAT_HOURS * 3600)) ]; then
            remind_keys+=("$key|$msg|$first")
            lines_remind+="- ${msg} (since $(duration $((NOW - first))) ago)"$'\n'
        fi
    fi
done

# Anything with a state file that is no longer a problem has recovered.
for f in "$STATE_DIR"/*; do
    [ -f "$f" ] || continue
    key=$(basename "$f")
    still=0
    for k in "${PROB_KEYS[@]}"; do [ "$k" = "$key" ] && still=1; done
    if [ "$still" -eq 0 ]; then
        IFS='|' read -r first _ msg < "$f"
        [[ "$first" =~ ^[0-9]+$ ]] || first="$NOW"
        recovered_keys+=("$key")
        lines_recovered+="- ${msg} (was broken for $(duration $((NOW - first))))"$'\n'
    fi
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

if ! notify_all "$level" "$title" "$body"; then
    echo "alert was not delivered, will retry on the next run" >&2
    exit 1
fi

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
