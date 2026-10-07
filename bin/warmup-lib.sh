#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - shared warm-up helpers (sourced, not executed)

# Build the /api/generate body that loads a model resident at a given context.
#   franken_warmup_json <model> <num_ctx> [prompt]
# keep_alive -1 keeps the model loaded; options.num_ctx pins the context so a
# client that sends the same num_ctx reuses this load instead of reloading.
franken_warmup_json() {
    local model="$1" ctx="$2" prompt="${3:-Hi}"
    printf '{"model": "%s", "prompt": "%s", "stream": false, "keep_alive": -1, "options": {"num_ctx": %s}}' \
        "$model" "$prompt" "$ctx"
}

# Pick the context for a model: its own setting if non-empty, else the instance's.
#   franken_pick_ctx <model_ctx_or_empty> <instance_ctx>
franken_pick_ctx() {
    if [ -n "$1" ]; then echo "$1"; else echo "$2"; fi
}

# POST a warm-up request and report success.
#   franken_warmup_load <host> <port> <model> <num_ctx> <timeout_s>
# Prints the raw response on stdout; returns 0 when it contains "response".
franken_warmup_load() {
    local host="$1" port="$2" model="$3" ctx="$4" timeout="$5" resp
    resp=$(curl -s -m "$timeout" "http://$host:$port/api/generate" \
        -d "$(franken_warmup_json "$model" "$ctx")" 2>&1)
    printf '%s' "$resp"
    echo "$resp" | grep -q "response"
}

# Context for a model on a given GPU, honouring the guard/extra overrides and
# falling back to that GPU's instance context (then to 8192).
#   franken_ctx_for_model <gpu_index> <model>
franken_ctx_for_model() {
    local gpu="$1" model="$2" v
    local inst_var="FRANKEN_GPU${gpu}_CONTEXT"
    local inst="${!inst_var:-8192}"
    local guard_var="FRANKEN_GPU${gpu}_GUARD_MODEL" guard_ctx_var="FRANKEN_GPU${gpu}_GUARD_CONTEXT"
    local extra_var="FRANKEN_GPU${gpu}_EXTRA_MODEL" extra_ctx_var="FRANKEN_GPU${gpu}_EXTRA_CONTEXT"
    if [ -n "$model" ] && [ "$model" = "${!guard_var:-}" ]; then
        v="${!guard_ctx_var:-}"
    elif [ -n "$model" ] && [ "$model" = "${!extra_var:-}" ]; then
        v="${!extra_ctx_var:-}"
    else
        v=""
    fi
    franken_pick_ctx "$v" "$inst"
}
