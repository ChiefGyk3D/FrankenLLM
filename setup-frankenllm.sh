#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Complete Setup Wizard
# One script to rule them all - from fresh server to fully operational LLM system
# Stitched-together GPUs, but it lives!

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}"
cat << "EOF"
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║              🧟 FrankenLLM - Complete Setup 🧟               ║
║                                                              ║
║            Stitched-together GPUs, but it lives!             ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"
echo ""

# Function to prompt for yes/no
prompt_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    
    if [ "$default" = "y" ]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi
    
    read -p "$prompt" response
    response=${response:-$default}
    
    if [[ "$response" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}❌ Please do not run this script as root${NC}"
    echo "   The script will ask for sudo password when needed"
    exit 1
fi

echo -e "${YELLOW}════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}                   Installation Mode                    ${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════════${NC}"
echo ""
echo "Where do you want to install FrankenLLM?"
echo ""
echo "  1) Local  - Install on THIS machine"
echo "  2) Remote - Install on a remote server via SSH"
echo ""
read -p "Select installation mode [1-2]: " INSTALL_MODE

case $INSTALL_MODE in
    1)
        INSTALL_TYPE="local"
        SERVER_IP="localhost"
        echo -e "${GREEN}✓${NC} Selected: Local installation"
        ;;
    2)
        INSTALL_TYPE="remote"
        read -p "Enter remote server IP address: " SERVER_IP
        echo -e "${GREEN}✓${NC} Selected: Remote installation to $SERVER_IP"
        
        # Test SSH connection
        echo ""
        echo "Testing SSH connection..."
        if ssh -o ConnectTimeout=5 -o BatchMode=yes "$SERVER_IP" exit 2>/dev/null; then
            echo -e "${GREEN}✓${NC} SSH connection successful (key-based auth)"
        else
            echo -e "${YELLOW}⚠${NC} Testing password-based SSH..."
            if ! ssh -o ConnectTimeout=5 "$SERVER_IP" exit; then
                echo -e "${RED}❌ Cannot connect to $SERVER_IP${NC}"
                echo "Please ensure:"
                echo "  - Server is online and SSH is running"
                echo "  - You have SSH access (key or password)"
                exit 1
            fi
            echo -e "${GREEN}✓${NC} SSH connection successful (password-based)"
        fi
        ;;
    *)
        echo -e "${RED}Invalid selection${NC}"
        exit 1
        ;;
esac

echo ""
echo -e "${YELLOW}════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}                  GPU Configuration                     ${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════════${NC}"
echo ""

# Detect GPUs
if [ "$INSTALL_TYPE" = "local" ]; then
    GPU_INFO=$(nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader 2>/dev/null || echo "")
else
    GPU_INFO=$(ssh "$SERVER_IP" "nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader" 2>/dev/null || echo "")
fi

if [ -z "$GPU_INFO" ]; then
    echo -e "${RED}❌ No NVIDIA GPUs detected or nvidia-smi not available${NC}"
    echo "Please install NVIDIA drivers first."
    exit 1
fi

echo "Detected GPUs:"
echo "$GPU_INFO" | nl
echo ""

GPU_COUNT=$(echo "$GPU_INFO" | wc -l)
echo -e "${GREEN}Found $GPU_COUNT GPU(s)${NC}"

if [ "$GPU_COUNT" -lt 2 ]; then
    echo -e "${YELLOW}⚠  FrankenLLM is designed for 2+ GPUs${NC}"
    if ! prompt_yes_no "Continue with single GPU setup?"; then
        exit 0
    fi
fi

# GPU ports configuration
GPU0_PORT=11434
GPU1_PORT=11435
read -p "GPU 0 port [$GPU0_PORT]: " port_input
GPU0_PORT=${port_input:-$GPU0_PORT}

if [ "$GPU_COUNT" -ge 2 ]; then
    read -p "GPU 1 port [$GPU1_PORT]: " port_input
    GPU1_PORT=${port_input:-$GPU1_PORT}
fi

echo ""
echo -e "${YELLOW}════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}              Component Selection                       ${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════════${NC}"
echo ""

# What to install
INSTALL_DOCKER=false
INSTALL_OLLAMA=true
INSTALL_WEBUI=false
INSTALL_WARMUP=false
PULL_MODELS=false

if prompt_yes_no "Install Docker? (Required for Open WebUI)" "y"; then
    INSTALL_DOCKER=true
fi

