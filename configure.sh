#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Configuration Setup Wizard
# Stitched-together GPUs, but it lives!

echo "╔════════════════════════════════════════╗"
echo "║     FrankenLLM Configuration Setup     ║"
echo "║  Stitched-together GPUs, but it lives! ║"
echo "╚════════════════════════════════════════╝"
echo ""

# Check if .env exists
if [ -f .env ]; then
    echo "Found existing configuration in .env"
    echo "Current settings:"
    cat .env
    echo ""
    read -p "Do you want to reconfigure? (y/N): " reconfigure
    if [[ ! $reconfigure =~ ^[Yy]$ ]]; then
        echo "Using existing configuration."
        exit 0
    fi
fi

# Installation location
echo "1. Installation Location"
echo "   Where is the FrankenLLM server located?"
echo "   a) Local machine (this computer)"
echo "   b) Remote server (SSH required)"
echo ""
read -p "Select option (a/b): " location

if [[ $location == "a" || $location == "A" ]]; then
    SERVER_IP="localhost"
    echo "Selected: Local installation"
else
    read -p "Enter remote server IP address [192.168.201.145]: " SERVER_IP
    SERVER_IP=${SERVER_IP:-192.168.201.145}
    echo "Selected: Remote installation on $SERVER_IP"
fi

# Installation directory
echo ""
echo "2. Installation Directory"
read -p "Enter installation directory [/opt/frankenllm]: " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-/opt/frankenllm}

# Port configuration
echo ""
echo "3. Port Configuration"
read -p "Enter port for GPU 0 [11434]: " GPU0_PORT
GPU0_PORT=${GPU0_PORT:-11434}

read -p "Enter port for GPU 1 [11435]: " GPU1_PORT
GPU1_PORT=${GPU1_PORT:-11435}

# GPU names
echo ""
echo "4. GPU Names (for display purposes)"
read -p "Enter name for GPU 0 [RTX 5060 Ti]: " GPU0_NAME
GPU0_NAME=${GPU0_NAME:-RTX 5060 Ti}

read -p "Enter name for GPU 1 [RTX 3050]: " GPU1_NAME
GPU1_NAME=${GPU1_NAME:-RTX 3050}

# Write configuration
cat > .env << EOF
# FrankenLLM Configuration
# Generated on $(date)

# Server Configuration
FRANKEN_SERVER_IP=$SERVER_IP
FRANKEN_INSTALL_DIR=$INSTALL_DIR

# Port Configuration
FRANKEN_GPU0_PORT=$GPU0_PORT
FRANKEN_GPU1_PORT=$GPU1_PORT

# GPU Names
FRANKEN_GPU0_NAME=$GPU0_NAME
FRANKEN_GPU1_NAME=$GPU1_NAME
EOF

echo ""
echo "✓ Configuration saved to .env"
echo ""
echo "Summary:"
echo "--------"
echo "Server:        $SERVER_IP"
echo "Install Dir:   $INSTALL_DIR"
echo "GPU 0:         $GPU0_NAME (port $GPU0_PORT)"
echo "GPU 1:         $GPU1_NAME (port $GPU1_PORT)"
echo ""
echo "To apply this configuration, all scripts will automatically load .env"
echo "You can also manually export these variables or edit .env directly."
echo ""

if [[ $SERVER_IP != "localhost" && $SERVER_IP != "127.0.0.1" ]]; then
    echo "Next steps for remote installation:"
    echo "  1. Test SSH connection: ssh $SERVER_IP"
    echo "  2. Check GPUs: ./check-gpus.sh"
    echo "  3. Install Ollama: ./install-ollama-native.sh"
else
    echo "Next steps for local installation:"
    echo "  1. Check GPUs: ./check-gpus.sh"
    echo "  2. Install Ollama: ./install-ollama-native.sh"
fi
