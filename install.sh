#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Main Installation Launcher
# Auto-detects local or remote installation and runs the appropriate installer

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

if [ "$FRANKEN_IS_LOCAL" = true ]; then
    echo "Detected LOCAL installation (server: $FRANKEN_SERVER_IP)"
    echo ""
    exec "$SCRIPT_DIR/local/install.sh"
else
    echo "Detected REMOTE installation (server: $FRANKEN_SERVER_IP)"
    echo ""
    exec "$SCRIPT_DIR/remote/install.sh"
fi
