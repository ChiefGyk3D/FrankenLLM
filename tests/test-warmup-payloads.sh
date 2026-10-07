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
if [ -n "${STUB_FAIL_MODEL:-}" ] && [[ "$body" == *"\"model\": \"$STUB_FAIL_MODEL\""* ]]; then
    printf '{"error":"model not found"}'
    exit 0
fi
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
        FRANKEN_SERVER_IP=test-host "$@" bash "$WORK/bin/warmup-models.sh" 2>"$WORK/stderr")
    RC=$?
    ERR=$(cat "$WORK/stderr")
    LOG=$(cat "$LOGFILE")
}
# field <line-number> <1=timeout|2=url|3=body>
field() { sed -n "${1}p" <<< "$LOG" | cut -f"$2"; }
body() { field "$1" 3 | jq -c "$2"; }

# --- 1. Defaults: same requests as before, plus keep_alive and NO num_ctx ----
run_warmup
check "defaults: exit 0" 0 "$RC"
check "defaults: three requests" 3 "$(wc -l <<< "$LOG")"
check "defaults: gpu0 model, no num_ctx, keep_alive" '["gemma4:12b",null,-1]' "$(body 1 '[.model,.options.num_ctx,.keep_alive]')"
check "defaults: gpu0 has no options at all" false "$(body 1 'has("options")')"
check "defaults: gpu0 url" "http://test-host:11434/api/generate" "$(field 1 2)"
check "defaults: gpu0 timeout" 180 "$(field 1 1)"
check "defaults: guard model, no num_ctx" '["llama-guard3:8b",false]' "$(body 2 '[.model,has("options")]')"
check "defaults: gpu1 model, no num_ctx" '["qwen3.5:4b",false,-1]' "$(body 3 '[.model,has("options"),.keep_alive]')"
check "defaults: gpu1 url" "http://test-host:11435/api/generate" "$(field 3 2)"
check "defaults: gpu1 timeout" 120 "$(field 3 1)"
check "defaults: stream off" false "$(body 1 '.stream')"
check "defaults: bodies are valid JSON" 3 "$(cut -f3 <<< "$LOG" | jq -c . | wc -l)"
check "defaults: no failure section" 0 "$(grep -c FAILED <<< "$OUT")"

# --- 2. Single GPU, NO new variables set --------------------------------------
run_warmup FRANKEN_GPU_COUNT=1
check "single gpu: exit 0" 0 "$RC"
check "single gpu: main + default guard only" 2 "$(wc -l <<< "$LOG")"
check "single gpu: nothing sent to gpu1" 0 "$(grep -c ':11435/' <<< "$LOG")"
check "single gpu: main body has no options" false "$(body 1 'has("options")')"
check "single gpu: no warning" "" "$ERR"
run_warmup FRANKEN_GPU_COUNT=1 FRANKEN_GPU0_GUARD_MODEL=
check "single gpu, guard disabled: only the main model" 1 "$(wc -l <<< "$LOG")"
check "single gpu, guard disabled: it is the main model" gemma4:12b "$(body 1 .model | tr -d '"')"

# --- 3. Warn when a GPU1 guard is set on a one-GPU install ---------------------
run_warmup FRANKEN_GPU_COUNT=1 FRANKEN_GPU1_GUARD_MODEL=llama-guard3:8b FRANKEN_GPU0_GUARD_MODEL=
check "gpu1 guard on one gpu: warns on stderr" 1 "$(grep -c 'FRANKEN_GPU1_GUARD_MODEL is set' <<< "$ERR")"
check "gpu1 guard on one gpu: not sent" 1 "$(wc -l <<< "$LOG")"
run_warmup FRANKEN_GPU1_GUARD_MODEL=llama-guard3:8b
check "no warning on two gpus" 0 "$(grep -c 'WARNING' <<< "$ERR")"

