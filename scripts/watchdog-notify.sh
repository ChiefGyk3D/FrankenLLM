#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - watchdog notifier
#
# Source this file, then call:  notify_all LEVEL TITLE BODY
#   LEVEL  problem | recovery   (picks the ntfy priority)
#
# A channel is on when its variables are set; nothing is hard-coded:
#   Discord  DISCORD_WEBHOOK_URL
#   ntfy     NTFY_URL            (optional NTFY_TOKEN)
#   Matrix   MATRIX_HOMESERVER, MATRIX_ACCESS_TOKEN, MATRIX_ROOM_ID
#   Email    SMTP_HOST, SMTP_FROM, EMAIL_TO  (optional SMTP_PORT, SMTP_USER,
#            SMTP_PASSWORD, SMTP_SECURITY=starttls|ssl)
#
# Endpoints must be single-line https URLs; every curl is limited to https
# (and https redirects). Email is always TLS (STARTTLS or implicit); there is
# no cleartext mode. Values with control characters are refused before they
# can reach a curl config or a mail header.
#
# Secrets reach curl through a config file descriptor, never argv, so they do
# not show up in `ps`. notify_all LEVEL TITLE BODY returns 0 when at least one
# channel delivered, 1 when channels are configured but none delivered, 2 when
# no channel is configured at all.
#
# With a fourth argument, notify_all LEVEL TITLE BODY MARKER_DIR KEY..., it
# tracks delivery per channel: a channel that delivered leaves a marker
# MARKER_DIR/KEY.CHANNEL for each KEY and is skipped on the retry, and the call
# returns 0 only when EVERY configured channel has delivered. The caller
# removes the markers once it has recorded the problem as notified.

# _clean VALUE...  succeeds only when no value has a control character
# (CR, LF, tab, escape, DEL). NUL cannot live in a Bash variable at all.
_clean() {
    local v
    for v in "$@"; do
        [[ "$v" =~ [[:cntrl:]] ]] && return 1
    done
    return 0
}

# _https_url VALUE  a single-line https URL with no whitespace
_https_url() {
    _clean "$1" && [[ "$1" =~ ^https://[^[:space:]]+$ ]]
}

# _cfg KEY VALUE  one curl config line; refuses values that could end the line
_cfg() {
    _clean "$2" || return 1
    local v="${2//\\/\\\\}"
    v="${v//\"/\\\"}"
    printf '%s = "%s"\n' "$1" "$v"
}

_http_ok() {
    case "$1" in 2??) return 0 ;; *) return 1 ;; esac
}

notify_discord() {
    local title="$2" body="$3" text code
    if ! _https_url "$DISCORD_WEBHOOK_URL"; then
        echo "notify: the Discord webhook must be a single-line https URL" >&2
        return 1
    fi
    text="**${title}**"$'\n'"${body}"
    text="${text:0:1900}"
    code=$(jq -n --arg c "$text" '{content: $c, allowed_mentions: {parse: []}}' |
        curl -sS -m 15 --proto '=https' --proto-redir '=https' -o /dev/null -w '%{http_code}' \
            -K <(_cfg url "$DISCORD_WEBHOOK_URL") \
            -H 'Content-Type: application/json' --data-binary @- 2> /dev/null) || return 1
    _http_ok "$code"
}

notify_ntfy() {
    local level="$1" title="$2" body="$3" prio tags code
    if ! _https_url "$NTFY_URL" || ! _clean "${NTFY_TOKEN:-}"; then
        echo "notify: the ntfy URL must be a single-line https URL and the token one line" >&2
        return 1
    fi
    case "$level" in
        problem) prio=high tags=warning ;;
        *) prio=default tags=white_check_mark ;;
    esac
    # HTTP header values must stay plain ASCII
    title=$(printf '%s' "$title" | tr -cd '\40-\176')
    code=$(printf '%s' "$body" |
        curl -sS -m 15 --proto '=https' --proto-redir '=https' -o /dev/null -w '%{http_code}' -X POST \
            -K <(
                _cfg url "$NTFY_URL"
                _cfg header "Title: $title"
                _cfg header "Priority: $prio"
                _cfg header "Tags: $tags"
                if [ -n "${NTFY_TOKEN:-}" ]; then _cfg header "Authorization: Bearer $NTFY_TOKEN"; fi
            ) --data-binary @- 2> /dev/null) || return 1
    _http_ok "$code"
}

notify_matrix() {
    local title="$2" body="$3" room txn code
    if ! _https_url "$MATRIX_HOMESERVER" || ! _clean "$MATRIX_ACCESS_TOKEN" "$MATRIX_ROOM_ID"; then
        echo "notify: the Matrix homeserver must be a single-line https URL and the token and room one line" >&2
        return 1
    fi
    room=$(jq -rn --arg s "$MATRIX_ROOM_ID" '$s | @uri')
    txn="fllm-$(date +%s)-$RANDOM"
    code=$(jq -n --arg b "${title}"$'\n'"${body}" '{msgtype: "m.text", body: $b}' |
        curl -sS -m 15 --proto '=https' --proto-redir '=https' -o /dev/null -w '%{http_code}' -X PUT \
            -K <(
                _cfg url "${MATRIX_HOMESERVER%/}/_matrix/client/v3/rooms/${room}/send/m.room.message/${txn}"
                _cfg header "Authorization: Bearer $MATRIX_ACCESS_TOKEN"
            ) -H 'Content-Type: application/json' --data-binary @- 2> /dev/null) || return 1
    _http_ok "$code"
}

