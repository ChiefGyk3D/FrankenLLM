#!/bin/bash
# FrankenLLM - Install Docker and NVIDIA Container Toolkit
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

echo "=== FrankenLLM: Installing Docker and NVIDIA Container Toolkit on $FRANKEN_SERVER_IP ==="
echo ""

# Prepare the installation script
DOCKER_INSTALL_SCRIPT=$(cat << 'ENDSSH'
# Update package index
sudo apt-get update

# Install prerequisites
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Add Docker's official GPG key
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Set up the repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add user to docker group
sudo usermod -aG docker $USER

# Install NVIDIA Container Toolkit
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | sudo tee /etc/apt/sources.list.d/nvidia-docker.list

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

# Configure Docker to use NVIDIA runtime
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

echo ""
echo "Docker and NVIDIA Container Toolkit installed!"
echo "Please log out and log back in for group changes to take effect."
ENDSSH
)

# Execute the installation script
if [ "$FRANKEN_IS_LOCAL" = true ]; then
    echo "Installing Docker locally..."
    eval "$DOCKER_INSTALL_SCRIPT"
else
    echo "Installing Docker on remote server $FRANKEN_SERVER_IP..."
    ssh "$FRANKEN_SERVER_IP" 'bash -s' << EOF
$DOCKER_INSTALL_SCRIPT
EOF
fi

echo ""
echo "=== Installation Complete ==="
if [ "$FRANKEN_IS_LOCAL" = false ]; then
    echo "You may need to log out and back in to the remote server."
else
    echo "You may need to log out and back in to apply group changes."
fi
