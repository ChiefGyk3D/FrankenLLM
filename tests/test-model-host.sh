#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Test that bin/pull-model.sh, bin/add-model.sh and bin/pull-dual-models.sh
# reach Ollama at FRANKEN_BIND_ADDR when it is a valid specific address, and at
# their old host otherwise. Scripts run in a scratch copy of the repo (no .env)
# with stub ollama/ssh on PATH: no network, no real Ollama, no live config.
#
# Usage: tests/test-model-host.sh

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

# --- franken_model_host: unit level ------------------------------------------
check "host unset (localhost)" "localhost" "$(franken_model_host localhost '' 2>&1)"
check "host unset (127.0.0.1)" "127.0.0.1" "$(franken_model_host 127.0.0.1 '' 2>&1)"
check "host 0.0.0.0 -> default" "localhost" "$(franken_model_host localhost 0.0.0.0 2>&1)"
check "host set" "192.0.2.10" "$(franken_model_host localhost 192.0.2.10 2>&1)"
check "host set (127.0.0.1 default)" "192.0.2.10" "$(franken_model_host 127.0.0.1 192.0.2.10 2>&1)"
for v in "192.0.2.256" "example.com" "192.0.2.10; id" "\$(id)" "192.0.2.10
x" "192.0.2.10:80"; do
    check "host invalid stdout [$v]" "localhost" "$(franken_model_host localhost "$v" 2>/dev/null)"
    check "host invalid warns once [$v]" "WARNING: FRANKEN_BIND_ADDR is not a valid IPv4 address; using localhost" \
        "$(franken_model_host localhost "$v" 2>&1 >/dev/null)"
done
check "host unset: no warning" "" "$(franken_model_host localhost '' 2>&1 >/dev/null)"
check "host 0.0.0.0: no warning" "" "$(franken_model_host localhost 0.0.0.0 2>&1 >/dev/null)"

# --- scripts, end to end against stubs ---------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/remote" "$WORK/stub"
cp "$REPO/config.sh" "$WORK/"
cp "$REPO"/bin/pull-model.sh "$REPO"/bin/add-model.sh "$REPO"/bin/pull-dual-models.sh "$WORK/bin/"
cp "$REPO/remote/unit-lib.sh" "$WORK/remote/"
cat > "$WORK/stub/ollama" << 'STUB'
#!/bin/bash
echo "ollama OLLAMA_HOST=$OLLAMA_HOST args=$*" >> "$STUB_LOG"
STUB
cat > "$WORK/stub/ssh" << 'STUB'
#!/bin/bash
echo "ssh $*" >> "$STUB_LOG"
STUB
chmod +x "$WORK/stub/ollama" "$WORK/stub/ssh"

# run SCRIPT ARGS... with env from ENVV (array of VAR=value); sets LOG and ERR
ENVV=()
run() {
    local script="$1"; shift
    : > "$WORK/calls.log"
    # cd into the scratch dir: a hostile value that escapes quoting can then only
    # create files here, never in the repo.
    (cd "$WORK" && env -i PATH="$WORK/stub:$PATH" HOME="$WORK" STUB_LOG="$WORK/calls.log" \
        "${ENVV[@]}" bash "$WORK/bin/$script" "$@" > /dev/null 2> "$WORK/stderr")
    LOG=$(cat "$WORK/calls.log")
    ERR=$(cat "$WORK/stderr")
}

LOCAL=(FRANKEN_SERVER_IP=localhost FRANKEN_GPU_COUNT=2)

# defaults: byte-for-byte the old commands
ENVV=("${LOCAL[@]}")
run pull-model.sh m1
check "pull-model default" "ollama OLLAMA_HOST=http://localhost:11434 args=pull m1
ollama OLLAMA_HOST=http://localhost:11435 args=pull m1" "$LOG"
check "pull-model default: no stderr" "" "$ERR"
run pull-dual-models.sh m1 m2
check "pull-dual default" "ollama OLLAMA_HOST=http://localhost:11434 args=pull m1
ollama OLLAMA_HOST=http://localhost:11435 args=pull m2" "$LOG"
run add-model.sh 0 m1
check "add-model default (local)" "ollama OLLAMA_HOST=127.0.0.1:11434 args=pull m1" "$LOG"
run add-model.sh all m1
check "add-model all default" "ollama OLLAMA_HOST=127.0.0.1:11434 args=pull m1
ollama OLLAMA_HOST=127.0.0.1:11435 args=pull m1" "$LOG"