if prompt_yes_no "Install Open WebUI? (ChatGPT-like web interface)" "y"; then
    INSTALL_WEBUI=true
    if [ "$INSTALL_DOCKER" = false ]; then
        echo -e "${YELLOW}⚠  Open WebUI requires Docker. Enabling Docker installation.${NC}"
        INSTALL_DOCKER=true
    fi
fi

echo ""
echo -e "${CYAN}ℹ️  Auto-start on boot:${NC}"
echo "   Ollama services will automatically start on system boot (systemd)"
echo ""

if prompt_yes_no "Setup auto-warmup? (Keep models loaded in VRAM on boot)" "y"; then
    INSTALL_WARMUP=true
    echo -e "${GREEN}✓${NC} Auto-warmup will be enabled (models load on boot)"
else
    echo -e "${YELLOW}⚠${NC}  First query after boot will be slow (models load on-demand)"
fi

if prompt_yes_no "Pull models after installation?" "y"; then
    PULL_MODELS=true
    echo ""
    echo "Model selection:"
    echo "  1) Same model on all GPUs"
    echo "  2) Different models per GPU"
    read -p "Select [1-2]: " MODEL_MODE
    
    if [ "$MODEL_MODE" = "1" ]; then
        read -p "Enter model name (e.g., gemma3:12b): " MODEL_NAME
    else
        read -p "Enter model for GPU 0 (e.g., gemma3:12b): " MODEL_GPU0
        read -p "Enter model for GPU 1 (e.g., gemma3:4b): " MODEL_GPU1
    fi
fi

# Create configuration
echo ""
echo -e "${YELLOW}════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}              Creating Configuration                    ${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════════${NC}"
echo ""

cat > "$SCRIPT_DIR/.env" << EOF
# FrankenLLM Configuration
# Generated by setup-frankenllm.sh on $(date)

FRANKEN_SERVER_IP=$SERVER_IP
FRANKEN_GPU0_PORT=$GPU0_PORT
FRANKEN_GPU1_PORT=$GPU1_PORT
FRANKEN_GPU0_NAME="GPU 0"
FRANKEN_GPU1_NAME="GPU 1"
EOF

echo -e "${GREEN}✓${NC} Configuration saved to .env"

# Cache sudo password for local installation
if [ "$INSTALL_TYPE" = "local" ]; then
    echo ""
    echo -e "${YELLOW}Caching sudo credentials for smoother installation...${NC}"
    sudo -v
    
    # Keep sudo alive in background
    (while true; do sudo -v; sleep 50; done) &
    SUDO_KEEPALIVE_PID=$!
    trap "kill $SUDO_KEEPALIVE_PID 2>/dev/null" EXIT
fi

# Function to execute commands (local or remote)
exec_cmd() {
    if [ "$INSTALL_TYPE" = "local" ]; then
        eval "$1"
    else
        ssh -t "$SERVER_IP" "$1"
    fi
}

