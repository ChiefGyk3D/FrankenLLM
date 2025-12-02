#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Main Service Management Launcher
# Auto-detects local or remote and runs the appropriate manager

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

if [ "$FRANKEN_IS_LOCAL" = true ]; then
    exec "$SCRIPT_DIR/local/manage.sh" "$@"
else
    exec "$SCRIPT_DIR/remote/manage.sh" "$@"
fi
