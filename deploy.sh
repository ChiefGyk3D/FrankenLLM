#!/bin/bash
# FrankenLLM - Deploy LLM servers to remote machine
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== FrankenLLM: Multi-GPU Server Deployment ==="
echo "Target: $FRANKEN_SERVER_IP"
echo "Install Dir: $FRANKEN_INSTALL_DIR"
echo ""

if [ "$FRANKEN_IS_LOCAL" = false ]; then
    # Create remote directory
    echo "1. Creating remote directory..."
    franken_exec "sudo mkdir -p $FRANKEN_INSTALL_DIR && sudo chown \$USER:\$USER $FRANKEN_INSTALL_DIR"

    # Copy configuration files
    echo "2. Copying configuration files..."
    scp docker-compose.yml vllm-compose.yml ollama-compose.yml "$FRANKEN_SERVER_IP:$FRANKEN_INSTALL_DIR/"
    scp *.sh "$FRANKEN_SERVER_IP:$FRANKEN_INSTALL_DIR/"

    # Create models directory
    echo "3. Creating models directory..."
    franken_exec "mkdir -p $FRANKEN_INSTALL_DIR/models"
else
    # Local installation
    echo "1. Creating local directory..."
    sudo mkdir -p "$FRANKEN_INSTALL_DIR"
    sudo chown $USER:$USER "$FRANKEN_INSTALL_DIR"
    
    echo "2. Copying configuration files..."
    cp docker-compose.yml vllm-compose.yml ollama-compose.yml "$FRANKEN_INSTALL_DIR/"
    cp *.sh "$FRANKEN_INSTALL_DIR/"
    
    echo "3. Creating models directory..."
    mkdir -p "$FRANKEN_INSTALL_DIR/models"
fi

# Check GPU status
echo "4. Checking GPU configuration..."
franken_exec "nvidia-smi --query-gpu=index,name,memory.total --format=csv"

echo ""
echo "=== FrankenLLM Deployment Complete ==="
echo "Next steps:"
if [ "$FRANKEN_IS_LOCAL" = false ]; then
    echo "1. Upload your model files to $FRANKEN_SERVER_IP:$FRANKEN_INSTALL_DIR/models/"
    echo "2. SSH to the server: ssh $FRANKEN_SERVER_IP"
    echo "3. Navigate to: cd $FRANKEN_INSTALL_DIR"
else
    echo "1. Upload your model files to $FRANKEN_INSTALL_DIR/models/"
    echo "2. Navigate to: cd $FRANKEN_INSTALL_DIR"
fi
echo "4. Start services: docker-compose up -d"
echo ""
echo "Services will be available at:"
echo "  - $FRANKEN_GPU0_NAME: http://$FRANKEN_SERVER_IP:8080"
echo "  - $FRANKEN_GPU1_NAME: http://$FRANKEN_SERVER_IP:8081"
