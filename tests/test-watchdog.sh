#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Test scripts/watchdog.sh and scripts/watchdog-notify.sh. curl, nvidia-smi
# and python3 are stubs on a private PATH, the NVIDIA version files are fakes,
# and the scripts run from a temp copy with a cleaned environment: nothing
# touches a real server, driver, state directory, or webhook.
#
# Usage: tests/test-watchdog.sh

# Setup is strict (-e): any failure before the scratch directory is proven safe
# stops the run. -e is switched off below, because the scenarios deliberately
# run commands that fail.
set -eu
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq > /dev/null || { echo "jq is required"; exit 2; }

# workdir_ok DIR  succeeds only for a directory this run just created: an
# absolute path at least two levels deep, an existing directory, owned by us,
# and still empty. Everything below is written under it, so it must never be
# empty, "/" or a system directory such as /bin.
workdir_ok() {
    local d="${1:-}"
    [[ "$d" =~ ^/[^/]+/[^/].* ]] || return 1
    [ -d "$d" ] && [ -O "$d" ] && [ ! -L "$d" ] || return 1
    [ -z "$(ls -A -- "$d" 2> /dev/null)" ]
}

WORK="$(mktemp -d)" || {
    echo "mktemp failed" >&2
    exit 2
}
workdir_ok "$WORK" || {
    echo "refusing to run: [$WORK] is not a fresh private directory" >&2
    exit 2
}
trap 'rm -rf -- "$WORK"' EXIT
BIN="$WORK/bin"
SCRIPTS="$WORK/scripts"
mkdir -p "$BIN" "$SCRIPTS" "$WORK/lib"
cp "$REPO/scripts/watchdog.sh" "$REPO/scripts/watchdog-notify.sh" "$REPO/scripts/watchdog-env.sh" "$SCRIPTS/"

CALLS="$WORK/calls.log"   # one line per notification the stub curl received
ARGV="$WORK/argv.log"     # every curl argv, to prove secrets never appear in it
EMAILS="$WORK/emails.log"

# curl stub. API probes answer from files; anything else is a notification.
cat > "$BIN/curl" << 'STUB'
#!/bin/bash
cfg="" url="" want_code=0
echo "$*" >> "$STUB_ARGV"
while [ $# -gt 0 ]; do
    case "$1" in
        -K) cfg="$2"; shift 2 ;;
        -w) want_code=1; shift 2 ;;
        -m | -o | -X | -H | --data-binary | --proto | --proto-redir | --max-filesize) shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done
cfgtxt=""
[ -n "$cfg" ] && cfgtxt=$(cat "$cfg")
[ -z "$url" ] && url=$(printf '%s' "$cfgtxt" | sed -n 's/^url = "\(.*\)"$/\1/p')
case "$url" in
    */api/version)
        port=${url##*:}; port=${port%%/*}
        case " ${STUB_DOWN:-} " in *" $port "*) exit 22 ;; esac
        echo '{"version":"0.33.2"}'
        ;;
    */api/ps)
        port=${url##*:}; port=${port%%/*}
        cat "$STUB_DIR/ps-$port.json"
        ;;
    *)
        body=$(cat)
        printf '%s\t%s\t%s\n' "$url" "$(printf '%s' "$cfgtxt" | grep -v '^url' | tr '\n' ' ')" "$(printf '%s' "$body" | tr '\n' ' ')" >> "$STUB_CALLS"
        [ "$want_code" = 1 ] && printf '%s' "${STUB_HTTP_CODE:-204}"
        ;;
esac
STUB

cat > "$BIN/nvidia-smi" << 'STUB'
#!/bin/bash
if [ -n "${STUB_SMI_FAIL:-}" ]; then
    echo "Failed to initialize NVML: Driver/library version mismatch"
    exit 18
fi
echo "GPU 0: Fake GPU (UUID: GPU-0)"
STUB

