#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Test scripts/watchdog.sh and scripts/watchdog-notify.sh. curl, nvidia-smi
# and python3 are stubs on a private PATH, the NVIDIA version files are fakes,
# and the scripts run from a temp copy with a cleaned environment: nothing
# touches a real server, driver, state directory, or webhook.
#
# Usage: tests/test-watchdog.sh

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq > /dev/null || { echo "jq is required"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
SCRIPTS="$WORK/scripts"
mkdir -p "$BIN" "$SCRIPTS" "$WORK/lib"
cp "$REPO/scripts/watchdog.sh" "$REPO/scripts/watchdog-notify.sh" "$SCRIPTS/"

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
        -m | -o | -X | -H | --data-binary) shift 2 ;;
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
    local now="$1"
    shift
    env -i PATH="$BIN:/usr/bin:/bin" HOME="$WORK" \
        STUB_DIR="$WORK" STUB_CALLS="$CALLS" STUB_ARGV="$ARGV" STUB_EMAILS="$EMAILS" \
        STUB_DOWN="${STUB_DOWN:-}" STUB_SMI_FAIL="${STUB_SMI_FAIL:-}" STUB_HTTP_CODE="${STUB_HTTP_CODE:-}" \
        STUB_EMAIL_FAIL="${STUB_EMAIL_FAIL:-}" \
        WATCHDOG_STATE_DIR="$WORK/state" WATCHDOG_PROC_NVIDIA_VERSION="$WORK/proc-version" \
        WATCHDOG_LIBDIR="$WORK/lib" WATCHDOG_REBOOT_FILE="$WORK/reboot-required" \
        WATCHDOG_NOW="$now" "$@" \
        bash "$SCRIPTS/watchdog.sh" "${MODE_ARG:-check}" > "$WORK/out.log" 2>&1
    echo $? > "$WORK/rc"
}

rc() { cat "$WORK/rc"; }
state_count() { find "$WORK/state/watchdog" -maxdepth 1 -type f ! -name .lock 2> /dev/null | wc -l | tr -d ' '; }
state_keys() { find "$WORK/state/watchdog" -maxdepth 1 -type f ! -name .lock -printf '%f ' 2> /dev/null; }
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
check "delivered via discord, exit 0" "$(rc)" 0
contains "failure reported" "$WORK/out.log" "email delivery failed"

echo "--print is read-only"
healthy
: > "$WORK/lib/libnvidia-ml.so.595.99.03"
rm "$WORK/lib/libnvidia-ml.so.595.99.02"
MODE_ARG=--print run_wd $T0 "$DISCORD"
check "exit 1 with a problem" "$(rc)" 1
check "no notification" "$(calls)" 0
check "no state" "$(state_count)" 0

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
