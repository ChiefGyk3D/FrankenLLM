#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Test that config.sh reads .env as data: hostile files are rejected or inert,
# nothing in them is executed. Everything runs in a scratch copy (no repo .env).
#
# Usage: tests/test-env-parse.sh

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$REPO/config.sh" "$WORK/"

PASS=0
FAIL=0
check() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc"
        echo "  want: $want"
        echo "  got:  $got"
    fi
}

# load_env CONTENT [VAR=value ...] -> sets OUT (value of the probe variable), RC, ERR
# The probe prints FRANKEN_SERVER_IP | FRANKEN_GPU0_NAME | FRANKEN_GPU0_MODEL.
load_env() {
    local content="$1"; shift
    printf '%s' "$content" > "$WORK/.env"
    OUT=$(cd "$WORK" && env -i PATH="$PATH" HOME="$WORK" "$@" bash -c \
        'source ./config.sh > /dev/null; printf "%s|%s|%s" "$FRANKEN_SERVER_IP" "$FRANKEN_GPU0_NAME" "$FRANKEN_GPU0_MODEL"' 2> "$WORK/stderr")
    RC=$?
    ERR=$(cat "$WORK/stderr")
}

# --- accepted syntax ---------------------------------------------------------
load_env 'FRANKEN_SERVER_IP=192.0.2.10
FRANKEN_GPU0_NAME="RTX 5060 Ti"
FRANKEN_GPU0_MODEL=gemma4:12b
'
check "plain file: rc" "0" "$RC"
check "plain file: values" "192.0.2.10|RTX 5060 Ti|gemma4:12b" "$OUT"

load_env "# comment

export FRANKEN_SERVER_IP='192.0.2.11'
  # indented comment
FRANKEN_GPU0_NAME=\"a b\"
FRANKEN_GPU0_MODEL=
"
check "comments, export, single quotes, empty value (default applies)" "192.0.2.11|a b|gemma4:12b" "$OUT"

load_env 'FRANKEN_SERVER_IP=192.0.2.12'
check "no trailing newline" "192.0.2.12|RTX 5060 Ti|gemma4:12b" "$OUT"

load_env 'FRANKEN_SERVER_IP=192.0.2.10
OTHER_THING=x
'
check "non-FRANKEN key ignored: rc" "0" "$RC"
check "non-FRANKEN key warns" "yes" "$(grep -q 'not FRANKEN_' <<< "$ERR" && echo yes || echo no)"

# environment wins over the file, including an explicit empty value
load_env 'FRANKEN_SERVER_IP=192.0.2.10
FRANKEN_GPU0_MODEL=from-file
' FRANKEN_SERVER_IP=192.0.2.99 FRANKEN_GPU0_MODEL=
check "env overrides file" "192.0.2.99|RTX 5060 Ti|gemma4:12b" "$OUT"

# --- hostile content: rejected, never executed -------------------------------
MARK="$WORK/executed"
HOSTILE=(
    "FRANKEN_SERVER_IP=\$(touch $MARK)"
    "FRANKEN_SERVER_IP=\`touch $MARK\`"
    "FRANKEN_SERVER_IP=\"\$(touch $MARK)\""
    "FRANKEN_SERVER_IP=\"\`touch $MARK\`\""
    "FRANKEN_SERVER_IP=\"\${IFS}\""
    "FRANKEN_SERVER_IP=192.0.2.10; touch $MARK"
    "FRANKEN_SERVER_IP=192.0.2.10 && touch $MARK"
    "FRANKEN_SERVER_IP=1 | touch $MARK"
    "FRANKEN_SERVER_IP=192.0.2.10 touch $MARK"
    "FRANKEN_SERVER_IP=\"a\\\"; touch $MARK; \""
    "FRANKEN_SERVER_IP='a'; touch $MARK"
    "FRANKEN_SERVER_IP=\"a\"b"
    "FRANKEN_SERVER_IP=\"unterminated"
    "FRANKEN_SERVER_IP=a#comment"
    "FRANKEN_SERVER_IP=\$'x'"
    "FRANKEN_SERVER_IP=<(touch $MARK)"
    "touch $MARK"
    "FRANKEN_SERVER_IP =x"
    "FRANKEN_SERVER_IP=a
FRANKEN_SERVER_IP=b"
    "FRANKEN_SERVER_IP=a$(printf '\t')b"
    "FRANKEN_SERVER_IP=a$(printf '\r')"
    "FRANKEN_SERVER_IP=a$(printf '\033')[0m"
    "x() { touch $MARK; }"
    "FRANKEN_X=\$(touch $MARK) FRANKEN_SERVER_IP=a"
)
for h in "${HOSTILE[@]}"; do
    rm -f "$MARK"
    load_env "$h
"
    check "hostile rejected (rc!=0) [${h//$'\n'/ / }]" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
    check "hostile not executed [${h//$'\n'/ / }]" "no" "$([ -e "$MARK" ] && echo yes || echo no)"
    check "hostile loads nothing [${h//$'\n'/ / }]" "" "$OUT"
done

# a bad line late in the file means nothing earlier is applied
load_env 'FRANKEN_SERVER_IP=192.0.2.50
FRANKEN_GPU0_MODEL=$(id)
'
check "bad later line: nothing loaded" "" "$OUT"

# the old behavior (source) would have executed this; prove the guard bites by
# showing a plain source of the same file does run it
rm -f "$MARK"
printf 'FRANKEN_SERVER_IP=$(touch %s)\n' "$MARK" > "$WORK/.env"
(cd "$WORK" && bash -c 'set -a; source ./.env; set +a' > /dev/null 2>&1)
check "negative control: plain source executes" "yes" "$([ -e "$MARK" ] && echo yes || echo no)"
rm -f "$MARK"

# the repo's own example file must still load cleanly
if [ -f "$REPO/.env.example" ]; then
    cp "$REPO/.env.example" "$WORK/.env"
    (cd "$WORK" && env -i PATH="$PATH" HOME="$WORK" bash -c 'source ./config.sh > /dev/null' 2> "$WORK/stderr")
    check ".env.example loads" "0" "$?"
fi

echo "env-parse: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
