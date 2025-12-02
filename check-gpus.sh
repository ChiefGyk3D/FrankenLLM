#!/bin/bash
# FrankenLLM - Check GPU configuration on remote server
# Stitched-together GPUs, but it lives!

SERVER_IP="192.168.201.145"

echo "=== FrankenLLM: Checking GPU Configuration on $SERVER_IP ==="
echo ""

echo "1. GPU List:"
ssh $SERVER_IP "nvidia-smi --list-gpus"
echo ""

echo "2. Detailed GPU Info:"
ssh $SERVER_IP "nvidia-smi --query-gpu=index,name,memory.total,memory.free,driver_version,cuda_version --format=csv,noheader"
echo ""

echo "3. Full nvidia-smi output:"
ssh $SERVER_IP "nvidia-smi"
echo ""

echo "4. Docker availability:"
ssh $SERVER_IP "docker --version && docker-compose --version"