# Standard-library SMTP so the box needs no local mail agent. Always TLS.
notify_email() {
    local title="$2" body="$3" mode port
    mode="${SMTP_SECURITY:-starttls}"
    mode="${mode,,}"
    port="${SMTP_PORT:-}"
    if ! _clean "$SMTP_HOST" "$SMTP_FROM" "$EMAIL_TO" "$port" "$mode" "${SMTP_USER:-}" "${SMTP_PASSWORD:-}"; then
        echo "notify: an email setting contains a control character" >&2
        return 1
    fi
    case "$mode" in starttls | ssl) ;; *)
        echo "notify: SMTP_SECURITY must be starttls or ssl (cleartext is not supported)" >&2
        return 1
        ;;
    esac
    if ! [[ "$SMTP_HOST" =~ ^[A-Za-z0-9.-]{1,253}$ ]]; then
        echo "notify: SMTP_HOST has characters that are not allowed" >&2
        return 1
    fi
    if [ -n "$port" ] && { ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || [ $((10#$port)) -lt 1 ] || [ $((10#$port)) -gt 65535 ]; }; then
        echo "notify: SMTP_PORT must be 1 to 65535" >&2
        return 1
    fi
    WD_TITLE="$title" WD_BODY="$body" SMTP_SECURITY="$mode" python3 -I -c '
import os, smtplib, ssl
from email.message import EmailMessage

host = os.environ["SMTP_HOST"]
mode = os.environ.get("SMTP_SECURITY", "starttls").lower()
if mode not in ("starttls", "ssl"):
    raise SystemExit(1)
port = int(os.environ.get("SMTP_PORT") or (465 if mode == "ssl" else 587))
msg = EmailMessage()
msg["Subject"] = os.environ["WD_TITLE"]
msg["From"] = os.environ["SMTP_FROM"]
msg["To"] = os.environ["EMAIL_TO"]
msg.set_content(os.environ["WD_BODY"])
ctx = ssl.create_default_context()
if mode == "ssl":
    server = smtplib.SMTP_SSL(host, port, timeout=20, context=ctx)
else:
    server = smtplib.SMTP(host, port, timeout=20)
with server:
    if mode == "starttls":
        server.starttls(context=ctx)
    if os.environ.get("SMTP_USER"):
        server.login(os.environ["SMTP_USER"], os.environ.get("SMTP_PASSWORD", ""))
    server.send_message(msg)
' 2> /dev/null
}

notify_all() {
    local level="$1" title="$2" body="$3" configured=0 delivered=0 failed=0 ch
    # Optional per-channel tracking: notify_all LEVEL TITLE BODY MARKER_DIR KEY...
    # A channel that delivered gets a marker per KEY; on a retry it is skipped.
    _MARK_DIR="${4:-}"
    _MARK_KEYS=("${@:5}")

    # Test-only: print instead of sending. Needs the explicit testing switch.
    if [ "${WATCHDOG_TESTING:-}" = "1" ] && [ "${WATCHDOG_DRY_RUN:-}" = "1" ]; then
        printf 'DRY RUN [%s] %s\n%s\n' "$level" "$title" "$body"
        return 0
    fi

    for ch in discord ntfy matrix email; do
        _channel_on "$ch" || continue
        configured=1
        if _marked "$ch"; then
            delivered=1
        elif "notify_$ch" "$level" "$title" "$body"; then
            delivered=1
            _mark "$ch"
        else
            failed=1
            echo "notify: $ch delivery failed" >&2
        fi
    done

    if [ "$configured" -eq 0 ]; then
        echo "notify: no channel configured, alert was not delivered" >&2
        return 2
    fi
    # With tracking, every channel must have delivered; without it (the test
    # alert) one is enough.
    if [ -n "$_MARK_DIR" ] && [ "${#_MARK_KEYS[@]}" -gt 0 ]; then
        [ "$failed" -eq 0 ]
    else
        [ "$delivered" -eq 1 ]
    fi
}

# _channel_on NAME  succeeds when that channel's settings are present
_channel_on() {
    case "$1" in
        discord) [ -n "${DISCORD_WEBHOOK_URL:-}" ] ;;
        ntfy) [ -n "${NTFY_URL:-}" ] ;;
        matrix) [ -n "${MATRIX_HOMESERVER:-}" ] && [ -n "${MATRIX_ACCESS_TOKEN:-}" ] && [ -n "${MATRIX_ROOM_ID:-}" ] ;;
        email) [ -n "${SMTP_HOST:-}" ] && [ -n "${SMTP_FROM:-}" ] && [ -n "${EMAIL_TO:-}" ] ;;
    esac
}

# _marked CHANNEL  succeeds when CHANNEL already delivered every tracked key
_marked() {
    local k
    [ -n "$_MARK_DIR" ] && [ "${#_MARK_KEYS[@]}" -gt 0 ] || return 1
    for k in "${_MARK_KEYS[@]}"; do
        [ -f "$_MARK_DIR/$k.$1" ] && [ ! -L "$_MARK_DIR/$k.$1" ] || return 1
    done
    return 0
}

_mark() {
    local k
    [ -n "$_MARK_DIR" ] && [ "${#_MARK_KEYS[@]}" -gt 0 ] || return 0
    mkdir -p "$_MARK_DIR" || return 0
    for k in "${_MARK_KEYS[@]}"; do : > "$_MARK_DIR/$k.$1"; done
}
