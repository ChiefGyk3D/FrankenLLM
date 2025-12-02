#!/bin/bash
# Setup script for multi-GPU LLM servers

SERVER_IP="192.168.201.145"

echo "Connecting to $SERVER_IP to check GPU configuration..."
ssh $SERVER_IP "nvidia-smi --list-gpus"
