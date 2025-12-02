#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Auto-warmup on Boot
# This script runs at boot to load models into GPU memory

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

# Log to systemd journal
log() {
    echo "[FrankenLLM Warmup] $1"
}

log "Starting automatic model warmup..."

# Wait for Ollama services to be ready
TIMEOUT=120
ELAPSED=0

log "Waiting for Ollama services to be ready..."
while [ $ELAPSED -lt $TIMEOUT ]; do
    # Check GPU 0
    if curl -s -f "http://localhost:$FRANKEN_GPU0_PORT/api/tags" > /dev/null 2>&1; then
        log "GPU 0 service is ready"
        
        # Check GPU 1 if configured
        if [ "$FRANKEN_GPU_COUNT" -ge 2 ]; then
            if curl -s -f "http://localhost:$FRANKEN_GPU1_PORT/api/tags" > /dev/null 2>&1; then
                log "GPU 1 service is ready"
                break
            fi
        else
            break
        fi
    fi
    
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    log "ERROR: Timeout waiting for Ollama services to be ready"
    exit 1
fi

log "All Ollama services ready. Starting warmup..."

# Run the warmup script
"$SCRIPT_DIR/warmup-models.sh"

log "Warmup complete!"
