#!/bin/bash
# FrankenLLM - Remote Installation Helper
# Run this script to SSH into the remote server and install there
# Stitched-together GPUs, but it lives!

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

if [ "$FRANKEN_IS_LOCAL" = true ]; then
    echo "Configuration is set for LOCAL installation."
    echo "Running installation locally..."
    ./install-ollama-native.sh
    exit 0
fi

echo "=== FrankenLLM: Remote Installation ==="
echo ""
echo "This will connect you to $FRANKEN_SERVER_IP to run the installation."
echo "You'll need sudo access on the remote server."
echo ""
echo "Press Ctrl+C to cancel, or Enter to continue..."
read

# Create the installation script
cat > /tmp/franken-install.sh << 'ENDSCRIPT'
#!/bin/bash
set -e

echo "=== Installing Ollama ==="
curl -fsSL https://ollama.com/install.sh | sh

echo ""
echo "=== Creating systemd services ==="

# Create systemd service for GPU 0
sudo tee /etc/systemd/system/ollama-gpu0.service > /dev/null << 'EOF'
[Unit]
Description=Ollama Service for GPU 0 (RTX 5060 Ti)
After=network-online.target

[Service]
Type=simple
User=$USER
Environment="CUDA_VISIBLE_DEVICES=0"
Environment="OLLAMA_HOST=0.0.0.0:11434"
ExecStart=/usr/local/bin/ollama serve
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

# Create systemd service for GPU 1
sudo tee /etc/systemd/system/ollama-gpu1.service > /dev/null << 'EOF'
[Unit]
Description=Ollama Service for GPU 1 (RTX 3050)
After=network-online.target

[Service]
Type=simple
User=$USER
Environment="CUDA_VISIBLE_DEVICES=1"
Environment="OLLAMA_HOST=0.0.0.0:11435"
ExecStart=/usr/local/bin/ollama serve
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

# Reload systemd
sudo systemctl daemon-reload

# Start services
sudo systemctl start ollama-gpu0
sudo systemctl start ollama-gpu1

# Enable on boot
sudo systemctl enable ollama-gpu0
sudo systemctl enable ollama-gpu1

echo ""
echo "=== Installation Complete! ==="
echo ""
echo "Services Status:"
sudo systemctl status ollama-gpu0 --no-pager -l
echo ""
sudo systemctl status ollama-gpu1 --no-pager -l

echo ""
echo "Services available at:"
echo "  - GPU 0 (RTX 5060 Ti): http://localhost:11434"
echo "  - GPU 1 (RTX 3050): http://localhost:11435"
echo ""
echo "You can now exit and use the FrankenLLM scripts from your local machine."
ENDSCRIPT

# Copy script to remote server
echo "Copying installation script to remote server..."
scp /tmp/franken-install.sh "$FRANKEN_SERVER_IP:/tmp/"

# SSH into remote and run installation
echo ""
echo "Connecting to $FRANKEN_SERVER_IP..."
echo ""
ssh -t "$FRANKEN_SERVER_IP" "bash /tmp/franken-install.sh"

# Cleanup
rm /tmp/franken-install.sh

echo ""
echo "=== Done! ==="
echo ""
echo "Services should now be running on $FRANKEN_SERVER_IP"
echo "Test with: ./manage-services.sh status"
