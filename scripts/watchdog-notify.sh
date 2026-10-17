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
#            SMTP_PASSWORD, SMTP_SECURITY=starttls|ssl|none)
#
# Secrets reach curl through a config file descriptor, never argv, so they do
# not show up in `ps`. notify_all returns 0 when at least one channel
# delivered, 1 when channels are configured but none delivered, 2 when no
# channel is configured at all.

_cfg() {
    local v="${2//\\/\\\\}"
    v="${v//\"/\\\"}"
    printf '%s = "%s"\n' "$1" "$v"
}

_http_ok() {
    case "$1" in 2??) return 0 ;; *) return 1 ;; esac
}

notify_discord() {
    local title="$2" body="$3" text code
    text="**${title}**"$'\n'"${body}"
    text="${text:0:1900}"
    code=$(jq -n --arg c "$text" '{content: $c, allowed_mentions: {parse: []}}' |
        curl -sS -m 15 -o /dev/null -w '%{http_code}' \
            -K <(_cfg url "$DISCORD_WEBHOOK_URL") \
            -H 'Content-Type: application/json' --data-binary @- 2> /dev/null) || return 1
    _http_ok "$code"
}

notify_ntfy() {
    local level="$1" title="$2" body="$3" prio tags code
    case "$level" in
        problem) prio=high tags=warning ;;
        *) prio=default tags=white_check_mark ;;
    esac
    # HTTP header values must stay plain ASCII
    title=$(printf '%s' "$title" | tr -cd '\40-\176')
    code=$(printf '%s' "$body" |
        curl -sS -m 15 -o /dev/null -w '%{http_code}' -X POST \
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
    room=$(jq -rn --arg s "$MATRIX_ROOM_ID" '$s | @uri')
    txn="fllm-$(date +%s)-$RANDOM"
    code=$(jq -n --arg b "${title}"$'\n'"${body}" '{msgtype: "m.text", body: $b}' |
        curl -sS -m 15 -o /dev/null -w '%{http_code}' -X PUT \
            -K <(
                _cfg url "${MATRIX_HOMESERVER%/}/_matrix/client/v3/rooms/${room}/send/m.room.message/${txn}"
                _cfg header "Authorization: Bearer $MATRIX_ACCESS_TOKEN"
            ) -H 'Content-Type: application/json' --data-binary @- 2> /dev/null) || return 1
    _http_ok "$code"
}

# Standard-library SMTP so the box needs no local mail agent.
notify_email() {
    local title="$2" body="$3"
    WD_TITLE="$title" WD_BODY="$body" python3 -I -c '
import os, smtplib, ssl
from email.message import EmailMessage

host = os.environ["SMTP_HOST"]
mode = os.environ.get("SMTP_SECURITY", "starttls").lower()
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
    local level="$1" title="$2" body="$3" configured=0 delivered=0

    if [ "${WATCHDOG_DRY_RUN:-}" = "1" ]; then
        printf 'DRY RUN [%s] %s\n%s\n' "$level" "$title" "$body"
        return 0
    fi

    if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
        configured=1
        if notify_discord "$level" "$title" "$body"; then delivered=1; else echo "notify: Discord delivery failed" >&2; fi
    fi
    if [ -n "${NTFY_URL:-}" ]; then
        configured=1
        if notify_ntfy "$level" "$title" "$body"; then delivered=1; else echo "notify: ntfy delivery failed" >&2; fi
    fi
    if [ -n "${MATRIX_HOMESERVER:-}" ] && [ -n "${MATRIX_ACCESS_TOKEN:-}" ] && [ -n "${MATRIX_ROOM_ID:-}" ]; then
        configured=1
        if notify_matrix "$level" "$title" "$body"; then delivered=1; else echo "notify: Matrix delivery failed" >&2; fi
    fi
    if [ -n "${SMTP_HOST:-}" ] && [ -n "${SMTP_FROM:-}" ] && [ -n "${EMAIL_TO:-}" ]; then
        configured=1
        if notify_email "$level" "$title" "$body"; then delivered=1; else echo "notify: email delivery failed" >&2; fi
    fi

    if [ "$configured" -eq 0 ]; then
        echo "notify: no channel configured, alert was not delivered" >&2
        return 2
    fi
    [ "$delivered" -eq 1 ]
}
