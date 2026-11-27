#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - watchdog env file reader
#
# Source this file, then call:  wd_load_env FILE
#
# The one grammar for the watchdog settings file, used by the timer run and by
# `install-watchdog.sh test`. The file is DATA, never shell code. Allowed lines:
#   blank, a comment starting with #, or KEY=VALUE
# where KEY is on the allowlist below and VALUE is everything after the first
# '=', taken literally (no quotes, no expansion, no substitution). Any control
# character (CR, tab, NUL, escape) rejects the whole file. Nothing is exported
# unless the whole file is valid. Errors name the line number only, never the
# value, because values can be secrets.

WD_ENV_KEYS=" WATCHDOG_LABEL WATCHDOG_HOST WATCHDOG_PORTS WATCHDOG_REPEAT_HOURS WATCHDOG_REBOOT_GRACE_HOURS WATCHDOG_USE_DOPPLER WATCHDOG_ALLOW_REMOTE_HOST DOPPLER_TOKEN DISCORD_WEBHOOK_URL NTFY_URL NTFY_TOKEN MATRIX_HOMESERVER MATRIX_ACCESS_TOKEN MATRIX_ROOM_ID SMTP_HOST SMTP_PORT SMTP_SECURITY SMTP_USER SMTP_PASSWORD SMTP_FROM EMAIL_TO "

wd_load_env() {
    local file="$1" line key val n=0 i
    local keys=() vals=()
    if [ ! -r "$file" ]; then
        echo "env: cannot read the settings file" >&2
        return 1
    fi
    if [ "$(tr -d '\0' < "$file" | wc -c)" -ne "$(wc -c < "$file")" ]; then
        echo "env: the settings file contains a NUL byte" >&2
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        if [[ "$line" =~ [[:cntrl:]] ]]; then
            echo "env: line $n contains a control character" >&2
            return 1
        fi
        [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
        if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
        else
            echo "env: line $n is not KEY=VALUE or a comment" >&2
            return 1
        fi
        case "$WD_ENV_KEYS" in *" $key "*) ;; *)
            echo "env: line $n names a setting that is not allowed" >&2
            return 1
            ;;
        esac
        # Under `doppler run`, values Doppler supplied win over the file.
        if [ -n "${WATCHDOG_IN_DOPPLER:-}" ] && [ -n "${!key:-}" ]; then continue; fi
        keys+=("$key")
        vals+=("$val")
    done < "$file"
    for i in "${!keys[@]}"; do
        export "${keys[$i]}=${vals[$i]}"
    done
    return 0
}
