#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Wikipedia Pipeline Status Checker
# Quick check on pipeline progress — run from anywhere

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PIPELINE_SCRIPT="$SCRIPT_DIR/wiki-pipeline.py"

# Default work dir (same as pipeline default)
WORK_DIR="${1:-$PROJECT_ROOT/wiki-pipeline-data}"

if [ ! -f "$PIPELINE_SCRIPT" ]; then
    echo "Error: wiki-pipeline.py not found at $PIPELINE_SCRIPT"
    exit 1
fi

python3 "$PIPELINE_SCRIPT" --step status --work-dir "$WORK_DIR"
