#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Health Check Module Installer
# Can be run standalone or as part of main install

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Default install location
INSTALL_DIR="${FRANKEN_INSTALL_DIR:-/opt/frankenllm}"

print_header() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  FrankenLLM Health Check Module Installer${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_step() {
    echo -e "${GREEN}▶${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_ok() {
    echo -e "${GREEN}✓${NC} $1"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Install health check scripts
install_scripts() {
    print_step "Installing health check scripts..."
    
    # Create directories
    mkdir -p "$INSTALL_DIR/scripts"
    mkdir -p /var/lib/frankenllm
    mkdir -p /var/log
    
    # Copy scripts (only if source != destination)
    if [ "$SCRIPT_DIR" != "$INSTALL_DIR/scripts" ]; then
        cp "$SCRIPT_DIR/health-check.sh" "$INSTALL_DIR/scripts/" 2>/dev/null || true
        cp "$SCRIPT_DIR/auto-fix.sh" "$INSTALL_DIR/scripts/" 2>/dev/null || true
    fi
    
    # Make executable
    chmod +x "$INSTALL_DIR/scripts/health-check.sh" 2>/dev/null || true
    chmod +x "$INSTALL_DIR/scripts/auto-fix.sh" 2>/dev/null || true
    
    print_ok "Scripts installed to $INSTALL_DIR/scripts/"
}

# Install systemd service for auto-fix on boot
install_autofix_service() {
    print_step "Installing auto-fix systemd service..."
    
    # Create service file with correct path
    cat > /etc/systemd/system/frankenllm-autofix.service << EOF
[Unit]
Description=FrankenLLM GPU Health Auto-Fix
After=network.target nvidia-persistenced.service
Wants=nvidia-persistenced.service
Before=ollama-gpu0.service ollama-gpu1.service

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/scripts/auto-fix.sh check
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd
    systemctl daemon-reload
    
    print_ok "Systemd service installed"
}

# Install CLI wrapper
install_cli() {
    print_step "Installing CLI command..."
    
    # Create frankenllm command wrapper
    cat > /usr/local/bin/frankenllm << EOF
#!/bin/bash
# FrankenLLM CLI Wrapper

INSTALL_DIR="$INSTALL_DIR"

case "\$1" in
    health|check)
        "\$INSTALL_DIR/scripts/health-check.sh" "\${@:2}"
        ;;
    fix)
        sudo "\$INSTALL_DIR/scripts/auto-fix.sh" fix
        ;;
    reset-alerts|reset)
        sudo "\$INSTALL_DIR/scripts/auto-fix.sh" reset
        ;;
    autofix-status)
        sudo "\$INSTALL_DIR/scripts/auto-fix.sh" status
        ;;
    start|stop|restart|status|logs|enable|disable)
        "\$INSTALL_DIR/manage.sh" "\$@"
        ;;
    *)
        echo "FrankenLLM - Stitched-together GPUs, but it lives!"
        echo ""
        echo "Usage: frankenllm <command>"
        echo ""
        echo "Health Commands:"
        echo "  health [quick]    - Run GPU health check"
        echo "  fix               - Attempt to fix GPU issues"
        echo "  reset-alerts      - Reset failure counter and clear login alerts"
        echo "  autofix-status    - Show auto-fix state"
        echo ""
        echo "Service Commands:"
        echo "  start             - Start Ollama services"
        echo "  stop              - Stop Ollama services"
        echo "  restart           - Restart Ollama services"
        echo "  status            - Show service status"
        echo "  logs              - Show service logs"
        echo "  enable            - Enable services on boot"
        echo "  disable           - Disable services on boot"
        ;;
esac
EOF

    chmod +x /usr/local/bin/frankenllm
    
    print_ok "CLI installed: frankenllm"
}

# Install login notification
install_login_check() {
    print_step "Installing login health check..."
    
    # Create profile.d script for optional quick check on login
    cat > /etc/profile.d/frankenllm-health.sh << 'EOF'
# FrankenLLM Quick Health Check on Login
# Set FRANKENLLM_LOGIN_CHECK=1 to enable

if [ "${FRANKENLLM_LOGIN_CHECK:-0}" = "1" ] && command -v nvidia-smi &>/dev/null; then
    if ! nvidia-smi &>/dev/null 2>&1; then
        echo ""
        echo -e "\033[0;31m⚠ FrankenLLM: GPU health check failed!\033[0m"
        echo "  Run 'frankenllm health' for details"
        echo ""
    fi
fi
EOF

    chmod +x /etc/profile.d/frankenllm-health.sh
    
    print_ok "Login check installed (enable with: export FRANKENLLM_LOGIN_CHECK=1)"
}