cat > "$BIN/python3" << 'STUB'
#!/bin/bash
printf '%s\t%s\t%s\t%s\n' "${SMTP_HOST:-}" "${EMAIL_TO:-}" "${WD_TITLE:-}" "$(printf '%s' "${WD_BODY:-}" | tr '\n' ' ')" >> "$STUB_EMAILS"
[ -n "${STUB_EMAIL_FAIL:-}" ] && exit 1
exit 0
STUB
chmod +x "$BIN"/*
set +e # setup is done; scenarios run commands that are expected to fail

# --- scenario helpers --------------------------------------------------------

healthy() {
    rm -rf "$WORK/state" "$CALLS" "$ARGV" "$EMAILS" "$WORK/reboot-required"
    mkdir -p "$WORK/state"
    : > "$CALLS" && : > "$ARGV" && : > "$EMAILS"
    printf 'NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  595.99.02  Release Build\nGCC version:  gcc version 13.3.0\n' > "$WORK/proc-version"
    rm -f "$WORK/lib"/libnvidia-ml.so.*
    : > "$WORK/lib/libnvidia-ml.so.595.99.02"
    : > "$WORK/lib/libnvidia-ml.so.1"
    echo '{"models":[{"name":"gemma4:12b","size":8200000000,"size_vram":8200000000}]}' > "$WORK/ps-11434.json"
    echo '{"models":[{"name":"llama-guard3:8b","size":5800000000,"size_vram":5800000000}]}' > "$WORK/ps-11435.json"
    unset STUB_DOWN STUB_SMI_FAIL STUB_HTTP_CODE STUB_EMAIL_FAIL
}

# run_wd NOW [VAR=value ...]  -> runs the watchdog with a cleaned environment
run_wd() {
    local now="$1" testing=(WATCHDOG_TESTING=1)
    shift
    # TESTING_OFF=1 runs the script as production would: no test overrides.
    [ -n "${TESTING_OFF:-}" ] && testing=()
    env -i PATH="$BIN:/usr/bin:/bin" HOME="$WORK" \
        STUB_DIR="$WORK" STUB_CALLS="$CALLS" STUB_ARGV="$ARGV" STUB_EMAILS="$EMAILS" \
        STUB_DOWN="${STUB_DOWN:-}" STUB_SMI_FAIL="${STUB_SMI_FAIL:-}" STUB_HTTP_CODE="${STUB_HTTP_CODE:-}" \
        STUB_EMAIL_FAIL="${STUB_EMAIL_FAIL:-}" \
        "${testing[@]}" \
        WATCHDOG_STATE_DIR="$WORK/state" WATCHDOG_PROC_NVIDIA_VERSION="$WORK/proc-version" \
        WATCHDOG_LIBDIR="$WORK/lib" WATCHDOG_REBOOT_FILE="$WORK/reboot-required" \
        WATCHDOG_NOW="$now" "$@" \
        bash "$SCRIPTS/watchdog.sh" "${MODE_ARG:-check}" > "$WORK/out.log" 2>&1
    echo $? > "$WORK/rc"
}

rc() { cat "$WORK/rc"; }
state_count() { find "$WORK/state" -maxdepth 1 -type f ! -name .lock 2> /dev/null | wc -l | tr -d ' '; }
state_keys() { find "$WORK/state" -maxdepth 1 -type f ! -name .lock -printf '%f ' 2> /dev/null; }
calls() { wc -l < "$CALLS" | tr -d ' '; }

PASS=0
FAIL=0
check() {
    local name="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        PASS=$((PASS + 1))
        echo "  ok   $name"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL $name: got [$got] want [$want]"
    fi
}
contains() { # contains NAME FILE TEXT
    if grep -qF -- "$3" "$2"; then
        PASS=$((PASS + 1))
        echo "  ok   $1"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL $1: [$3] not found in $2"
    fi
}
lacks() {
    if grep -qF -- "$3" "$2"; then
        FAIL=$((FAIL + 1))
        echo "  FAIL $1: [$3] found in $2"
    else
        PASS=$((PASS + 1))
        echo "  ok   $1"
    fi
}

DISCORD="DISCORD_WEBHOOK_URL=https://discord.test/api/webhooks/1/secrettoken"
T0=1800000000
HOUR=3600

echo "healthy box"
healthy
run_wd $T0 "$DISCORD"
check "exit 0" "$(rc)" 0
check "no notification" "$(calls)" 0
check "no state written" "$(state_count)" 0

echo "driver skew alerts once, reminds late, recovers"
healthy
: > "$WORK/lib/libnvidia-ml.so.595.99.03"
rm "$WORK/lib/libnvidia-ml.so.595.99.02"
run_wd $T0 "$DISCORD"
check "exit 0" "$(rc)" 0
check "one notification" "$(calls)" 1
contains "names both versions" "$CALLS" "595.99.02 but the userland libraries are 595.99.03"
contains "goes to the webhook" "$CALLS" "https://discord.test/api/webhooks/1/secrettoken"
lacks "secret not in curl argv" "$ARGV" "secrettoken"
check "state recorded" "$(state_keys)" "gpu-skew "
run_wd $((T0 + 600)) "$DISCORD"
check "no repeat inside the interval" "$(calls)" 1
run_wd $((T0 + 25 * HOUR)) "$DISCORD"
check "reminder after 24h" "$(calls)" 2
contains "reminder says still broken" "$CALLS" "STILL BROKEN"
rm "$WORK/lib/libnvidia-ml.so.595.99.03"
: > "$WORK/lib/libnvidia-ml.so.595.99.02"
run_wd $((T0 + 26 * HOUR)) "$DISCORD"
check "recovery sent" "$(calls)" 3
contains "recovery text" "$CALLS" "RECOVERED"
check "state cleared" "$(state_count)" 0
run_wd $((T0 + 27 * HOUR)) "$DISCORD"
check "quiet after recovery" "$(calls)" 3

echo "nvidia-smi failing"
healthy
STUB_SMI_FAIL=1 run_wd $T0 "$DISCORD"
check "one notification" "$(calls)" 1
contains "quotes the driver error" "$CALLS" "version mismatch"

echo "model running on the CPU"
healthy
echo '{"models":[{"name":"gemma4:12b","size":8200000000,"size_vram":0}]}' > "$WORK/ps-11434.json"
run_wd $T0 "$DISCORD"
check "one notification" "$(calls)" 1
contains "names the model and port" "$CALLS" "On port 11434, gemma4:12b has no VRAM"
echo '{"models":[{"name":"x","size":0,"size_vram":0}]}' > "$WORK/ps-11434.json"
run_wd $((T0 + HOUR)) "$DISCORD"
contains "an empty model entry is not a CPU model" "$CALLS" "RECOVERED"

echo "ollama down"
healthy
STUB_DOWN="11435" run_wd $T0 "$DISCORD"
check "one notification" "$(calls)" 1
contains "names the dead port" "$CALLS" "Ollama on port 11435 is not answering"

echo "pending reboot"
healthy
: > "$WORK/reboot-required"
touch -d "@$((T0 - 10 * HOUR))" "$WORK/reboot-required"
run_wd $T0 "$DISCORD"
check "inside grace: quiet" "$(calls)" 0
touch -d "@$((T0 - 100 * HOUR))" "$WORK/reboot-required"
run_wd $T0 "$DISCORD"
check "past grace: alert" "$(calls)" 1
contains "says how long" "$CALLS" "pending for 100h"

echo "failed delivery is retried"
healthy
: > "$WORK/lib/libnvidia-ml.so.595.99.03"
rm "$WORK/lib/libnvidia-ml.so.595.99.02"
STUB_HTTP_CODE=500 run_wd $T0 "$DISCORD"
check "exit 1" "$(rc)" 1
check "state not written" "$(state_count)" 0
STUB_HTTP_CODE=204 run_wd $((T0 + 300)) "$DISCORD"
check "exit 0 on retry" "$(rc)" 0
check "state written after success" "$(state_keys)" "gpu-skew "

echo "no channel configured"
healthy
: > "$WORK/lib/libnvidia-ml.so.595.99.03"
rm "$WORK/lib/libnvidia-ml.so.595.99.02"
run_wd $T0
check "exit 1" "$(rc)" 1
contains "says so" "$WORK/out.log" "no channel configured"
check "state not written" "$(state_count)" 0

echo "every channel at once"
healthy
: > "$WORK/lib/libnvidia-ml.so.595.99.03"
rm "$WORK/lib/libnvidia-ml.so.595.99.02"
run_wd $T0 "$DISCORD" NTFY_URL=https://ntfy.test/frank NTFY_TOKEN=ntfysecret \
    MATRIX_HOMESERVER=https://matrix.test MATRIX_ACCESS_TOKEN=matrixsecret 'MATRIX_ROOM_ID=!room:matrix.test' \
    SMTP_HOST=smtp.test SMTP_FROM=a@test EMAIL_TO=b@test SMTP_PASSWORD=smtpsecret
check "exit 0" "$(rc)" 0
check "discord + ntfy + matrix" "$(calls)" 3
contains "ntfy url" "$CALLS" "https://ntfy.test/frank"
contains "ntfy priority high for a problem" "$CALLS" "Priority: high"
contains "matrix url encodes the room id" "$CALLS" "/rooms/%21room%3Amatrix.test/send/m.room.message/"
contains "matrix bearer from config, not argv" "$CALLS" "Authorization: Bearer matrixsecret"
lacks "ntfy token not in argv" "$ARGV" "ntfysecret"
lacks "matrix token not in argv" "$ARGV" "matrixsecret"
check "email sent" "$(wc -l < "$EMAILS" | tr -d ' ')" 1
contains "email addressed" "$EMAILS" "smtp.test	b@test"

echo "one channel failing does not lose the alert"
healthy
: > "$WORK/lib/libnvidia-ml.so.595.99.03"
rm "$WORK/lib/libnvidia-ml.so.595.99.02"
STUB_EMAIL_FAIL=1 run_wd $T0 SMTP_HOST=smtp.test SMTP_FROM=a@test EMAIL_TO=b@test "$DISCORD"
check "one channel failed: not recorded as notified, exit 1" "$(rc)" 1
check "delivered via discord meanwhile" "$(calls)" 1
contains "failure reported" "$WORK/out.log" "email delivery failed"

echo "--print is read-only"
healthy
: > "$WORK/lib/libnvidia-ml.so.595.99.03"
rm "$WORK/lib/libnvidia-ml.so.595.99.02"
MODE_ARG=--print run_wd $T0 "$DISCORD"
check "exit 1 with a problem" "$(rc)" 1
check "no notification" "$(calls)" 0
check "no state" "$(state_count)" 0

echo "never executes files from the checkout"
healthy
printf 'touch "%s/sourced-marker"\n' "$WORK" > "$WORK/config.sh"
printf 'touch "%s/sourced-marker"\n' "$WORK" > "$WORK/.env"
run_wd $T0 "$DISCORD"
check "config.sh and .env beside the scripts are ignored" "$(test -e "$WORK/sourced-marker" && echo sourced || echo ignored)" ignored
rm -f "$WORK/config.sh" "$WORK/.env"

# =============================================================================
# Hostile values. Every marker file below is the proof of code execution: it
# must never exist after a run.
# =============================================================================
MARK="$WORK/pwned"
ENVF="$WORK/test.env"
# PATH is always set, so under `set -u` Bash really evaluates the subscript
# (a bare x[...] dies as "unbound variable" before the command runs).
HOSTILE='PATH[$(touch '"$MARK"')]'
skew() {
    : > "$WORK/lib/libnvidia-ml.so.595.99.03"
    rm -f "$WORK/lib/libnvidia-ml.so.595.99.02"
}
nomark() {
    check "$1" "$(test -e "$MARK" && echo EXECUTED || echo clean)" clean
    rm -f "$MARK"
}
alert_run() { # a fresh skew problem, then run with the given settings
    healthy
    skew
    run_wd "$@"
}
has_line() { # has_line NAME REGEX FILE
    if grep -qE -- "$2" "$3"; then
        PASS=$((PASS + 1))
        echo "  ok   $1"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL $1: /$2/ not in $3"
    fi
}
envload() { # envload FILE -> runs the reader in a clean shell, output in o.log
    env -i PATH=/usr/bin:/bin bash -c 'source "$1"; wd_load_env "$2"; echo "rc=$? [${WATCHDOG_LABEL:-unset}] [${DISCORD_WEBHOOK_URL:-unset}]"' _ "$SCRIPTS/watchdog-env.sh" "$1" > "$WORK/o.log" 2>&1
}

echo "env file is data, never shell code"
printf '%s\n' '# comment' '' '  # indented comment' 'DISCORD_WEBHOOK_URL=$(touch "'"$MARK"'")' 'WATCHDOG_LABEL=a b "c" $HOME `x`' > "$ENVF"
envload "$ENVF"
contains "valid file loads" "$WORK/o.log" "rc=0"
contains "values are taken literally" "$WORK/o.log" '[a b "c" $HOME `x`] [$(touch'
nomark "command substitution in a value does not run"
bad_env() { # bad_env NAME CONTENT (printf %b escapes allowed)
    printf '%b' "$2" > "$ENVF"
    envload "$ENVF"
    contains "$1 is rejected, nothing exported" "$WORK/o.log" "rc=1 [unset] [unset]"
}
bad_env "line that is not KEY=VALUE (after a good line)" 'WATCHDOG_LABEL=ok\nBAD LINE\n'
bad_env "bare command" 'touch /x\n'
bad_env "unknown key" 'UNKNOWN_KEY=1\n'
bad_env "PATH key" 'PATH=/tmp\n'
bad_env "LD_PRELOAD key" 'LD_PRELOAD=/tmp/x.so\n'
bad_env "lowercase key" 'watchdog_label=x\n'
bad_env "CRLF line ending" 'WATCHDOG_LABEL=ok\r\n'
bad_env "tab in a value" 'WATCHDOG_LABEL=a\tb\n'
bad_env "escape character" 'WATCHDOG_LABEL=a\033b\n'
bad_env "NUL byte" 'WATCHDOG_LABEL=a\0b\n'
bad_env "export prefix" 'export WATCHDOG_LABEL=x\n'
rm -f "$ENVF"

echo "install-watchdog.sh test never executes the env file"
healthy
printf 'DISCORD_WEBHOOK_URL=$(touch "%s")\n' "$MARK" > "$ENVF"
chmod 600 "$ENVF"
env -i PATH="$BIN:/usr/bin:/bin" WATCHDOG_TESTING=1 WATCHDOG_ENV_FILE="$ENVF" WATCHDOG_INSTALLED_LIB="$SCRIPTS" \
    STUB_ARGV="$ARGV" STUB_CALLS="$CALLS" bash "$REPO/scripts/install-watchdog.sh" test > "$WORK/o.log" 2>&1
check "hostile file: exit 1" "$?" 1
nomark "hostile value is not executed as root would have"
printf 'touch "%s"\n' "$MARK" > "$ENVF"
chmod 600 "$ENVF"
env -i PATH="$BIN:/usr/bin:/bin" WATCHDOG_TESTING=1 WATCHDOG_ENV_FILE="$ENVF" WATCHDOG_INSTALLED_LIB="$SCRIPTS" \
    STUB_ARGV="$ARGV" STUB_CALLS="$CALLS" bash "$REPO/scripts/install-watchdog.sh" test > "$WORK/o.log" 2>&1
check "bare command line: exit 1" "$?" 1
nomark "bare command line is not executed"
printf 'DISCORD_WEBHOOK_URL=https://discord.test/api/webhooks/9/tok\n' > "$ENVF"
chmod 600 "$ENVF"
env -i PATH="$BIN:/usr/bin:/bin" WATCHDOG_TESTING=1 WATCHDOG_ENV_FILE="$ENVF" WATCHDOG_INSTALLED_LIB="$SCRIPTS" \
    STUB_ARGV="$ARGV" STUB_CALLS="$CALLS" bash "$REPO/scripts/install-watchdog.sh" test > "$WORK/o.log" 2>&1
check "good file: exit 0" "$?" 0
check "good file: one test alert sent" "$(calls)" 1
rm -f "$ENVF"

echo "numeric settings never reach arithmetic unchecked"
alert_run "$HOSTILE" "$DISCORD"
check "WATCHDOG_NOW hostile: exit 2" "$(rc)" 2
nomark "WATCHDOG_NOW hostile: no execution"
check "WATCHDOG_NOW hostile: nothing sent" "$(calls)" 0
alert_run $T0 "$DISCORD"
run_wd "$HOSTILE" "$DISCORD"
check "WATCHDOG_NOW hostile (state exists): exit 2" "$(rc)" 2
nomark "WATCHDOG_NOW hostile (state exists): no execution"
run_wd $((T0 + HOUR)) "$DISCORD" "WATCHDOG_REPEAT_HOURS=$HOSTILE"
check "REPEAT_HOURS hostile (state exists): exit 2" "$(rc)" 2
nomark "REPEAT_HOURS hostile: no execution"
run_wd $((T0 + HOUR)) "$DISCORD" "WATCHDOG_REBOOT_GRACE_HOURS=$HOSTILE"
check "REBOOT_GRACE_HOURS hostile: exit 2" "$(rc)" 2
nomark "REBOOT_GRACE_HOURS hostile: no execution"
run_wd $((T0 + HOUR)) "$DISCORD" "WATCHDOG_PORTS=11434 $HOSTILE"
check "PORTS hostile: exit 2" "$(rc)" 2
nomark "PORTS hostile: no execution"
printf 'WATCHDOG_REPEAT_HOURS=%s\n' "$HOSTILE" > "$ENVF"
run_wd $((T0 + HOUR)) "$DISCORD" WATCHDOG_ENV_FILE="$ENVF"
check "hostile value from the env file: exit 2" "$(rc)" 2
nomark "hostile value from the env file: no execution"
rm -f "$ENVF"
for bad in 0 -1 "1 2" 99999 abc 1.5 "" ; do
    alert_run $T0 "$DISCORD" "WATCHDOG_REPEAT_HOURS=${bad:-' '}"
    check "REPEAT_HOURS [$bad] rejected" "$(rc)" 2
done
for bad in 0 65536 99999999999999999999 "11434;x" "-1" "0x10"; do
    alert_run $T0 "$DISCORD" "WATCHDOG_PORTS=$bad"
    check "PORTS [$bad] rejected" "$(rc)" 2
done
alert_run $T0 "$DISCORD" "WATCHDOG_PORTS=1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17"
check "more than 16 ports rejected" "$(rc)" 2
alert_run "0$T0" "$DISCORD"
check "leading zeros are plain decimals" "$(rc)" 0

echo "the Ollama host stays on loopback"
for h in 169.254.169.254 example.com 10.0.0.5 '127.0.0.1@evil.test' '127.0.0.1/x' 'a b'; do
    alert_run $T0 "$DISCORD" "WATCHDOG_HOST=$h"
    check "host [$h] refused" "$(rc)" 2
    check "host [$h]: no request was made" "$(wc -c < "$ARGV" | tr -d ' ')" 0
done
alert_run $T0 "$DISCORD" WATCHDOG_HOST=10.0.0.5 WATCHDOG_ALLOW_REMOTE_HOST=true
check "remote host with the opt-in is allowed" "$(rc)" 0
contains "opt-in probes the named host" "$ARGV" "http://10.0.0.5:11434/api/version"
alert_run $T0 "$DISCORD" 'WATCHDOG_HOST=127.0.0.1@evil.test' WATCHDOG_ALLOW_REMOTE_HOST=true
check "opt-in does not allow URL tricks" "$(rc)" 2
alert_run $T0 "$DISCORD" WATCHDOG_HOST=::1
check "IPv6 loopback allowed" "$(rc)" 0
contains "IPv6 host is bracketed" "$ARGV" "http://[::1]:11434/api/version"
alert_run $T0 "$DISCORD" WATCHDOG_HOST=localhost
check "localhost allowed" "$(rc)" 0

echo "curl is restricted to the right protocols"
alert_run $T0 "$DISCORD"
contains "webhook curl: https only" "$ARGV" "--proto =https --proto-redir =https"
contains "probe curl: http only" "$ARGV" "--proto =http --max-filesize 1048576"
alert_run $T0 NTFY_URL=https://ntfy.test/frank NTFY_TOKEN=tok
contains "ntfy curl: https only" "$ARGV" "--proto =https --proto-redir =https"
alert_run $T0 MATRIX_HOMESERVER=https://matrix.test MATRIX_ACCESS_TOKEN=tok 'MATRIX_ROOM_ID=!r:matrix.test'
contains "matrix curl: https only" "$ARGV" "--proto =https --proto-redir =https"

echo "notification endpoints must be single-line https"
NL=$'\n'
for u in 'http://discord.test/x' 'file:///etc/passwd' 'gopher://x/' 'https://a/b c' "https://a/ok${NL}url = \"http://evil.test/\"" "https://a/ok"$'\r'; do
    alert_run $T0 "DISCORD_WEBHOOK_URL=$u"
    check "discord [${u//$'\n'/<LF>}] not sent" "$(calls)" 0
    check "discord [${u//$'\n'/<LF>}] reported failed" "$(rc)" 1
done
alert_run $T0 NTFY_URL=http://ntfy.test/x NTFY_TOKEN=tok
check "ntfy over http (with a token) not sent" "$(calls)" 0
alert_run $T0 NTFY_URL=https://ntfy.test/x "NTFY_TOKEN=tok${NL}url = \"http://evil.test/\""
check "ntfy token with a newline not sent" "$(calls)" 0
alert_run $T0 MATRIX_HOMESERVER=http://matrix.test MATRIX_ACCESS_TOKEN=tok 'MATRIX_ROOM_ID=!r:matrix.test'
check "matrix over http not sent" "$(calls)" 0
alert_run $T0 MATRIX_HOMESERVER=https://matrix.test "MATRIX_ACCESS_TOKEN=tok${NL}header = \"X: y\"" 'MATRIX_ROOM_ID=!r:matrix.test'
check "matrix token with a newline not sent" "$(calls)" 0
alert_run $T0 MATRIX_HOMESERVER=https://matrix.test MATRIX_ACCESS_TOKEN=tok "MATRIX_ROOM_ID=!r${NL}url = \"http://evil.test/\""
check "matrix room with a newline not sent" "$(calls)" 0

echo "the curl config writer refuses line breaks"
env -i PATH=/usr/bin:/bin bash -c 'source "$1"; _cfg url "https://a/b"' _ "$SCRIPTS/watchdog-notify.sh" > "$WORK/o.log" 2>&1
check "normal value: exact config line" "$(cat "$WORK/o.log")" 'url = "https://a/b"'
for v in $'a\nurl = "http://evil.test/"' $'a\rb' $'a\tb' $'a\033b'; do
    env -i PATH=/usr/bin:/bin bash -c 'source "$1"; _cfg url "$2"; echo "rc=$?"' _ "$SCRIPTS/watchdog-notify.sh" "$v" > "$WORK/o.log" 2>&1
    check "control character refused, no config text" "$(cat "$WORK/o.log")" "rc=1"
done

# SMOKE TEST ONLY. This runs the real curl against a local listener to show the
# whole path with a hostile value ends in a refused delivery and no connection.
# It does NOT prove the newline-injection fix: the old code also made no
# connection with this payload. That proof is the "config writer refuses line
# breaks" tests above, which fail on the old code.
echo "smoke: hostile URL ends in a refused delivery, no connection (real curl, local listener)"
REALCURL=$(PATH=/usr/bin:/bin command -v curl || true)
REALPY=$(PATH=/usr/bin:/bin command -v python3 || true)
if [ -n "$REALCURL" ] && [ -n "$REALPY" ]; then
    cat > "$WORK/listener.py" << 'PY'
import socket, sys
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(1)
print(s.getsockname()[1], flush=True)
s.settimeout(8)
try:
    c, _ = s.accept()
    open(sys.argv[1], "w").write("hit")
    c.close()
except Exception:
    pass
PY
    rm -f "$WORK/hit" "$WORK/port"
    "$REALPY" -I "$WORK/listener.py" "$WORK/hit" > "$WORK/port" &
    LPID=$!
    for _ in $(seq 1 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
    LPORT=$(cat "$WORK/port")
    INJ="https://127.0.0.1:1/ok\"${NL}url = \"http://127.0.0.1:${LPORT}/x"
    env -i PATH=/usr/bin:/bin bash -c 'source "$1"; DISCORD_WEBHOOK_URL=$2; notify_discord problem t b; echo "rc=$?"' _ "$SCRIPTS/watchdog-notify.sh" "$INJ" > "$WORK/o.log" 2>&1
    kill "$LPID" 2> /dev/null
    wait "$LPID" 2> /dev/null
    check "smoke: listener was not contacted" "$(test -e "$WORK/hit" && echo CONNECTED || echo blocked)" blocked
    contains "delivery reported as failed" "$WORK/o.log" "rc=1"
else
    echo "  skip real-curl smoke test: curl or python3 missing"
fi

echo "email is always TLS"
for sec in none NONE plain; do
    alert_run $T0 SMTP_HOST=smtp.test SMTP_FROM=a@test EMAIL_TO=b@test SMTP_USER=u SMTP_PASSWORD=p "SMTP_SECURITY=$sec"
    check "SMTP_SECURITY=$sec with credentials: no mail sent" "$(wc -l < "$EMAILS" | tr -d ' ')" 0
done
alert_run $T0 SMTP_HOST=smtp.test SMTP_FROM=a@test EMAIL_TO=b@test SMTP_SECURITY=none
check "SMTP_SECURITY=none without credentials: still no mail" "$(wc -l < "$EMAILS" | tr -d ' ')" 0
alert_run $T0 SMTP_HOST=smtp.test SMTP_FROM=a@test EMAIL_TO=b@test SMTP_SECURITY=ssl
check "SMTP_SECURITY=ssl is accepted" "$(wc -l < "$EMAILS" | tr -d ' ')" 1
alert_run $T0 SMTP_HOST=smtp.test SMTP_FROM=a@test EMAIL_TO=b@test
check "default (starttls) is accepted" "$(wc -l < "$EMAILS" | tr -d ' ')" 1
alert_run $T0 SMTP_HOST=smtp.test SMTP_FROM=a@test EMAIL_TO=b@test SMTP_PORT=70000
check "SMTP_PORT out of range: no mail" "$(wc -l < "$EMAILS" | tr -d ' ')" 0
alert_run $T0 "SMTP_HOST=smtp.test${NL}x" SMTP_FROM=a@test EMAIL_TO=b@test
check "SMTP_HOST with a newline: no mail" "$(wc -l < "$EMAILS" | tr -d ' ')" 0
alert_run $T0 SMTP_HOST=smtp.test SMTP_FROM=a@test "EMAIL_TO=b@test${NL}Bcc: x@test"
check "EMAIL_TO with a header injection: no mail" "$(wc -l < "$EMAILS" | tr -d ' ')" 0

echo "a huge /api/ps answer is not read"
healthy
{
    printf '{"models":[{"name":"big","size":5,"size_vram":0}],"pad":"'
    head -c 1200000 /dev/zero | tr '\0' a
    printf '"}'
} > "$WORK/ps-11434.json"
run_wd $T0 "$DISCORD"
check "oversize answer is ignored, not parsed" "$(calls)" 0
echo '{"models":[{"name":"small","size":5,"size_vram":0}]}' > "$WORK/ps-11434.json"
run_wd $T0 "$DISCORD"
check "a normal answer still alerts" "$(calls)" 1

echo "test-only overrides do nothing in production"
healthy
printf 'WATCHDOG_REPEAT_HOURS=abc\n' > "$ENVF"
TESTING_OFF=1 MODE_ARG=--print run_wd "$HOSTILE" "WATCHDOG_PROC_NVIDIA_VERSION=$WORK/nope-proc" \
    "WATCHDOG_STATE_DIR=$WORK/prod-state" WATCHDOG_ENV_FILE="$ENVF" "$DISCORD"
nomark "WATCHDOG_NOW ignored in production"
lacks "proc path override ignored in production" "$WORK/out.log" "$WORK/nope-proc"
check "env file override ignored in production" "$([ "$(rc)" = 2 ] && echo used || echo ignored)" ignored
check "state dir override ignored in production" "$(test -e "$WORK/prod-state" && echo created || echo absent)" absent
rm -f "$ENVF"

echo "the scratch-directory guard refuses unsafe paths"
ln -s "$WORK/lib" "$WORK/lnk"
mkdir "$WORK/fresh"
for bad in "" / /bin /usr /tmp relative "$WORK/does-not-exist" "$WORK" "$WORK/lnk"; do
    check "workdir_ok [$bad] refused" "$(workdir_ok "$bad" && echo ok || echo refused)" refused
done
check "workdir_ok accepts a fresh empty directory" "$(workdir_ok "$WORK/fresh" && echo ok || echo refused)" ok
rm -f "$WORK/lnk"
rmdir "$WORK/fresh"

echo "the installer never honors the test seam as root"
INSTALL="$REPO/scripts/install-watchdog.sh"
seam() { # seam UID [SWITCH]  -> allowed | refused (uid is a function-level stub)
    WATCHDOG_TESTING="${2-1}" bash -c 'source "$1"; stub_uid="$2"; current_uid() { echo "$stub_uid"; }; testing_seam_ok && echo allowed || echo refused' _ "$INSTALL" "$1"
}
check "seam refused for uid 0" "$(seam 0)" refused
check "seam allowed for a non-root uid with the switch" "$(seam 1000)" allowed
check "seam refused for a non-root uid without the switch" "$(seam 1000 "")" refused
healthy
mkdir "$WORK/decoy"
printf 'touch "%s"\n' "$MARK" > "$WORK/decoy/watchdog-env.sh"
printf 'DISCORD_WEBHOOK_URL=https://discord.test/api/webhooks/9/tok\n' > "$ENVF"
# uid stubbed to 0: the variables must be ignored, so nothing from the decoy
# directory is sourced and the real settings path is the one reported.
WATCHDOG_TESTING=1 WATCHDOG_ENV_FILE="$ENVF" WATCHDOG_INSTALLED_LIB="$WORK/decoy" PATH="$BIN:/usr/bin:/bin" \
    STUB_ARGV="$ARGV" STUB_CALLS="$CALLS" \
    bash -c 'source "$1"; current_uid() { echo 0; }; cmd_test' _ "$INSTALL" > "$WORK/o.log" 2>&1
nomark "as root the decoy WATCHDOG_INSTALLED_LIB is never sourced"
lacks "as root the WATCHDOG_ENV_FILE override is ignored" "$WORK/o.log" "$ENVF"
check "as root no test alert goes out through the overrides" "$(calls)" 0
# real (non-root) user, switch not set: the root-requiring path must refuse.
env -i PATH="$BIN:/usr/bin:/bin" WATCHDOG_ENV_FILE="$ENVF" WATCHDOG_INSTALLED_LIB="$SCRIPTS" \
    STUB_ARGV="$ARGV" STUB_CALLS="$CALLS" bash "$INSTALL" test > "$WORK/o.log" 2>&1
check "variables without the switch: refused" "$?" 1
check "variables without the switch: nothing sent" "$(calls)" 0
if [ "$(id -u)" -ne 0 ]; then
    contains "variables without the switch: says to run as root" "$WORK/o.log" "Run this as root"
fi
rm -rf "$WORK/decoy" "$ENVF"

# =============================================================================
# Polish round: per-channel retry, installer fail-fast, status and test use the
# real settings, settings file ownership.
# =============================================================================
EM=(SMTP_HOST=smtp.test SMTP_FROM=a@test EMAIL_TO=b@test)
mark_count() { find "$WORK/state/.sent" -maxdepth 1 -type f 2> /dev/null | wc -l | tr -d ' '; }
email_count() { wc -l < "$EMAILS" | tr -d ' '; }
unskew() { # fix the skew without wiping state
    rm -f "$WORK/lib"/libnvidia-ml.so.595.99.03
    : > "$WORK/lib/libnvidia-ml.so.595.99.02"
}

echo "a failed channel is retried, a delivered one is not re-sent"
healthy
skew
STUB_EMAIL_FAIL=1 run_wd $T0 "${EM[@]}" "$DISCORD"
check "partial: exit 1" "$(rc)" 1
check "partial: not recorded as notified" "$(state_count)" 0
check "partial: discord got it once" "$(calls)" 1
check "partial: email tried once" "$(email_count)" 1
run_wd $((T0 + 300)) "${EM[@]}" "$DISCORD"
check "retry: exit 0" "$(rc)" 0
check "retry: discord is not sent a second time" "$(calls)" 1
check "retry: email delivered" "$(email_count)" 2
check "retry: now recorded as notified" "$(state_keys)" "gpu-skew "
check "retry: markers cleared" "$(mark_count)" 0
run_wd $((T0 + 25 * HOUR)) "${EM[@]}" "$DISCORD"
check "reminder goes to every channel again" "$(calls)" 2

echo "a failed recovery notice is retried on the failed channel only"
healthy
skew
run_wd $T0 "${EM[@]}" "$DISCORD"
check "problem notified everywhere" "$(calls)/$(email_count)" "1/1"
unskew
STUB_EMAIL_FAIL=1 run_wd $((T0 + HOUR)) "${EM[@]}" "$DISCORD"
check "recovery partial: exit 1" "$(rc)" 1
check "recovery partial: state kept" "$(state_keys)" "gpu-skew "
run_wd $((T0 + HOUR + 300)) "${EM[@]}" "$DISCORD"
check "recovery retry: exit 0" "$(rc)" 0
check "recovery retry: discord not repeated" "$(calls)" 2
check "recovery retry: email delivered" "$(email_count)" 3
check "recovery retry: state cleared" "$(state_count)" 0

echo "a stale delivery marker does not suppress a later new problem"
healthy
skew
STUB_EMAIL_FAIL=1 run_wd $T0 "${EM[@]}" "$DISCORD"
check "marker left after a partial send" "$(mark_count)" 1
unskew
run_wd $((T0 + 300)) "${EM[@]}" "$DISCORD"
check "problem cleared before the retry: quiet" "$(rc)" 0
check "problem cleared before the retry: no state" "$(state_count)" 0
check "problem cleared before the retry: marker pruned" "$(mark_count)" 0
skew
run_wd $((T0 + 600)) "${EM[@]}" "$DISCORD"
check "the problem returns: discord is told again" "$(calls)" 2

echo "a delivery that cannot be recorded counts as failed"
healthy
skew
: > "$WORK/state/.sent" # a file where the marker directory must go: mkdir fails
run_wd $T0 "$DISCORD"
check "unrecorded delivery: exit 1" "$(rc)" 1
check "unrecorded delivery: not recorded as notified" "$(test -e "$WORK/state/gpu-skew" && echo recorded || echo none)" none
contains "unrecorded delivery: one diagnostic line" "$WORK/out.log" "delivery marker could not be written"
lacks "unrecorded delivery: no secret in the message" "$WORK/out.log" "secrettoken"

echo "status refuses a settings symlink"
SLIB="$WORK/status-lib"
mkdir -p "$SLIB" "$WORK/sbin"
cp "$SCRIPTS/watchdog-env.sh" "$SLIB/"
printf '#!/bin/bash\necho "PRINT label=[${WATCHDOG_LABEL:-}]"\n' > "$SLIB/watchdog.sh"
chmod +x "$SLIB/watchdog.sh"
printf 'WATCHDOG_LABEL=ViaLink\n' > "$WORK/link-target"
chmod 600 "$WORK/link-target"
ln -s "$WORK/link-target" "$ENVF"
env -i PATH="$BIN:/usr/bin:/bin" WATCHDOG_TESTING=1 WATCHDOG_ENV_FILE="$ENVF" WATCHDOG_INSTALLED_LIB="$SLIB" \
    bash "$INSTALL" status > "$WORK/o.log" 2>&1
lacks "status does not read through a symlink" "$WORK/o.log" "ViaLink"
contains "status says why" "$WORK/o.log" "symbolic link"
rm -f "$ENVF" "$WORK/link-target"
rm -rf "$SLIB" "$WORK/sbin"

echo "install-watchdog.sh test still succeeds when one channel delivers"
healthy
printf 'DISCORD_WEBHOOK_URL=https://discord.test/api/webhooks/9/tok\nSMTP_HOST=smtp.test\nSMTP_FROM=a@test\nEMAIL_TO=b@test\n' > "$ENVF"
chmod 600 "$ENVF"
env -i PATH="$BIN:/usr/bin:/bin" WATCHDOG_TESTING=1 WATCHDOG_ENV_FILE="$ENVF" WATCHDOG_INSTALLED_LIB="$SCRIPTS" \
    STUB_ARGV="$ARGV" STUB_CALLS="$CALLS" STUB_EMAILS="$EMAILS" STUB_EMAIL_FAIL=1 bash "$INSTALL" test > "$WORK/o.log" 2>&1
check "test alert: one channel is enough, exit 0" "$?" 0
rm -f "$ENVF"

echo "the installer stops at the first failed step"
IBIN="$WORK/ibin"
ILOG="$WORK/install-steps.log"
mkdir -p "$IBIN" "$WORK/inst-lib" "$WORK/inst-units" "$WORK/inst-etc"
for tool in install chown systemctl; do
    cat > "$IBIN/$tool" << 'STUB'
#!/bin/bash
echo "$(basename "$0") $*" >> "$STUB_STEPS"
case "$*" in *"${STUB_FAIL_ON:-@@none@@}"*) exit 1 ;; esac
exit 0
STUB
    chmod +x "$IBIN/$tool"
done
run_install() { # run_install FAIL_ON  -> cmd_install as a stubbed root, rc in o.log
    : > "$ILOG"
    env -i PATH="$IBIN:$BIN:/usr/bin:/bin" STUB_STEPS="$ILOG" STUB_FAIL_ON="$1" \
        bash -c 'source "$1"; current_uid() { echo 0; }; set_safe_path() { :; }; ENV_FILE="$2"; LIB_DIR="$3"; UNIT_DIR="$4"; cmd_install; echo "rc=$?"' \
        _ "$INSTALL" "$WORK/inst-etc/watchdog.env" "$WORK/inst-lib" "$WORK/inst-units" > "$WORK/o.log" 2>&1
}
printf 'WATCHDOG_LABEL=x\n' > "$WORK/inst-etc/watchdog.env"
chmod 644 "$WORK/inst-etc/watchdog.env"
run_install "@@none@@"
contains "all steps ok: success message" "$WORK/o.log" "Watchdog timer enabled."
contains "all steps ok: rc 0" "$WORK/o.log" "rc=0"
contains "existing settings file: owner set to root:root" "$ILOG" "chown root:root $WORK/inst-etc/watchdog.env"
check "existing settings file: mode 0600" "$(stat -c %a "$WORK/inst-etc/watchdog.env")" 600
for failing in "watchdog-notify.sh" "frankenllm-watchdog.timer" "root:root" "daemon-reload" "enable --now"; do
    printf 'WATCHDOG_LABEL=x\n' > "$WORK/inst-etc/watchdog.env"
    run_install "$failing"
    lacks "step [$failing] failed: no success message" "$WORK/o.log" "Watchdog timer enabled."
    lacks "step [$failing] failed: rc is not 0" "$WORK/o.log" "rc=0"
    contains "step [$failing] failed: says which step" "$WORK/o.log" "Install failed at:"
done
run_install "watchdog-notify.sh"
lacks "after a failed copy nothing is enabled" "$ILOG" "systemctl"
# A planted symbolic link at the settings path must never be chowned or chmodded.
rm -f "$WORK/inst-etc/watchdog.env"
printf 'unrelated\n' > "$WORK/link-target"
chmod 644 "$WORK/link-target"
ln -s "$WORK/link-target" "$WORK/inst-etc/watchdog.env"
run_install "@@none@@"
contains "symlink: refused with a message" "$WORK/o.log" "symbolic link"
lacks "symlink: no success message" "$WORK/o.log" "Watchdog timer enabled."
lacks "symlink: rc is not 0" "$WORK/o.log" "rc=0"
check "symlink: the target keeps its mode" "$(stat -c %a "$WORK/link-target")" 644
lacks "symlink: nothing was chowned" "$ILOG" "chown"
rm -f "$WORK/inst-etc/watchdog.env"
ln -s "$WORK/does-not-exist" "$WORK/inst-etc/watchdog.env"
run_install "@@none@@"
contains "dangling symlink: refused" "$WORK/o.log" "symbolic link"
lacks "dangling symlink: rc is not 0" "$WORK/o.log" "rc=0"
check "dangling symlink: nothing created at the target" "$(test -e "$WORK/does-not-exist" && echo created || echo absent)" absent
# test and status refuse it too
env -i PATH="$BIN:/usr/bin:/bin" WATCHDOG_TESTING=1 WATCHDOG_ENV_FILE="$WORK/inst-etc/watchdog.env" WATCHDOG_INSTALLED_LIB="$SCRIPTS" \
    STUB_ARGV="$ARGV" STUB_CALLS="$CALLS" bash "$INSTALL" test > "$WORK/o.log" 2>&1
check "test refuses a symlink: exit 1" "$?" 1
contains "test refuses a symlink: message" "$WORK/o.log" "symbolic link"
rm -f "$WORK/inst-etc/watchdog.env"
printf 'DISCORD_WEBHOOK_URL=https://discord.test/api/webhooks/9/tok\n' > "$WORK/link-target"
chmod 600 "$WORK/link-target"
ln -s "$WORK/link-target" "$WORK/inst-etc/watchdog.env"
healthy
env -i PATH="$BIN:/usr/bin:/bin" WATCHDOG_TESTING=1 WATCHDOG_ENV_FILE="$WORK/inst-etc/watchdog.env" WATCHDOG_INSTALLED_LIB="$SCRIPTS" \
    STUB_ARGV="$ARGV" STUB_CALLS="$CALLS" bash "$INSTALL" test > "$WORK/o.log" 2>&1
check "test refuses a symlink to a good file: exit 1" "$?" 1
check "test refuses a symlink to a good file: nothing sent" "$(calls)" 0
rm -f "$WORK/inst-etc/watchdog.env" "$WORK/link-target"
rm -rf "$IBIN" "$ILOG" "$WORK/inst-lib" "$WORK/inst-units" "$WORK/inst-etc"

echo "status loads the same settings the timer run loads"
SLIB="$WORK/status-lib"
mkdir -p "$SLIB" "$WORK/sbin"
cp "$SCRIPTS/watchdog-env.sh" "$SLIB/"
cat > "$SLIB/watchdog.sh" << 'STUB'
#!/bin/bash
echo "PRINT label=[${WATCHDOG_LABEL:-}] ports=[${WATCHDOG_PORTS:-}] doppler=[${WATCHDOG_USE_DOPPLER:-}]"
STUB
chmod +x "$SLIB/watchdog.sh"
printf '#!/bin/bash\nexit 0\n' > "$WORK/sbin/systemctl"
chmod +x "$WORK/sbin/systemctl"
status_run() {
    env -i PATH="$WORK/sbin:$BIN:/usr/bin:/bin" WATCHDOG_TESTING=1 WATCHDOG_ENV_FILE="$ENVF" WATCHDOG_INSTALLED_LIB="$SLIB" \
        bash "$INSTALL" status > "$WORK/o.log" 2>&1
}
printf 'WATCHDOG_LABEL=CustomBox\nWATCHDOG_PORTS=11500 11501\nWATCHDOG_USE_DOPPLER=true\n' > "$ENVF"
chmod 600 "$ENVF"
status_run
contains "status shows the custom label" "$WORK/o.log" "label=[CustomBox]"
contains "status shows the custom ports" "$WORK/o.log" "ports=[11500 11501]"
contains "status never starts the secrets manager" "$WORK/o.log" "doppler=[]"
printf 'WATCHDOG_LABEL=$(touch "%s")\n' "$MARK" > "$ENVF"
printf 'touch "%s"\n' "$MARK" >> "$ENVF"
chmod 600 "$ENVF"
status_run
nomark "status does not execute the settings file"
contains "status says a bad settings file was rejected" "$WORK/o.log" "rejected"
printf 'WATCHDOG_LABEL=CustomBox\n' > "$ENVF"
chmod 644 "$ENVF"
status_run
lacks "status ignores a world-readable settings file" "$WORK/o.log" "label=[CustomBox]"
contains "status says why" "$WORK/o.log" "group or others can access it"
rm -f "$ENVF"
rm -rf "$SLIB" "$WORK/sbin"

echo "test never runs the secrets manager client as root"
DBIN="$WORK/dbin"
DLOG="$WORK/doppler.log"
mkdir -p "$DBIN"
cat > "$DBIN/doppler" << 'STUB'
#!/bin/bash
echo "doppler $*" >> "$STUB_DOPPLER_LOG"
exit 0
STUB
chmod +x "$DBIN/doppler"
: > "$DLOG"
healthy
printf 'WATCHDOG_USE_DOPPLER=true\nDOPPLER_TOKEN=dp.st.fake\nDISCORD_WEBHOOK_URL=https://discord.test/api/webhooks/9/tok\n' > "$ENVF"
chmod 600 "$ENVF"
env -i PATH="$DBIN:$BIN:/usr/bin:/bin" WATCHDOG_TESTING=1 WATCHDOG_ENV_FILE="$ENVF" WATCHDOG_INSTALLED_LIB="$SCRIPTS" \
    STUB_ARGV="$ARGV" STUB_CALLS="$CALLS" STUB_DOPPLER_LOG="$DLOG" bash "$INSTALL" test > "$WORK/o.log" 2>&1
check "channel in the settings file still tested: exit 0" "$?" 0
check "channel in the settings file still tested: alert sent" "$(calls)" 1
check "the secrets client was never invoked" "$(wc -c < "$DLOG" | tr -d ' ')" 0
contains "says it does not fetch secrets as root" "$WORK/o.log" "does not fetch secrets as root"
contains "says how to test the secrets path" "$WORK/o.log" "systemctl start frankenllm-watchdog.service"
healthy
printf 'WATCHDOG_USE_DOPPLER=true\nDOPPLER_TOKEN=dp.st.fake\n' > "$ENVF"
chmod 600 "$ENVF"
env -i PATH="$DBIN:$BIN:/usr/bin:/bin" WATCHDOG_TESTING=1 WATCHDOG_ENV_FILE="$ENVF" WATCHDOG_INSTALLED_LIB="$SCRIPTS" \
    STUB_ARGV="$ARGV" STUB_CALLS="$CALLS" STUB_DOPPLER_LOG="$DLOG" bash "$INSTALL" test > "$WORK/o.log" 2>&1
check "secrets-only settings: nothing to test here, exit 1" "$?" 1
check "secrets-only settings: client still not invoked" "$(wc -c < "$DLOG" | tr -d ' ')" 0
contains "secrets-only settings: note printed" "$WORK/o.log" "does not fetch secrets as root"
rm -f "$ENVF" "$DLOG"
rm -rf "$DBIN"

echo "a hostile ambient PATH cannot redirect the tools run as root"
HBIN="$WORK/hostile-bin"
HLOG="$WORK/hostile.log"
mkdir -p "$HBIN" "$WORK/hlib"
for t in systemctl head; do
    printf '#!/bin/bash\necho "hostile %s" >> "%s"\nexit 0\n' "$t" "$HLOG" > "$HBIN/$t"
    chmod +x "$HBIN/$t"
done
printf '#!/bin/bash\necho "PRINT ran"\n' > "$WORK/hlib/watchdog.sh"
chmod +x "$WORK/hlib/watchdog.sh"
: > "$HLOG"
# As a stubbed root (no test switch): status must pin PATH before it runs anything.
env -i PATH="$HBIN:/usr/bin:/bin" bash -c 'source "$1"; current_uid() { echo 0; }; ENV_FILE="$2"; LIB_DIR="$3"; cmd_status; echo "PATH=$PATH"' \
    _ "$INSTALL" "$WORK/no-such.env" "$WORK/hlib" > "$WORK/o.log" 2>&1
check "no tool from the hostile PATH ran" "$(wc -c < "$HLOG" | tr -d ' ')" 0
contains "PATH was pinned to system directories" "$WORK/o.log" "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
rm -rf "$HBIN" "$HLOG" "$WORK/hlib"

echo "the settings file must be root-owned and private"
printf 'DISCORD_WEBHOOK_URL=https://discord.test/api/webhooks/9/tok\n' > "$ENVF"
for m in 640 644 604 660; do
    healthy
    chmod "$m" "$ENVF"
    env -i PATH="$BIN:/usr/bin:/bin" WATCHDOG_TESTING=1 WATCHDOG_ENV_FILE="$ENVF" WATCHDOG_INSTALLED_LIB="$SCRIPTS" \
        STUB_ARGV="$ARGV" STUB_CALLS="$CALLS" bash "$INSTALL" test > "$WORK/o.log" 2>&1
    check "mode $m refused" "$?" 1
    check "mode $m: nothing sent" "$(calls)" 0
    contains "mode $m: message" "$WORK/o.log" "group or others can access it"
done
chmod 600 "$ENVF"
perm_check() { # perm_check UID GID -> rc of check_settings_perms on $ENVF
    env -i PATH="$BIN:/usr/bin:/bin" bash -c 'source "$1"; check_settings_perms "$2" "$3" "$4" 2> /dev/null; echo "rc=$?"' _ "$INSTALL" "$ENVF" "$1" "$2" 2>&1
}
check "owner and mode right: accepted" "$(perm_check "$(id -u)" "$(id -g)")" "rc=0"
if [ "$(id -u)" -ne 0 ]; then
    check "not owned by root: refused" "$(perm_check 0 0)" "rc=1"
fi
rm -f "$ENVF"

echo "the unit file carries the hardening"
UNIT="$REPO/scripts/frankenllm-watchdog.service"
has_line "memory ceiling" '^MemoryMax=[0-9]+[MG]$' "$UNIT"
has_line "cpu ceiling" '^CPUQuota=[0-9]+%$' "$UNIT"
has_line "runtime timeout" '^TimeoutStartSec=[0-9]+$' "$UNIT"
has_line "address families" '^RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX$' "$UNIT"
has_line "settings arrive as a credential" '^LoadCredential=watchdog\.env:/etc/frankenllm/watchdog\.env$' "$UNIT"
has_line "dynamic user" '^DynamicUser=yes$' "$UNIT"
lacks "no EnvironmentFile (it is not parsed by our reader)" "$UNIT" "EnvironmentFile="
lacks "no PrivateDevices (nvidia-smi needs the device nodes)" "$UNIT" "PrivateDevices="
lacks "no state-dir override in the unit" "$UNIT" "WATCHDOG_STATE_DIR"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