# --- 4. Optional split layout (placeholders for the card sizes) ---------------
run_warmup FRANKEN_GPU0_MODEL=gemma4:12b FRANKEN_GPU0_CONTEXT=65536 \
    FRANKEN_GPU0_GUARD_MODEL= \
    FRANKEN_GPU0_EXTRA_MODEL=qwen3.5:4b FRANKEN_GPU0_EXTRA_CONTEXT=8192 \
    FRANKEN_GPU1_MODEL=llama-guard3:8b FRANKEN_GPU1_CONTEXT=8192
check "split: three requests" 3 "$(wc -l <<< "$LOG")"
check "split: backbone sends no num_ctx (instance context applies)" false "$(body 1 'has("options")')"
check "split: extra sends its own ctx" '["qwen3.5:4b",8192]' "$(body 2 '[.model,.options.num_ctx]')"
check "split: extra goes to gpu0" "http://test-host:11434/api/generate" "$(field 2 2)"
check "split: gpu1 main sends no num_ctx" false "$(body 3 'has("options")')"

# --- 5. Guard/extra num_ctx only when their own *_CONTEXT is set --------------
run_warmup FRANKEN_GPU0_GUARD_MODEL= FRANKEN_GPU1_GUARD_MODEL=llama-guard3:8b \
    FRANKEN_GPU1_GUARD_CONTEXT=4096 FRANKEN_GPU1_CONTEXT=16384 \
    FRANKEN_GPU0_EXTRA_MODEL=qwen3.5:4b
check "gpu1 guard: four requests" 4 "$(wc -l <<< "$LOG")"
check "extra with no ctx sends no options" false "$(body 2 'has("options")')"
check "gpu1 guard own ctx sent" '["llama-guard3:8b",4096]' "$(body 4 '[.model,.options.num_ctx]')"
run_warmup FRANKEN_GPU0_GUARD_MODEL=llama-guard3:8b FRANKEN_GPU0_GUARD_CONTEXT=2048
check "gpu0 guard own ctx sent" 2048 "$(body 2 '.options.num_ctx')"
run_warmup FRANKEN_GPU0_GUARD_MODEL=llama-guard3:8b FRANKEN_GPU0_CONTEXT=65536
check "instance ctx never leaks into guard body" false "$(body 2 'has("options")')"

# --- 6. Configurable timeouts -------------------------------------------------
run_warmup FRANKEN_GPU0_GUARD_MODEL= FRANKEN_GPU0_WARMUP_TIMEOUT=300 FRANKEN_GPU1_WARMUP_TIMEOUT=45
check "gpu0 timeout override" 300 "$(field 1 1)"
check "gpu1 timeout override" 45 "$(field 2 1)"

# --- 7. Command-line model args still win -------------------------------------
LOGFILE="$WORK/curl.log"
: > "$LOGFILE"
env -i PATH="$WORK/stub:$PATH" HOME="$WORK" STUB_LOG="$LOGFILE" FRANKEN_SERVER_IP=test-host \
    FRANKEN_GPU0_GUARD_MODEL= bash "$WORK/bin/warmup-models.sh" argA:1b argB:2b > /dev/null 2>&1
check "cli args: gpu0" argA:1b "$(jq -r .model <<< "$(sed -n 1p "$LOGFILE" | cut -f3)")"
check "cli args: gpu1" argB:2b "$(jq -r .model <<< "$(sed -n 2p "$LOGFILE" | cut -f3)")"

# --- 8. One model fails, the others succeed ------------------------------------
run_warmup STUB_FAIL_MODEL=llama-guard3:8b
check "one failure: exit 1" 1 "$RC"
check "one failure: all three still attempted" 3 "$(wc -l <<< "$LOG")"
check "one failure: reported once as failed to load" 1 "$(grep -c 'Failed to load' <<< "$OUT")"
check "one failure: summary lists the failure" 1 "$(sed -n '/^FAILED/,$p' <<< "$OUT" | grep -c 'llama-guard3:8b')"
check "one failure: failed model is not listed as ready" 0 "$(sed -n '/^Loaded/,/^FAILED/p' <<< "$OUT" | grep -c 'llama-guard3:8b')"
check "one failure: others listed as loaded" 2 "$(sed -n '/^Loaded/,/^FAILED/p' <<< "$OUT" | grep -c '✅')"
run_warmup STUB_REPLY='{"error":"model not found"}'
check "all fail: exit 1" 1 "$RC"
check "all fail: nothing loaded" 0 "$(grep -c '^Loaded' <<< "$OUT")"

