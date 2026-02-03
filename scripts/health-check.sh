#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - System Health Check
# Detects NVIDIA driver issues, GPU health, and service status

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load configuration if available
if [ -f "$PROJECT_ROOT/config.sh" ]; then
    source "$PROJECT_ROOT/config.sh"
fi

# Track overall health
HEALTH_OK=true
WARNINGS=()
ERRORS=()

print_header() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  FrankenLLM Health Check${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_section() {
    echo -e "${BLUE}▶ $1${NC}"
}

print_ok() {
    echo -e "  ${GREEN}✓${NC} $1"
}

print_warn() {
    echo -e "  ${YELLOW}⚠${NC} $1"
    WARNINGS+=("$1")
}

print_error() {
    echo -e "  ${RED}✗${NC} $1"
    ERRORS+=("$1")
    HEALTH_OK=false
}

print_info() {
    echo -e "  ${BLUE}ℹ${NC} $1"
}

# Check if NVIDIA driver is loaded
check_nvidia_driver() {
    print_section "NVIDIA Driver Status"
    
    # Check if nvidia module is loaded
    if lsmod | grep -q "^nvidia "; then
        print_ok "NVIDIA kernel module loaded"
    else
        print_error "NVIDIA kernel module not loaded"
        print_info "Try: sudo modprobe nvidia"
        return 1
    fi
    
    # Check for driver/library version mismatch
    if nvidia-smi &>/dev/null; then
        DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
        print_ok "nvidia-smi working (Driver: $DRIVER_VERSION)"
    else
        # Try to get more info about the failure
        ERROR_MSG=$(nvidia-smi 2>&1)
        if echo "$ERROR_MSG" | grep -q "Driver/library version mismatch"; then
            print_error "NVIDIA Driver/Library version mismatch detected!"
            
            # Try to get NVML version
            NVML_VERSION=$(echo "$ERROR_MSG" | grep -oP "NVML library version: \K[0-9.]+")
            if [ -n "$NVML_VERSION" ]; then
                print_info "NVML library version: $NVML_VERSION"
            fi
            
            print_info ""
            print_info "This usually happens after a driver update without reboot."
            print_info "Solutions (in order of preference):"
            print_info "  1. Reboot the system: sudo reboot"
            print_info "  2. Try reloading the driver (may not work if GPUs are in use):"
            print_info "     sudo rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia"
            print_info "     sudo modprobe nvidia"
            return 1
        elif echo "$ERROR_MSG" | grep -q "NVIDIA-SMI has failed"; then
            print_error "nvidia-smi failed: $ERROR_MSG"
            return 1
        else
            print_error "nvidia-smi error: $ERROR_MSG"
            return 1
        fi
    fi
    
    return 0
}

# Check GPU health and stats
check_gpu_health() {
    print_section "GPU Health"
    
    if ! nvidia-smi &>/dev/null; then
        print_error "Cannot check GPU health - nvidia-smi not working"
        return 1
    fi
    
    # Get GPU count
    GPU_COUNT=$(nvidia-smi --query-gpu=count --format=csv,noheader 2>/dev/null | head -1)
    print_ok "Found $GPU_COUNT GPU(s)"
    
    # Check each GPU
    while IFS=',' read -r idx name temp mem_used mem_total util power_state; do
        # Clean up values
        idx=$(echo "$idx" | xargs)
        name=$(echo "$name" | xargs)
        temp=$(echo "$temp" | xargs | tr -d ' C')
        mem_used=$(echo "$mem_used" | xargs | tr -d ' MiB')
        mem_total=$(echo "$mem_total" | xargs | tr -d ' MiB')
        util=$(echo "$util" | xargs | tr -d ' %')
        power_state=$(echo "$power_state" | xargs)
        
        echo ""
        print_info "GPU $idx: $name"
        
        # Temperature check
        if [ -n "$temp" ] && [ "$temp" != "[N/A]" ]; then
            if [ "$temp" -lt 80 ]; then
                print_ok "Temperature: ${temp}°C"
            elif [ "$temp" -lt 90 ]; then
                print_warn "Temperature: ${temp}°C (elevated)"
            else
                print_error "Temperature: ${temp}°C (critical!)"
            fi
        fi
        
        # Memory check
        if [ -n "$mem_used" ] && [ -n "$mem_total" ] && [ "$mem_total" != "0" ]; then
            MEM_PERCENT=$((mem_used * 100 / mem_total))
            print_ok "Memory: ${mem_used}/${mem_total} MiB (${MEM_PERCENT}%)"
        fi
        
        # Utilization
        if [ -n "$util" ] && [ "$util" != "[N/A]" ]; then
            print_ok "Utilization: ${util}%"
        fi
        
        # Power state
        if [ -n "$power_state" ]; then
            print_ok "Power State: $power_state"
        fi
        
    done < <(nvidia-smi --query-gpu=index,name,temperature.gpu,memory.used,memory.total,utilization.gpu,pstate --format=csv,noheader 2>/dev/null)
    
    return 0
}

# Check for pending driver updates
check_driver_updates() {
    print_section "Driver Update Status"
    
    # Check if there's a newer driver installed but not loaded
    if [ -d "/usr/lib/modules" ]; then
        RUNNING_KERNEL=$(uname -r)
        
        # Check for nvidia modules in current kernel
        if [ -d "/usr/lib/modules/$RUNNING_KERNEL/kernel/drivers/video" ] || \
           [ -d "/usr/lib/modules/$RUNNING_KERNEL/updates/dkms" ]; then
            
            # Look for nvidia module files
            NVIDIA_KO=$(find /usr/lib/modules/$RUNNING_KERNEL -name "nvidia*.ko*" 2>/dev/null | head -1)
            if [ -n "$NVIDIA_KO" ]; then
                print_ok "NVIDIA kernel modules found for running kernel"
            fi
        fi
    fi
    
    # Check if a reboot is required (Ubuntu/Debian)
    if [ -f /var/run/reboot-required ]; then
        print_warn "System reboot required"
        if [ -f /var/run/reboot-required.pkgs ]; then
            REBOOT_PKGS=$(cat /var/run/reboot-required.pkgs | tr '\n' ', ' | sed 's/,$//')
            print_info "Packages requiring reboot: $REBOOT_PKGS"
        fi
    else
        print_ok "No reboot required"
    fi
    
    # Check for held packages
    if command -v apt-mark &>/dev/null; then
        HELD=$(apt-mark showhold 2>/dev/null | grep -i nvidia)
        if [ -n "$HELD" ]; then
            print_info "Held NVIDIA packages: $HELD"
        fi
    fi
    
    return 0
}

# Check Ollama services
check_ollama_services() {
    print_section "Ollama Services"
    
    GPU_COUNT="${FRANKEN_GPU_COUNT:-1}"
    
    for i in $(seq 0 $((GPU_COUNT - 1))); do
        SERVICE="ollama-gpu$i"
        
        if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
            print_ok "$SERVICE is running"
            
            # Check if port is responding
            PORT_VAR="FRANKEN_GPU${i}_PORT"
            PORT="${!PORT_VAR:-$((11434 + i))}"
            
            if curl -s --connect-timeout 2 "http://localhost:$PORT/api/tags" &>/dev/null; then
                print_ok "$SERVICE responding on port $PORT"
            else
                print_warn "$SERVICE not responding on port $PORT"
            fi
        elif systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
            print_warn "$SERVICE is enabled but not running"
        else
            print_info "$SERVICE not found or not enabled"
        fi
    done
    
    return 0
}

# Check system resources
check_system_resources() {
    print_section "System Resources"
    
    # Memory
    MEM_INFO=$(free -m | awk '/^Mem:/ {print $2, $3, $7}')
    MEM_TOTAL=$(echo $MEM_INFO | awk '{print $1}')
    MEM_USED=$(echo $MEM_INFO | awk '{print $2}')
    MEM_AVAIL=$(echo $MEM_INFO | awk '{print $3}')
    MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))
    
    if [ "$MEM_PERCENT" -lt 80 ]; then
        print_ok "RAM: ${MEM_USED}/${MEM_TOTAL} MB used (${MEM_PERCENT}%), ${MEM_AVAIL} MB available"
    elif [ "$MEM_PERCENT" -lt 95 ]; then
        print_warn "RAM: ${MEM_USED}/${MEM_TOTAL} MB used (${MEM_PERCENT}%) - running low"
    else
        print_error "RAM: ${MEM_USED}/${MEM_TOTAL} MB used (${MEM_PERCENT}%) - critical!"
    fi
    
    # Disk space for common Ollama paths
    for PATH_CHECK in "/usr/share/ollama" "$HOME/.ollama" "/var/lib/ollama"; do
        if [ -d "$PATH_CHECK" ]; then
            DISK_INFO=$(df -BG "$PATH_CHECK" 2>/dev/null | tail -1)
            DISK_USED=$(echo $DISK_INFO | awk '{print $3}' | tr -d 'G')
            DISK_AVAIL=$(echo $DISK_INFO | awk '{print $4}' | tr -d 'G')
            DISK_PERCENT=$(echo $DISK_INFO | awk '{print $5}' | tr -d '%')
            
            if [ "$DISK_PERCENT" -lt 80 ]; then
                print_ok "Disk ($PATH_CHECK): ${DISK_AVAIL}G available (${DISK_PERCENT}% used)"
            elif [ "$DISK_PERCENT" -lt 95 ]; then
                print_warn "Disk ($PATH_CHECK): ${DISK_AVAIL}G available (${DISK_PERCENT}% used) - running low"
            else
                print_error "Disk ($PATH_CHECK): ${DISK_AVAIL}G available (${DISK_PERCENT}% used) - critical!"
            fi
            break
        fi
    done
    
    return 0
}

