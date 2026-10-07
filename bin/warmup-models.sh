#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Warm up GPUs with their designated models
# This loads models into GPU memory so they're ready to use.
#
# Every model is loaded with keep_alive -1. Main models (FRANKEN_GPU0_MODEL,
# FRANKEN_GPU1_MODEL) send no num_ctx, so they load at the instance's
# OLLAMA_CONTEXT_LENGTH. The optional guard/extra models send options.num_ctx
# only when their own *_CONTEXT is set; clients must then send the same value
# or Ollama reloads the model.
#
# Exits 1 if any model failed to load.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/warmup-lib.sh"

echo "=== FrankenLLM: Warming up GPUs ==="
echo "GPU Count: $FRANKEN_GPU_COUNT"
echo ""

# Model to use on each GPU
# Priority: 1) Command line args, 2) Config file, 3) Default
GPU0_MODEL="${1:-${FRANKEN_GPU0_MODEL:-gemma4:12b}}"
GPU1_MODEL="${2:-${FRANKEN_GPU1_MODEL:-qwen3.5:4b}}"
GPU0_GUARD_MODEL="${FRANKEN_GPU0_GUARD_MODEL:-}"
GPU0_EXTRA_MODEL="${FRANKEN_GPU0_EXTRA_MODEL:-}"
GPU1_GUARD_MODEL="${FRANKEN_GPU1_GUARD_MODEL:-}"

# First load after an Ollama upgrade (or at a large context) can take over a
# minute (runner init), so the timeouts must be generous
GPU0_TIMEOUT="${FRANKEN_GPU0_WARMUP_TIMEOUT:-180}"
GPU1_TIMEOUT="${FRANKEN_GPU1_WARMUP_TIMEOUT:-120}"

if [ "$FRANKEN_GPU_COUNT" -lt 2 ] && [ -n "$GPU1_GUARD_MODEL" ]; then
    echo "WARNING: FRANKEN_GPU1_GUARD_MODEL is set ($GPU1_GUARD_MODEL) but FRANKEN_GPU_COUNT=$FRANKEN_GPU_COUNT; ignoring it." >&2
fi

LOADED=()
FAILED=()

# warm_one <gpu> <label> <model> <ctx_or_empty> <timeout>
warm_one() {
    local gpu="$1" label="$2" model="$3" ctx="$4" timeout="$5"
    local name_var="FRANKEN_GPU${gpu}_NAME" port_var="FRANKEN_GPU${gpu}_PORT"
    local ctx_note="" response
    [ -n "$ctx" ] && ctx_note=" (num_ctx $ctx)"
    echo "GPU $gpu (${!name_var}) - Loading ${label}${model}${ctx_note}..."
    if response=$(franken_warmup_load "$FRANKEN_SERVER_IP" "${!port_var}" "$model" "$ctx" "$timeout"); then
        echo "  ✅ $model loaded and ready on GPU $gpu"
        LOADED+=("GPU $gpu: ${label}${model}${ctx_note}")
    else
        echo "  ❌ Failed to load $model on GPU $gpu"
        echo "  Error: $response"
        FAILED+=("GPU $gpu: ${label}${model}")
    fi
    echo ""
}

echo "Loading models into GPU memory..."
echo ""

warm_one 0 "" "$GPU0_MODEL" "" "$GPU0_TIMEOUT"

# Guard/moderation model on GPU 0, resident alongside the main model
# (optional; set FRANKEN_GPU0_GUARD_MODEL= empty to turn it off)
if [ -n "$GPU0_GUARD_MODEL" ]; then
    warm_one 0 "guard model " "$GPU0_GUARD_MODEL" "${FRANKEN_GPU0_GUARD_CONTEXT:-}" "$GPU0_TIMEOUT"
fi

# Optional second resident model on GPU 0 (e.g. a small cheap-task model)
if [ -n "$GPU0_EXTRA_MODEL" ]; then
    warm_one 0 "extra model " "$GPU0_EXTRA_MODEL" "${FRANKEN_GPU0_EXTRA_CONTEXT:-}" "$GPU0_TIMEOUT"
fi

# Warm up GPU 1 if configured
if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
    warm_one 1 "" "$GPU1_MODEL" "" "$GPU1_TIMEOUT"

    if [ -n "$GPU1_GUARD_MODEL" ]; then
        warm_one 1 "guard model " "$GPU1_GUARD_MODEL" "${FRANKEN_GPU1_GUARD_CONTEXT:-}" "$GPU1_TIMEOUT"
    fi
fi

echo "=== GPU Warm-up Complete ==="
echo ""
if [ "${#LOADED[@]}" -gt 0 ]; then
    echo "Loaded (servers: GPU 0 http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT, GPU 1 http://$FRANKEN_SERVER_IP:$FRANKEN_GPU1_PORT):"
    for item in "${LOADED[@]}"; do echo "  ✅ $item"; done
fi
if [ "${#FAILED[@]}" -gt 0 ]; then
    echo ""
    echo "FAILED (${#FAILED[@]}):"
    for item in "${FAILED[@]}"; do echo "  ❌ $item"; done
    exit 1
fi
echo ""
echo "Clients must send the same options.num_ctx as any guard/extra model above, or Ollama reloads it."