# --- 9. Validation of values put into the JSON body ---------------------------
run_warmup FRANKEN_GPU0_GUARD_MODEL='bad"model'
check "bad model name: exit 1" 1 "$RC"
check "bad model name: clear message" 1 "$(grep -c 'invalid model name' <<< "$OUT")"
check "bad model name: not sent" 2 "$(wc -l <<< "$LOG")"
run_warmup FRANKEN_GPU0_GUARD_MODEL='x; $(id)'
check "shell metacharacters rejected" 1 "$(grep -c 'invalid model name' <<< "$OUT")"
run_warmup FRANKEN_GPU0_EXTRA_MODEL=qwen3.5:4b FRANKEN_GPU0_EXTRA_CONTEXT='8192, "x": 1'
check "bad context: exit 1" 1 "$RC"
check "bad context: clear message" 1 "$(grep -c 'invalid context' <<< "$OUT")"
check "bad context: not sent" 3 "$(wc -l <<< "$LOG")"
run_warmup FRANKEN_GPU0_GUARD_MODEL=registry.example/ns/model-name_v2:1.5b@sha
check "legal odd name accepted" 0 "$RC"

# --- 10. Reply check: quoted key, with and without jq --------------------------
run_warmup STUB_REPLY='{"error":"the word response is in this error"}'
check "reply check: bare word is not success" 1 "$RC"
NOJQ=$(mktemp -d)
for t in bash env cat sed cut grep sort tr wc head tail mktemp dirname; do ln -s "$(command -v $t)" "$NOJQ/$t"; done
ln -s "$WORK/stub/curl" "$NOJQ/curl"
: > "$WORK/curl.log"
env -i PATH="$NOJQ" HOME="$WORK" STUB_LOG="$WORK/curl.log" FRANKEN_SERVER_IP=test-host \
    FRANKEN_GPU0_GUARD_MODEL= "$NOJQ/bash" "$WORK/bin/warmup-models.sh" > /dev/null 2>&1
check "reply check without jq: success" 0 "$?"
env -i PATH="$NOJQ" HOME="$WORK" STUB_LOG="$WORK/curl.log" STUB_REPLY='{"error":"the word response"}' FRANKEN_SERVER_IP=test-host \
    FRANKEN_GPU0_GUARD_MODEL= "$NOJQ/bash" "$WORK/bin/warmup-models.sh" > /dev/null 2>&1
check "reply check without jq: failure" 1 "$?"
rm -rf "$NOJQ"

# --- 11. Context lookup helper (also used by warmup-config.sh) ----------------
ctx() { # ctx <gpu> <model> [VAR=value ...]
    local gpu="$1" model="$2"; shift 2
    env -i PATH="$PATH" "$@" bash -c "source '$WORK/bin/warmup-lib.sh'; franken_ctx_for_model $gpu $model"
}
check "ctx: main model never gets one" "" "$(ctx 0 gemma4:12b FRANKEN_GPU0_CONTEXT=65536)"
check "ctx: extra model" 8192 "$(ctx 0 qwen3.5:4b FRANKEN_GPU0_CONTEXT=65536 FRANKEN_GPU0_EXTRA_MODEL=qwen3.5:4b FRANKEN_GPU0_EXTRA_CONTEXT=8192)"
check "ctx: extra model with no ctx set" "" "$(ctx 0 qwen3.5:4b FRANKEN_GPU0_EXTRA_MODEL=qwen3.5:4b)"
check "ctx: guard on gpu1" 4096 "$(ctx 1 llama-guard3:8b FRANKEN_GPU1_GUARD_MODEL=llama-guard3:8b FRANKEN_GPU1_GUARD_CONTEXT=4096)"
check "ctx: unset everything" "" "$(ctx 1 whatever)"