# Check CUDA
check_cuda() {
    print_section "CUDA Status"
    
    if [ -d "/usr/local/cuda" ]; then
        if [ -f "/usr/local/cuda/version.txt" ]; then
            CUDA_VERSION=$(cat /usr/local/cuda/version.txt)
            print_ok "CUDA installed: $CUDA_VERSION"
        elif [ -x "/usr/local/cuda/bin/nvcc" ]; then
            CUDA_VERSION=$(/usr/local/cuda/bin/nvcc --version 2>/dev/null | grep "release" | awk '{print $6}' | tr -d ',')
            print_ok "CUDA toolkit: $CUDA_VERSION"
        else
            print_ok "CUDA directory exists at /usr/local/cuda"
        fi
    else
        print_info "CUDA toolkit not found in /usr/local/cuda (may not be needed)"
    fi
    
    # Check nvidia-cuda-toolkit
    if command -v nvcc &>/dev/null; then
        NVCC_VERSION=$(nvcc --version 2>/dev/null | grep "release" | awk '{print $6}' | tr -d ',')
        print_ok "nvcc available: $NVCC_VERSION"
    fi
    
    return 0
}

# Print summary
print_summary() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Summary${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    if [ "$HEALTH_OK" = true ] && [ ${#WARNINGS[@]} -eq 0 ]; then
        echo -e "${GREEN}✓ All systems healthy!${NC}"
    elif [ "$HEALTH_OK" = true ]; then
        echo -e "${YELLOW}⚠ System operational with ${#WARNINGS[@]} warning(s)${NC}"
        for warn in "${WARNINGS[@]}"; do
            echo -e "  ${YELLOW}•${NC} $warn"
        done
    else
        echo -e "${RED}✗ System has ${#ERRORS[@]} error(s) and ${#WARNINGS[@]} warning(s)${NC}"
        echo ""
        if [ ${#ERRORS[@]} -gt 0 ]; then
            echo -e "${RED}Errors:${NC}"
            for err in "${ERRORS[@]}"; do
                echo -e "  ${RED}•${NC} $err"
            done
        fi
        if [ ${#WARNINGS[@]} -gt 0 ]; then
            echo ""
            echo -e "${YELLOW}Warnings:${NC}"
            for warn in "${WARNINGS[@]}"; do
                echo -e "  ${YELLOW}•${NC} $warn"
            done
        fi
    fi
    echo ""
}

# Quick check mode - just check for critical issues
quick_check() {
    # Silent check for nvidia-smi
    if ! nvidia-smi &>/dev/null; then
        ERROR_MSG=$(nvidia-smi 2>&1)
        if echo "$ERROR_MSG" | grep -q "Driver/library version mismatch"; then
            echo -e "${RED}ERROR: NVIDIA Driver/Library version mismatch!${NC}"
            echo -e "${YELLOW}A reboot is required: sudo reboot${NC}"
            return 1
        else
            echo -e "${RED}ERROR: nvidia-smi failed${NC}"
            echo "$ERROR_MSG"
            return 1
        fi
    fi
    
    # Check GPU temps
    while IFS=',' read -r temp; do
        temp=$(echo "$temp" | xargs | tr -d ' C')
        if [ -n "$temp" ] && [ "$temp" != "[N/A]" ] && [ "$temp" -ge 90 ]; then
            echo -e "${RED}WARNING: GPU temperature critical: ${temp}°C${NC}"
            return 1
        fi
    done < <(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null)
    
    echo -e "${GREEN}✓ Quick check passed${NC}"
    return 0
}

# Main
main() {
    case "${1:-full}" in
        quick|-q|--quick)
            quick_check
            exit $?
            ;;
        full|-f|--full|"")
            print_header
            check_nvidia_driver
            check_gpu_health
            check_driver_updates
            check_cuda
            check_ollama_services
            check_system_resources
            print_summary
            
            if [ "$HEALTH_OK" = true ]; then
                exit 0
            else
                exit 1
            fi
            ;;
        help|-h|--help)
            echo "FrankenLLM Health Check"
            echo ""
            echo "Usage: $0 [command]"
            echo ""
            echo "Commands:"
            echo "  full, -f   Full health check (default)"
            echo "  quick, -q  Quick check for critical issues only"
            echo "  help, -h   Show this help"
            exit 0
            ;;
        *)
            echo "Unknown command: $1"
            echo "Use '$0 help' for usage information"
            exit 1
            ;;
    esac
}

main "$@"
