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

# GPU count
echo ""
echo "3. GPU Configuration"
read -p "How many GPUs do you want to use? [2]: " GPU_COUNT
GPU_COUNT=${GPU_COUNT:-2}

if [ "$GPU_COUNT" -lt 1 ]; then
    echo "⚠️  Warning: GPU count must be at least 1. Setting to 1."
    GPU_COUNT=1
fi

# Port configuration
echo ""
echo "4. Port Configuration"
declare -A GPU_PORTS
declare -A GPU_NAMES
declare -A GPU_MODELS

for i in $(seq 0 $(($GPU_COUNT - 1))); do
    default_port=$((11434 + i))
    
    if [ $i -eq 0 ]; then
        default_name="RTX 5060 Ti"
        default_model="gemma3:12b"
    elif [ $i -eq 1 ]; then
        default_name="RTX 3050"
        default_model="gemma3:4b"
    else
        default_name="GPU $i"
        default_model="gemma3:4b"
    fi
    
    read -p "Enter port for GPU $i [$default_port]: " port
    GPU_PORTS[$i]=${port:-$default_port}
done

# GPU names
echo ""
echo "5. GPU Names (for display purposes)"
for i in $(seq 0 $(($GPU_COUNT - 1))); do
    if [ $i -eq 0 ]; then
        default_name="RTX 5060 Ti"
    elif [ $i -eq 1 ]; then
        default_name="RTX 3050"
    else
        default_name="GPU $i"
    fi
    
    read -p "Enter name for GPU $i [$default_name]: " name
    GPU_NAMES[$i]=${name:-$default_name}
done

# Model configuration
echo ""
echo "6. Model Configuration"
echo "   Specify which models to use on each GPU"
echo "   Leave blank to use defaults"
echo ""
for i in $(seq 0 $(($GPU_COUNT - 1))); do
    if [ $i -eq 0 ]; then
        default_model="gemma3:12b"
    else
        default_model="gemma3:4b"
    fi
    
    read -p "Model for GPU $i [$default_model]: " model
    GPU_MODELS[$i]=${model:-$default_model}
done

# Write configuration
cat > .env << EOF
# FrankenLLM Configuration
# Generated on $(date)

# Server Configuration
FRANKEN_SERVER_IP=$SERVER_IP
FRANKEN_INSTALL_DIR=$INSTALL_DIR

# GPU Configuration
FRANKEN_GPU_COUNT=$GPU_COUNT

# Port Configuration
EOF

for i in $(seq 0 $(($GPU_COUNT - 1))); do
    echo "FRANKEN_GPU${i}_PORT=${GPU_PORTS[$i]}" >> .env
done

cat >> .env << EOF

# GPU Names
EOF

for i in $(seq 0 $(($GPU_COUNT - 1))); do
    echo "FRANKEN_GPU${i}_NAME=\"${GPU_NAMES[$i]}\"" >> .env
done

cat >> .env << EOF

# Model Configuration
EOF

for i in $(seq 0 $(($GPU_COUNT - 1))); do
    echo "FRANKEN_GPU${i}_MODEL=${GPU_MODELS[$i]}" >> .env
done

echo ""
echo "✓ Configuration saved to .env"
echo ""
echo "Summary:"
echo "--------"
echo "Server:        $SERVER_IP"
echo "Install Dir:   $INSTALL_DIR"
echo "GPU Count:     $GPU_COUNT"
for i in $(seq 0 $(($GPU_COUNT - 1))); do
    echo "GPU $i:         ${GPU_NAMES[$i]} (port ${GPU_PORTS[$i]}, model: ${GPU_MODELS[$i]})"
done
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