# 0.0.0.0 behaves as unset
ENVV=("${LOCAL[@]}" FRANKEN_BIND_ADDR=0.0.0.0)
run pull-model.sh m1
check "pull-model 0.0.0.0" "ollama OLLAMA_HOST=http://localhost:11434 args=pull m1
ollama OLLAMA_HOST=http://localhost:11435 args=pull m1" "$LOG"

# specific address
ENVV=("${LOCAL[@]}" FRANKEN_BIND_ADDR=192.0.2.10)
run pull-model.sh m1
check "pull-model bind" "ollama OLLAMA_HOST=http://192.0.2.10:11434 args=pull m1
ollama OLLAMA_HOST=http://192.0.2.10:11435 args=pull m1" "$LOG"
run pull-dual-models.sh m1 m2
check "pull-dual bind" "ollama OLLAMA_HOST=http://192.0.2.10:11434 args=pull m1
ollama OLLAMA_HOST=http://192.0.2.10:11435 args=pull m2" "$LOG"
run add-model.sh 1 m1
check "add-model bind (local)" "ollama OLLAMA_HOST=192.0.2.10:11435 args=pull m1" "$LOG"
ENVV=(FRANKEN_SERVER_IP=remote-host FRANKEN_GPU_COUNT=2 FRANKEN_BIND_ADDR=192.0.2.10)
run add-model.sh 0 m1
check "add-model bind (ssh)" "ssh -- remote-host 'env' 'OLLAMA_HOST=192.0.2.10:11434' 'ollama' 'pull' 'm1'" "$LOG"
ENVV=(FRANKEN_SERVER_IP=remote-host FRANKEN_GPU_COUNT=2)
run add-model.sh 0 m1
check "add-model default (ssh)" "ssh -- remote-host 'env' 'OLLAMA_HOST=127.0.0.1:11434' 'ollama' 'pull' 'm1'" "$LOG"

# invalid and hostile values: old host, one warning, value never in a command
for v in "192.0.2.256" "example.com" "192.0.2.10; touch $WORK/pwned" "\$(touch $WORK/pwned)" "192.0.2.10:80"; do
    ENVV=("${LOCAL[@]}" "FRANKEN_BIND_ADDR=$v")
    run pull-model.sh m1
    check "pull-model invalid [$v]" "ollama OLLAMA_HOST=http://localhost:11434 args=pull m1
ollama OLLAMA_HOST=http://localhost:11435 args=pull m1" "$LOG"
    check "pull-model invalid warns [$v]" "WARNING: FRANKEN_BIND_ADDR is not a valid IPv4 address; using localhost" "$ERR"
    run add-model.sh 0 m1
    check "add-model invalid [$v]" "ollama OLLAMA_HOST=127.0.0.1:11434 args=pull m1" "$LOG"
    check "add-model invalid warns [$v]" "WARNING: FRANKEN_BIND_ADDR is not a valid IPv4 address; using 127.0.0.1" "$ERR"
    run pull-dual-models.sh m1 m2
    check "pull-dual invalid [$v]" "ollama OLLAMA_HOST=http://localhost:11434 args=pull m1
ollama OLLAMA_HOST=http://localhost:11435 args=pull m2" "$LOG"
    check "no injected file [$v]" "no" "$([ -e "$WORK/pwned" ] && echo yes || echo no)"
done

# the repo root must be untouched by the run (guard bites if the scripts or stubs leak files)
check "repo root has no untracked files" "" "$(git -C "$REPO" status --porcelain --untracked-files=all 2>/dev/null | grep '^??')"

echo "model-host: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