# Start installation
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}            Starting Installation Process                ${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
echo ""

STEP=1

# Install Docker
if [ "$INSTALL_DOCKER" = true ]; then
    echo -e "${BLUE}[$STEP] Checking Docker installation...${NC}"
    
    # Check if Docker is already installed
    DOCKER_INSTALLED=false
    if [ "$INSTALL_TYPE" = "local" ]; then
        if command -v docker &> /dev/null; then
            DOCKER_INSTALLED=true
            DOCKER_VERSION=$(docker --version)
        fi
    else
        if ssh "$SERVER_IP" "command -v docker &> /dev/null" 2>/dev/null; then
            DOCKER_INSTALLED=true
            DOCKER_VERSION=$(ssh "$SERVER_IP" "docker --version" 2>/dev/null)
        fi
    fi
    
    if [ "$DOCKER_INSTALLED" = true ]; then
        echo -e "${GREEN}✓ Docker already installed: $DOCKER_VERSION${NC}"
        echo -e "${CYAN}  Skipping Docker installation${NC}"
    else
        echo "Installing Docker..."
        if [ "$INSTALL_TYPE" = "local" ]; then
            bash "$SCRIPT_DIR/scripts/install-docker.sh"
        else
            # Copy script to remote and execute
            scp "$SCRIPT_DIR/scripts/install-docker.sh" "$SERVER_IP:/tmp/" > /dev/null
            ssh -t "$SERVER_IP" "bash /tmp/install-docker.sh && rm /tmp/install-docker.sh"
        fi
        echo -e "${GREEN}✓ Docker installed${NC}"
    fi
    ((STEP++))
    echo ""
fi

# Install Ollama
echo -e "${BLUE}[$STEP] Checking Ollama services...${NC}"

# Check for existing Ollama installation
OLLAMA_EXISTS=false
if [ "$INSTALL_TYPE" = "local" ]; then
    if systemctl list-unit-files | grep -q "ollama-gpu0.service"; then
        OLLAMA_EXISTS=true
    fi
else
    if ssh "$SERVER_IP" "systemctl list-unit-files | grep -q 'ollama-gpu0.service'" 2>/dev/null; then
        OLLAMA_EXISTS=true
    fi
fi

if [ "$OLLAMA_EXISTS" = true ]; then
    echo -e "${YELLOW}⚠  Existing Ollama services detected${NC}"
    echo ""
    echo "Options:"
    echo "  1) Keep existing (update configuration only)"
    echo "  2) Reinstall (stops, removes, and recreates services)"
    echo "  3) Skip (leave everything as-is)"
    read -p "Select [1-3]: " OLLAMA_ACTION
    
    case $OLLAMA_ACTION in
        2)
            echo -e "${YELLOW}Reinstalling Ollama services...${NC}"
            if [ "$INSTALL_TYPE" = "local" ]; then
                sudo systemctl stop ollama-gpu0 ollama-gpu1 2>/dev/null || true
                sudo systemctl disable ollama-gpu0 ollama-gpu1 2>/dev/null || true
            else
                ssh -t "$SERVER_IP" "sudo systemctl stop ollama-gpu0 ollama-gpu1 2>/dev/null || true"
                ssh -t "$SERVER_IP" "sudo systemctl disable ollama-gpu0 ollama-gpu1 2>/dev/null || true"
            fi
            ;;
        3)
            echo -e "${CYAN}Skipping Ollama installation${NC}"
            ((STEP++))
            echo ""
            INSTALL_OLLAMA=false
            ;;
        *)
            echo -e "${CYAN}Keeping existing services, updating if needed${NC}"
            ;;
    esac
fi

if [ "${INSTALL_OLLAMA:-true}" != false ]; then
    if [ "$INSTALL_TYPE" = "local" ]; then
        bash "$SCRIPT_DIR/local/install.sh"
    else
        bash "$SCRIPT_DIR/remote/install.sh"
    fi
    echo -e "${GREEN}✓ Ollama services configured and running${NC}"
fi
((STEP++))
echo ""

# Install Open WebUI
if [ "$INSTALL_WEBUI" = true ]; then
    echo -e "${BLUE}[$STEP] Installing Open WebUI...${NC}"
    
    if [ "$INSTALL_TYPE" = "local" ]; then
        bash "$SCRIPT_DIR/bin/install-webui.sh"
    else
        bash "$SCRIPT_DIR/remote/install-webui.sh"
    fi
    
    echo -e "${GREEN}✓ Open WebUI installed${NC}"
    ((STEP++))
    echo ""
fi

# Setup auto-warmup
if [ "$INSTALL_WARMUP" = true ]; then
    echo -e "${BLUE}[$STEP] Setting up auto-warmup service...${NC}"
    
    if [ "$INSTALL_TYPE" = "local" ]; then
        # Local warmup setup
        source "$SCRIPT_DIR/config.sh"
        sudo cp "$SCRIPT_DIR/bin/warmup-on-boot.sh" /usr/local/bin/frankenllm-warmup
        sudo chmod +x /usr/local/bin/frankenllm-warmup
        
        sudo tee /etc/systemd/system/frankenllm-warmup.service > /dev/null << WARMUPEOF
[Unit]
Description=FrankenLLM Model Warmup
After=ollama-gpu0.service ollama-gpu1.service
Requires=ollama-gpu0.service ollama-gpu1.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/frankenllm-warmup
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
WARMUPEOF
        
        sudo systemctl daemon-reload
        sudo systemctl enable frankenllm-warmup.service
    else
        bash "$SCRIPT_DIR/remote/setup-warmup.sh"
    fi
    
    echo -e "${GREEN}✓ Auto-warmup configured${NC}"
    ((STEP++))
    echo ""
fi

# Pull models
if [ "$PULL_MODELS" = true ]; then
    echo -e "${BLUE}[$STEP] Pulling models...${NC}"
    echo "This may take several minutes depending on model size..."
    echo ""
    
    if [ "$MODEL_MODE" = "1" ]; then
        bash "$SCRIPT_DIR/bin/pull-model.sh" "$MODEL_NAME"
    else
        bash "$SCRIPT_DIR/bin/pull-dual-models.sh" "$MODEL_GPU0" "$MODEL_GPU1"
    fi
    
    echo -e "${GREEN}✓ Models downloaded${NC}"
    ((STEP++))
    echo ""
