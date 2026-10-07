#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Test the JSON warmup-models.sh sends to Ollama. curl is stubbed, nothing
# touches a real server and no .env is read (scripts run from a temp copy).
#
# Usage: tests/test-warmup-payloads.sh

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq > /dev/null || { echo "jq is required"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/stub"
cp "$REPO/config.sh" "$WORK/"
cp "$REPO/bin/warmup-models.sh" "$REPO/bin/warmup-lib.sh" "$WORK/bin/"

# curl stub: log "<-m value> <url> <body>" per call; reply from $STUB_REPLY
cat > "$WORK/stub/curl" << 'STUB'
#!/bin/bash
timeout="" url="" body=""
while [ $# -gt 0 ]; do
    case "$1" in
        -m) timeout="$2"; shift 2 ;;
        -d) body="$2"; shift 2 ;;
        -s) shift ;;
        *) url="$1"; shift ;;
    esac
done
printf '%s\t%s\t%s\n' "$timeout" "$url" "$body" >> "$STUB_LOG"
printf '%s' "${STUB_REPLY:-{\"response\":\"ok\"}}"
STUB
chmod +x "$WORK/stub/curl"

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

# run_warmup [VAR=value ...]  -> sets LOG (curl calls) and OUT (script stdout)
run_warmup() {
    LOGFILE="$WORK/curl.log"
    : > "$LOGFILE"
    OUT=$(env -i PATH="$WORK/stub:$PATH" HOME="$WORK" STUB_LOG="$LOGFILE" \
        FRANKEN_SERVER_IP=test-host "$@" bash "$WORK/bin/warmup-models.sh" 2>&1)
    LOG=$(cat "$LOGFILE")
}
# field <line-number> <1=timeout|2=url|3=body>
field() { sed -n "${1}p" <<< "$LOG" | cut -f"$2"; }
body() { field "$1" 3 | jq -c "$2"; }

# --- 1. Defaults: existing installs keep their layout, now with num_ctx ------
run_warmup
check "defaults: three requests" 3 "$(wc -l <<< "$LOG")"
check "defaults: gpu0 model+ctx" '["gemma4:12b",8192,-1]' "$(body 1 '[.model,.options.num_ctx,.keep_alive]')"
check "defaults: gpu0 url" "http://test-host:11434/api/generate" "$(field 1 2)"
check "defaults: gpu0 timeout" 180 "$(field 1 1)"
check "defaults: guard model+ctx" '["llama-guard3:8b",8192,-1]' "$(body 2 '[.model,.options.num_ctx,.keep_alive]')"
check "defaults: gpu1 model+ctx" '["qwen3.5:4b",32768,-1]' "$(body 3 '[.model,.options.num_ctx,.keep_alive]')"
check "defaults: gpu1 url" "http://test-host:11435/api/generate" "$(field 3 2)"
check "defaults: gpu1 timeout" 120 "$(field 3 1)"
check "defaults: stream off" false "$(body 1 '.stream')"
check "defaults: bodies are valid JSON" 3 "$(cut -f3 <<< "$LOG" | jq -c . | wc -l)"

# --- 2. Recommended 16 GB + 8 GB layout --------------------------------------
run_warmup FRANKEN_GPU0_MODEL=gemma4:12b FRANKEN_GPU0_CONTEXT=65536 \
    FRANKEN_GPU0_GUARD_MODEL= \
    FRANKEN_GPU0_EXTRA_MODEL=qwen3.5:4b FRANKEN_GPU0_EXTRA_CONTEXT=8192 \
    FRANKEN_GPU1_MODEL=llama-guard3:8b FRANKEN_GPU1_CONTEXT=8192
check "layout: three requests" 3 "$(wc -l <<< "$LOG")"
check "layout: backbone at 65536" '["gemma4:12b",65536]' "$(body 1 '[.model,.options.num_ctx]')"
check "layout: extra on gpu0 at its own ctx" '["qwen3.5:4b",8192]' "$(body 2 '[.model,.options.num_ctx]')"
check "layout: extra goes to gpu0 port" "http://test-host:11434/api/generate" "$(field 2 2)"
check "layout: guard on gpu1 at 8192" '["llama-guard3:8b",8192]' "$(body 3 '[.model,.options.num_ctx]')"
check "layout: guard goes to gpu1 port" "http://test-host:11435/api/generate" "$(field 3 2)"

