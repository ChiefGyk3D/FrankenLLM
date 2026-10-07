#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Warm up GPUs with their designated models
# This loads models into GPU memory so they're ready to use.
#
# Every model is loaded with options.num_ctx (its own *_CONTEXT, else the
# instance context) and keep_alive -1. Clients must send the same num_ctx,
# otherwise Ollama reloads the model at the client's context.

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

# Context per model: the model's own setting, else its instance's
GPU0_CTX="${FRANKEN_GPU0_CONTEXT:-8192}"
GPU1_CTX="${FRANKEN_GPU1_CONTEXT:-32768}"
GPU0_GUARD_CTX=$(franken_pick_ctx "${FRANKEN_GPU0_GUARD_CONTEXT:-}" "$GPU0_CTX")
GPU0_EXTRA_CTX=$(franken_pick_ctx "${FRANKEN_GPU0_EXTRA_CONTEXT:-}" "$GPU0_CTX")
GPU1_GUARD_CTX=$(franken_pick_ctx "${FRANKEN_GPU1_GUARD_CONTEXT:-}" "$GPU1_CTX")

# First load after an Ollama upgrade (or at a large context) can take over a
# minute (runner init), so the timeouts must be generous
GPU0_TIMEOUT="${FRANKEN_GPU0_WARMUP_TIMEOUT:-180}"
GPU1_TIMEOUT="${FRANKEN_GPU1_WARMUP_TIMEOUT:-120}"

# warm_one <gpu> <label> <model> <ctx> <timeout>
warm_one() {
    local gpu="$1" label="$2" model="$3" ctx="$4" timeout="$5"
    local name_var="FRANKEN_GPU${gpu}_NAME" port_var="FRANKEN_GPU${gpu}_PORT"
    local response
    echo "GPU $gpu (${!name_var}) - Loading ${label}$model (num_ctx $ctx)..."
    if response=$(franken_warmup_load "$FRANKEN_SERVER_IP" "${!port_var}" "$model" "$ctx" "$timeout"); then
        echo "  ✅ $model loaded and ready on GPU $gpu"
    else
        echo "  ❌ Failed to load $model on GPU $gpu"
        echo "  Error: $response"
    fi
    echo ""
}

echo "Loading models into GPU memory..."
echo ""

warm_one 0 "" "$GPU0_MODEL" "$GPU0_CTX" "$GPU0_TIMEOUT"

# Guard/moderation model on GPU 0, resident alongside the main model
# (e.g. llama-guard3:8b for AI moderation)
if [ -n "$GPU0_GUARD_MODEL" ]; then
    warm_one 0 "guard model " "$GPU0_GUARD_MODEL" "$GPU0_GUARD_CTX" "$GPU0_TIMEOUT"
fi

# Optional second resident model on GPU 0 (e.g. a small cheap-task model)
if [ -n "$GPU0_EXTRA_MODEL" ]; then
    warm_one 0 "extra model " "$GPU0_EXTRA_MODEL" "$GPU0_EXTRA_CTX" "$GPU0_TIMEOUT"
fi

# Warm up GPU 1 if configured
if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
    warm_one 1 "" "$GPU1_MODEL" "$GPU1_CTX" "$GPU1_TIMEOUT"

    if [ -n "$GPU1_GUARD_MODEL" ]; then
        warm_one 1 "guard model " "$GPU1_GUARD_MODEL" "$GPU1_GUARD_CTX" "$GPU1_TIMEOUT"
    fi
fi

echo "=== GPU Warm-up Complete ==="
echo ""
echo "Models ready to use:"
echo "  GPU 0: $GPU0_MODEL at http://$FRANKEN_SERVER_IP:$FRANKEN_GPU0_PORT (num_ctx $GPU0_CTX)"
[ -n "$GPU0_GUARD_MODEL" ] && echo "  GPU 0: $GPU0_GUARD_MODEL (guard, num_ctx $GPU0_GUARD_CTX)"
[ -n "$GPU0_EXTRA_MODEL" ] && echo "  GPU 0: $GPU0_EXTRA_MODEL (extra, num_ctx $GPU0_EXTRA_CTX)"
if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
    echo "  GPU 1: $GPU1_MODEL at http://$FRANKEN_SERVER_IP:$FRANKEN_GPU1_PORT (num_ctx $GPU1_CTX)"
    [ -n "$GPU1_GUARD_MODEL" ] && echo "  GPU 1: $GPU1_GUARD_MODEL (guard, num_ctx $GPU1_GUARD_CTX)"
fi
echo ""
echo "Clients must send the same options.num_ctx or Ollama reloads the model."
