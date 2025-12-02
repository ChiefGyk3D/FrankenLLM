#!/bin/bash
# FrankenLLM - Install Docker and NVIDIA Container Toolkit on remote server
# Stitched-together GPUs, but it lives!

SERVER_IP="192.168.201.145"

echo "=== FrankenLLM: Installing Docker and NVIDIA Container Toolkit on $SERVER_IP ==="
echo ""

# Install Docker
echo "Installing Docker..."
ssh $SERVER_IP 'bash -s' << 'ENDSSH'
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

echo ""
echo "=== Installation Complete ==="
echo "You may need to log out and back in to the remote server."