# --- 3. GPU1 guard + per-model contexts + fallbacks --------------------------
run_warmup FRANKEN_GPU0_GUARD_MODEL= FRANKEN_GPU1_MODEL=qwen3.5:4b \
    FRANKEN_GPU1_CONTEXT=16384 FRANKEN_GPU1_GUARD_MODEL=llama-guard3:8b \
    FRANKEN_GPU0_EXTRA_MODEL=qwen3.5:4b
check "gpu1 guard: four requests" 4 "$(wc -l <<< "$LOG")"
check "extra without own ctx falls back to instance ctx" 8192 "$(body 2 '.options.num_ctx')"
check "gpu1 guard falls back to gpu1 instance ctx" '["llama-guard3:8b",16384]' "$(body 4 '[.model,.options.num_ctx]')"
run_warmup FRANKEN_GPU0_GUARD_MODEL= FRANKEN_GPU1_GUARD_MODEL=llama-guard3:8b \
    FRANKEN_GPU1_GUARD_CONTEXT=4096 FRANKEN_GPU1_CONTEXT=16384
check "gpu1 guard own ctx wins" 4096 "$(body 3 '.options.num_ctx')"

# --- 4. Configurable timeouts -------------------------------------------------
run_warmup FRANKEN_GPU0_GUARD_MODEL= FRANKEN_GPU0_WARMUP_TIMEOUT=300 FRANKEN_GPU1_WARMUP_TIMEOUT=45
check "gpu0 timeout override" 300 "$(field 1 1)"
check "gpu1 timeout override" 45 "$(field 2 1)"

# --- 5. Single GPU: nothing is sent to GPU 1 ----------------------------------
run_warmup FRANKEN_GPU_COUNT=1 FRANKEN_GPU1_GUARD_MODEL=llama-guard3:8b
check "single gpu: no gpu1 requests" 0 "$(grep -c ':11435/' <<< "$LOG")"

# --- 6. Command-line model args still win -------------------------------------
LOGFILE="$WORK/curl.log"
: > "$LOGFILE"
OUT=$(env -i PATH="$WORK/stub:$PATH" HOME="$WORK" STUB_LOG="$WORK/curl.log" \
    FRANKEN_SERVER_IP=test-host FRANKEN_GPU0_GUARD_MODEL= \
    bash "$WORK/bin/warmup-models.sh" argA:1b argB:2b 2>&1)
check "cli args: gpu0" argA:1b "$(jq -r .model <<< "$(sed -n 1p "$WORK/curl.log" | cut -f3)")"
check "cli args: gpu1" argB:2b "$(jq -r .model <<< "$(sed -n 2p "$WORK/curl.log" | cut -f3)")"

# --- 7. Failure is reported ---------------------------------------------------
run_warmup STUB_REPLY='{"error":"model not found"}' FRANKEN_GPU0_GUARD_MODEL=
check "failure reported" 2 "$(grep -c 'Failed to load' <<< "$OUT")"

# --- 8. Context lookup helper (also used by warmup-config.sh) ----------------
ctx() { # ctx <gpu> <model> [VAR=value ...]
    local gpu="$1" model="$2"; shift 2
    env -i PATH="$PATH" "$@" bash -c "source '$WORK/bin/warmup-lib.sh'; franken_ctx_for_model $gpu $model"
}
check "ctx: instance default" 65536 "$(ctx 0 gemma4:12b FRANKEN_GPU0_CONTEXT=65536)"
check "ctx: extra model" 8192 "$(ctx 0 qwen3.5:4b FRANKEN_GPU0_CONTEXT=65536 FRANKEN_GPU0_EXTRA_MODEL=qwen3.5:4b FRANKEN_GPU0_EXTRA_CONTEXT=8192)"
check "ctx: guard on gpu1" 4096 "$(ctx 1 llama-guard3:8b FRANKEN_GPU1_CONTEXT=8192 FRANKEN_GPU1_GUARD_MODEL=llama-guard3:8b FRANKEN_GPU1_GUARD_CONTEXT=4096)"
check "ctx: unset everything" 8192 "$(ctx 1 whatever)"

echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
