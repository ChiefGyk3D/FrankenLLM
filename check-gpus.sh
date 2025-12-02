#!/bin/bash
# FrankenLLM - Check GPU configuration on remote server
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== FrankenLLM: Checking GPU Configuration on $FRANKEN_SERVER_IP ==="
echo ""

echo "1. GPU List:"
franken_exec "nvidia-smi --list-gpus"
echo ""

echo "2. Detailed GPU Info:"
franken_exec "nvidia-smi --query-gpu=index,name,memory.total,memory.free,driver_version --format=csv,noheader"
echo ""

echo "3. Full nvidia-smi output:"
franken_exec "nvidia-smi"
echo ""

echo "4. Docker availability:"
franken_exec "docker --version 2>/dev/null && docker-compose --version 2>/dev/null || echo 'Docker not installed'"