fi

# Installation complete
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                              ║${NC}"
echo -e "${GREEN}║             🎉 Installation Complete! 🎉                     ║${NC}"
echo -e "${GREEN}║                                                              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Show next steps
echo -e "${CYAN}📋 What's Next:${NC}"
echo ""

if [ "$INSTALL_TYPE" = "remote" ]; then
    echo -e "${YELLOW}🌐 Access Your Services:${NC}"
    echo "  • Ollama GPU 0: http://$SERVER_IP:$GPU0_PORT"
    if [ "$GPU_COUNT" -ge 2 ]; then
        echo "  • Ollama GPU 1: http://$SERVER_IP:$GPU1_PORT"
    fi
    if [ "$INSTALL_WEBUI" = true ]; then
        echo "  • Open WebUI:   http://$SERVER_IP:3000"
    fi
else
    echo -e "${YELLOW}💻 Access Your Services:${NC}"
    echo "  • Ollama GPU 0: http://localhost:$GPU0_PORT"
    if [ "$GPU_COUNT" -ge 2 ]; then
        echo "  • Ollama GPU 1: http://localhost:$GPU1_PORT"
    fi
    if [ "$INSTALL_WEBUI" = true ]; then
        echo "  • Open WebUI:   http://localhost:3000"
    fi
fi

echo ""
echo -e "${YELLOW}⚙️  Auto-Start Configuration:${NC}"
echo "  • Ollama services: ${GREEN}✅ Enabled${NC} (starts on boot)"
if [ "$INSTALL_WARMUP" = true ]; then
    echo "  • Model warmup:    ${GREEN}✅ Enabled${NC} (models load on boot)"
    echo "  • First query:     ${GREEN}⚡ INSTANT${NC} (models stay in VRAM)"
else
    echo "  • Model warmup:    ${YELLOW}⚠  Disabled${NC} (manual warmup needed)"
    echo "  • First query:     ${YELLOW}⏱  SLOW${NC} (10-30s to load model)"
fi
if [ "$INSTALL_WEBUI" = true ]; then
    echo "  • Open WebUI:      ${GREEN}✅ Enabled${NC} (Docker --restart always)"
fi

echo ""
echo -e "${YELLOW}🎮 Useful Commands:${NC}"
echo "  • Test LLMs:     ./bin/test-connection.sh"
echo "  • Chat:          ./bin/chat.sh"
echo "  • Check GPUs:    ./bin/check-gpus.sh"
echo "  • Health check:  ./bin/health-check.sh"
echo "  • Manage:        ./manage.sh status"
echo ""

if [ "$INSTALL_WARMUP" = false ] && [ "$PULL_MODELS" = true ]; then
    echo -e "${YELLOW}💡 Tip:${NC} First query may be slow. Run this to pre-load models:"
    if [ "$MODEL_MODE" = "1" ]; then
        echo "  ./bin/warmup-models.sh $MODEL_NAME $MODEL_NAME"
    else
        echo "  ./bin/warmup-models.sh $MODEL_GPU0 $MODEL_GPU1"
    fi
    echo ""
    echo -e "${CYAN}To enable auto-warmup on boot later:${NC}"
    if [ "$INSTALL_TYPE" = "remote" ]; then
        echo "  ./remote/setup-warmup.sh"
    else
        echo "  Manually run: sudo systemctl enable frankenllm-warmup.service"
    fi
    echo ""
fi

echo -e "${CYAN}📚 Documentation:${NC}"
echo "  • Getting Started: cat GETTING_STARTED.md"
echo "  • Full docs:       ls docs/"
echo ""

echo -e "${CYAN}🔄 After System Reboot:${NC}"
if [ "$INSTALL_WARMUP" = true ]; then
    echo "  ${GREEN}✅${NC} Everything starts automatically!"
    echo "  ${GREEN}✅${NC} Models loaded within ~50 seconds"
    echo "  ${GREEN}✅${NC} Ready for instant queries"
else
    echo "  ${GREEN}✅${NC} Ollama services start automatically"
    echo "  ${YELLOW}⚠${NC}  Models load on first query (10-30s delay)"
    echo "  ${CYAN}💡${NC} Run warmup manually: ./bin/warmup-models.sh"
fi
echo ""

echo -e "${GREEN}Happy FrankenLLMing! 🧟‍♂️⚡${NC}"
echo ""
