#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Test the Ollama version pin helpers in remote/unit-lib.sh. Pure: nothing is
# fetched or run, no network, no .env is read.
#
# Usage: tests/test-ollama-pin.sh

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../remote/unit-lib.sh
source "$REPO/remote/unit-lib.sh"

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

verdict() { if "$1" "$2"; then echo ok; else echo rejected; fi; }

# --- hostile values: version pin --------------------------------------------
for v in "v0.33.2" "0.33" "0.33.2.1" "0.33.2." ".0.33.2" "0..33.2" "0.33.2-rc" "0.33.2-rc1a" \
         "0.33.2-beta1" "0.33.2 " " 0.33.2" "0.33.2
" "0.33.2
OLLAMA_X=1" "0.33.2; id" "0.33.2 | sh" "\$(id)" "\`id\`" "0.33.2&&id" "0.33.2'" "0.33.2\"" \
         "0.33.2\\" "0 .33.2" "a.b.c" "latest" "-1.0.0" "0.33.2-rc1-rc2" ""; do
    check "version rejects [$v]" "rejected" "$(verdict franken_valid_ollama_version "$v")"
done
for v in "0.33.2" "0.0.0" "10.20.30" "0.33.2-rc1" "1.2.3-rc12"; do
    check "version accepts [$v]" "ok" "$(verdict franken_valid_ollama_version "$v")"
done

# --- installed version parsed from `ollama --version` output -----------------
check "parse plain" "0.33.2" "$(franken_ollama_parse_version 'ollama version is 0.33.2')"
check "parse with warning line" "0.33.2" "$(franken_ollama_parse_version 'Warning: could not connect to a running Ollama instance
Warning: client version is 0.33.2')"
check "parse rc" "0.34.0-rc1" "$(franken_ollama_parse_version 'ollama version is 0.34.0-rc1')"
check "parse none" "" "$(franken_ollama_parse_version 'garbage')"

echo "ollama-pin: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
