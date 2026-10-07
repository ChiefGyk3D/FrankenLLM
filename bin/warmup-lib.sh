#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - shared warm-up helpers (sourced, not executed)

# Validate values before they are put into a JSON body by hand.
franken_valid_model() { [[ "$1" =~ ^[A-Za-z0-9._:/@-]+$ ]]; }
franken_valid_ctx()   { [[ "$1" =~ ^[0-9]+$ ]]; }

# Build the /api/generate body that loads a model resident.
#   franken_warmup_json <model> [num_ctx] [prompt]
# keep_alive -1 keeps the model loaded. options.num_ctx is included ONLY when a
# context is given: without it the model loads at the instance's
# OLLAMA_CONTEXT_LENGTH, exactly as a plain client request would.
franken_warmup_json() {
    local model="$1" ctx="${2:-}" prompt="${3:-Hi}" opts=""
    [ -n "$ctx" ] && opts=", \"options\": {\"num_ctx\": $ctx}"
    printf '{"model": "%s", "prompt": "%s", "stream": false, "keep_alive": -1%s}' \
        "$model" "$prompt" "$opts"
}

# Does an Ollama reply look like a successful generate?
#   franken_reply_ok <reply>
franken_reply_ok() {
    if command -v jq > /dev/null 2>&1; then
        printf '%s' "$1" | jq -e '.response' > /dev/null 2>&1
    else
        printf '%s' "$1" | grep -q '"response"'
    fi
}

# POST a warm-up request.
#   franken_warmup_load <host> <port> <model> <num_ctx_or_empty> <timeout_s>
# Prints the reply (or the reason it never got sent) on stdout. Returns 0 only
# for a valid request that got a successful reply.
franken_warmup_load() {
    local host="$1" port="$2" model="$3" ctx="$4" timeout="$5" resp
    if ! franken_valid_model "$model"; then
        printf 'invalid model name "%s" (allowed: letters, digits, . _ : / @ -)' "$model"
        return 1
    fi
    if [ -n "$ctx" ] && ! franken_valid_ctx "$ctx"; then
        printf 'invalid context "%s" for %s (must be a whole number)' "$ctx" "$model"
        return 1
    fi
    resp=$(curl -sS -m "$timeout" "http://$host:$port/api/generate" \
        -d "$(franken_warmup_json "$model" "$ctx")" 2>&1)
    printf '%s' "$resp"
    franken_reply_ok "$resp"
}

# The num_ctx warm-up should send for a model on a GPU, or empty for none.
# Main models never get one (they inherit the instance's OLLAMA_CONTEXT_LENGTH,
# as before). Only a guard/extra model with its own *_CONTEXT set gets one.
#   franken_ctx_for_model <gpu_index> <model>
franken_ctx_for_model() {
    local gpu="$1" model="$2"
    local guard_var="FRANKEN_GPU${gpu}_GUARD_MODEL" guard_ctx_var="FRANKEN_GPU${gpu}_GUARD_CONTEXT"
    local extra_var="FRANKEN_GPU${gpu}_EXTRA_MODEL" extra_ctx_var="FRANKEN_GPU${gpu}_EXTRA_CONTEXT"
    if [ -n "$model" ] && [ "$model" = "${!guard_var:-}" ]; then
        echo "${!guard_ctx_var:-}"
    elif [ -n "$model" ] && [ "$model" = "${!extra_var:-}" ]; then
        echo "${!extra_ctx_var:-}"
    else
        echo ""
    fi
}
