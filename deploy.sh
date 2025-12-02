#!/bin/bash
# FrankenLLM - Deploy LLM servers to remote machine
# Stitched-together GPUs, but it lives!

SERVER_IP="192.168.201.145"
REMOTE_DIR="/opt/frankenllm"

echo "=== FrankenLLM: Multi-GPU Server Deployment ==="
echo "Target: $SERVER_IP"
echo ""

# Create remote directory
echo "1. Creating remote directory..."
ssh $SERVER_IP "sudo mkdir -p $REMOTE_DIR && sudo chown \$USER:\$USER $REMOTE_DIR"

# Copy configuration files
echo "2. Copying configuration files..."
scp docker-compose.yml $SERVER_IP:$REMOTE_DIR/
scp *.sh $SERVER_IP:$REMOTE_DIR/

# Create models directory
echo "3. Creating models directory..."
ssh $SERVER_IP "mkdir -p $REMOTE_DIR/models"

# Check GPU status
echo "4. Checking GPU configuration..."
ssh $SERVER_IP "nvidia-smi --query-gpu=index,name,memory.total --format=csv"

echo ""
echo "=== FrankenLLM Deployment Complete ==="
echo "Next steps:"
echo "1. Upload your model files to $SERVER_IP:$REMOTE_DIR/models/"
echo "2. SSH to the server: ssh $SERVER_IP"
echo "3. Navigate to: cd $REMOTE_DIR"
echo "4. Start services: docker-compose up -d"
echo ""
echo "Services will be available at:"
echo "  - RTX 5060 Ti: http://$SERVER_IP:8080"
echo "  - RTX 3050:    http://$SERVER_IP:8081"