# Enable auto-fix service
enable_autofix() {
    print_step "Enabling auto-fix service..."
    
    systemctl enable frankenllm-autofix.service
    
    print_ok "Auto-fix will run on every boot"
}

# Disable auto-fix service
disable_autofix() {
    print_step "Disabling auto-fix service..."
    
    systemctl disable frankenllm-autofix.service 2>/dev/null || true
    
    print_ok "Auto-fix service disabled"
}

# Uninstall everything
uninstall() {
    print_step "Uninstalling health check module..."
    
    # Stop and disable service
    systemctl stop frankenllm-autofix.service 2>/dev/null || true
    systemctl disable frankenllm-autofix.service 2>/dev/null || true
    
    # Remove files
    rm -f /etc/systemd/system/frankenllm-autofix.service
    rm -f /usr/local/bin/frankenllm
    rm -f /etc/profile.d/frankenllm-health.sh
    rm -f /etc/update-motd.d/99-frankenllm-alert
    rm -f "$INSTALL_DIR/scripts/health-check.sh"
    rm -f "$INSTALL_DIR/scripts/auto-fix.sh"
    rm -rf /var/lib/frankenllm
    
    systemctl daemon-reload
    
    print_ok "Health check module uninstalled"
}

# Show status
show_status() {
    echo "FrankenLLM Health Check Module Status"
    echo "======================================"
    echo ""
    
    # Check if scripts exist
    if [ -f "$INSTALL_DIR/scripts/health-check.sh" ]; then
        echo -e "${GREEN}✓${NC} health-check.sh installed"
    else
        echo -e "${RED}✗${NC} health-check.sh not found"
    fi
    
    if [ -f "$INSTALL_DIR/scripts/auto-fix.sh" ]; then
        echo -e "${GREEN}✓${NC} auto-fix.sh installed"
    else
        echo -e "${RED}✗${NC} auto-fix.sh not found"
    fi
    
    # Check CLI
    if [ -f "/usr/local/bin/frankenllm" ]; then
        echo -e "${GREEN}✓${NC} CLI wrapper installed"
    else
        echo -e "${RED}✗${NC} CLI wrapper not found"
    fi
    
    # Check service
    if systemctl is-enabled frankenllm-autofix.service &>/dev/null; then
        echo -e "${GREEN}✓${NC} Auto-fix service enabled"
    else
        echo -e "${YELLOW}○${NC} Auto-fix service not enabled"
    fi
    
    # Check login script
    if [ -f "/etc/profile.d/frankenllm-health.sh" ]; then
        echo -e "${GREEN}✓${NC} Login check script installed"
    else
        echo -e "${YELLOW}○${NC} Login check script not installed"
    fi
    
    echo ""
}

# Main installation
install_full() {
    print_header
    check_root
    
    install_scripts
    install_autofix_service
    install_cli
    install_login_check
    enable_autofix
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Installation Complete!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "The health check module is now installed and will:"
    echo "  • Automatically check GPU health on every boot"
    echo "  • Attempt to fix driver issues automatically"
    echo "  • Alert you on login if issues persist after $MAX_RETRIES attempts"
    echo ""
    echo "Commands:"
    echo "  frankenllm health        - Run health check"
    echo "  frankenllm health quick  - Quick check"
    echo "  frankenllm fix           - Manual fix attempt"
    echo "  frankenllm reset-alerts  - Clear alerts after manual fix"
    echo "  frankenllm autofix-status - View auto-fix state"
    echo ""
}

# Parse arguments
case "${1:-install}" in
    install|"")
        install_full
        ;;
    scripts-only)
        # Just install scripts without services (for main installer to call)
        check_root
        install_scripts
        ;;
    service-only)
        check_root
        install_autofix_service
        enable_autofix
        ;;
    cli-only)
        check_root
        install_cli
        ;;
    enable)
        check_root
        enable_autofix
        ;;
    disable)
        check_root
        disable_autofix
        ;;
    uninstall)
        check_root
        uninstall
        ;;
    status)
        show_status
        ;;
    help|-h|--help)
        echo "FrankenLLM Health Check Module Installer"
        echo ""
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  install       - Full installation (default)"
        echo "  scripts-only  - Install scripts only (no services)"
        echo "  service-only  - Install and enable systemd service only"
        echo "  cli-only      - Install CLI wrapper only"
        echo "  enable        - Enable auto-fix on boot"
        echo "  disable       - Disable auto-fix on boot"
        echo "  uninstall     - Remove health check module"
        echo "  status        - Show installation status"
        echo "  help          - Show this help"
        ;;
    *)
        print_error "Unknown command: $1"
        echo "Use '$0 help' for usage information"
        exit 1
        ;;
esac