# --- 12. OLLAMA_VULKAN line in the generated systemd units -------------------
# Runs the real install script locally with sudo/curl/nvidia-smi stubbed; units
# land in $UNITS instead of /etc/systemd/system.
UNITS="$WORK/units"
mkdir -p "$WORK/scripts" "$WORK/vstub"
cp "$REPO/scripts/install-ollama-native.sh" "$WORK/scripts/"
cat > "$WORK/vstub/sudo" << 'STUB'
#!/bin/bash
if [ "$1" = tee ]; then cat > "$UNITS/$(basename "$2")"; else :; fi
STUB
printf '#!/bin/bash\nexit 0\n' > "$WORK/vstub/curl"
printf '#!/bin/bash\necho "GPU 0: Test Card (UUID: GPU-0)"\n' > "$WORK/vstub/nvidia-smi"
chmod +x "$WORK/vstub/sudo" "$WORK/vstub/curl" "$WORK/vstub/nvidia-smi"

# gen_units <with-nvidia-smi: yes|no> [VAR=value ...]  -> RC; units in $UNITS
gen_units() {
    local smi="$1"; shift
    rm -rf "$UNITS"; mkdir -p "$UNITS" "$WORK/home"
    local path="$WORK/vstub:$PATH"
    if [ "$smi" = no ]; then
        mkdir -p "$WORK/vstub-nosmi"
        ln -sf "$WORK/vstub/sudo" "$WORK/vstub/curl" "$WORK/vstub-nosmi/"
        printf '#!/bin/bash\nexit 9\n' > "$WORK/vstub-nosmi/nvidia-smi"
        chmod +x "$WORK/vstub-nosmi/nvidia-smi"
        path="$WORK/vstub-nosmi:$PATH"
    fi
    env -i PATH="$path" HOME="$WORK/home" USER=tester UNITS="$UNITS" \
        FRANKEN_SERVER_IP=localhost "$@" bash "$WORK/scripts/install-ollama-native.sh" > /dev/null 2>"$WORK/stderr"
    RC=$?
}
vulkan_lines() { grep -h '^Environment="OLLAMA_VULKAN=' "$UNITS"/ollama-gpu0.service "$UNITS"/ollama-gpu1.service 2> /dev/null | tr '\n' ' '; }

gen_units yes FRANKEN_OLLAMA_VULKAN=0
check "vulkan=0: install ok" 0 "$RC"
check "vulkan=0: line in both units" 'Environment="OLLAMA_VULKAN=0" Environment="OLLAMA_VULKAN=0" ' "$(vulkan_lines)"
check "vulkan=0: pin kept" 1 "$(grep -c '^Environment="CUDA_VISIBLE_DEVICES=1"' "$UNITS/ollama-gpu1.service")"

gen_units no FRANKEN_OLLAMA_VULKAN=1
check "vulkan=1: line in both units" 'Environment="OLLAMA_VULKAN=1" Environment="OLLAMA_VULKAN=1" ' "$(vulkan_lines)"

gen_units yes FRANKEN_OLLAMA_VULKAN=
check "vulkan empty: install ok" 0 "$RC"
check "vulkan empty: line omitted" "" "$(vulkan_lines)"

gen_units yes FRANKEN_OLLAMA_VULKAN=auto
check "vulkan auto + NVIDIA: 0 written" 'Environment="OLLAMA_VULKAN=0" Environment="OLLAMA_VULKAN=0" ' "$(vulkan_lines)"
gen_units yes
check "vulkan default (unset in env) + NVIDIA: 0 written" 'Environment="OLLAMA_VULKAN=0" Environment="OLLAMA_VULKAN=0" ' "$(vulkan_lines)"

gen_units no FRANKEN_OLLAMA_VULKAN=auto
check "vulkan auto, no NVIDIA: line omitted" "" "$(vulkan_lines)"

gen_units yes FRANKEN_OLLAMA_VULKAN=bogus
check "vulkan invalid: install fails" 1 "$RC"

echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
