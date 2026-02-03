#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - Automatic Fix Script
# Attempts to fix common GPU issues, tracks failures, and alerts on persistent problems

set -e

# Configuration
STATE_FILE="/var/lib/frankenllm/boot-state"
STATE_DIR="/var/lib/frankenllm"
MAX_RETRIES="${FRANKEN_MAX_BOOT_RETRIES:-3}"
LOG_FILE="/var/log/frankenllm-autofix.log"
MOTD_FILE="/etc/update-motd.d/99-frankenllm-alert"

# Ensure state directory exists
mkdir -p "$STATE_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Read current state
read_state() {
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
    else
        FAIL_COUNT=0
        LAST_ERROR=""
        LAST_ATTEMPT=""
        ALERT_SHOWN=false
    fi
}

# Write state
write_state() {
    cat > "$STATE_FILE" << EOF
FAIL_COUNT=$FAIL_COUNT
LAST_ERROR="$LAST_ERROR"
LAST_ATTEMPT="$(date '+%Y-%m-%d %H:%M:%S')"
ALERT_SHOWN=$ALERT_SHOWN
EOF
}

# Reset state on success
reset_state() {
    FAIL_COUNT=0
    LAST_ERROR=""
    ALERT_SHOWN=false
    write_state
    
    # Remove MOTD alert if it exists
    if [ -f "$MOTD_FILE" ]; then
        rm -f "$MOTD_FILE"
        log "Cleared MOTD alert - system healthy"
    fi
}

# Create MOTD alert for persistent failures
create_alert() {
    cat > "$MOTD_FILE" << 'MOTD_EOF'
#!/bin/bash
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  ⚠️  FRANKENLLM GPU HEALTH ALERT                                  ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
MOTD_EOF

    cat >> "$MOTD_FILE" << MOTD_EOF
echo "║  Auto-fix has failed after $MAX_RETRIES attempts.                              ║"
echo "║                                                                  ║"
echo "║  Last Error: $(printf '%-50s' "${LAST_ERROR:0:50}")  ║"
echo "║                                                                  ║"
echo "║  Recommended Actions:                                            ║"
echo "║    1. Check: sudo frankenllm health                              ║"
echo "║    2. Review logs: cat /var/log/frankenllm-autofix.log           ║"
echo "║    3. Try manual fix: sudo frankenllm fix                        ║"
echo "║    4. After fixing: sudo frankenllm reset-alerts                 ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
MOTD_EOF

    chmod +x "$MOTD_FILE"
    log "Created MOTD alert for persistent GPU failures"
}

# Check if nvidia-smi works
check_nvidia() {
    if nvidia-smi &>/dev/null; then
        return 0
    else
        ERROR_MSG=$(nvidia-smi 2>&1)
        LAST_ERROR=$(echo "$ERROR_MSG" | head -1)
        return 1
    fi
}

# Attempt to fix driver/library mismatch by reloading modules
fix_driver_mismatch() {
    log "Attempting to fix driver/library mismatch..."
    
    # Check if any processes are using the GPU
    if lsof /dev/nvidia* &>/dev/null 2>&1; then
        log "GPU is in use, cannot reload modules. Processes using GPU:"
        lsof /dev/nvidia* 2>/dev/null | tee -a "$LOG_FILE" || true
        return 1
    fi
    
    # Stop Ollama services if running
    log "Stopping Ollama services..."
    systemctl stop 'ollama-gpu*' 2>/dev/null || true
    sleep 2
    
    # Try to unload nvidia modules
    log "Unloading NVIDIA modules..."
    for module in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
        if lsmod | grep -q "^$module "; then
            rmmod "$module" 2>/dev/null || {
                log "Failed to unload $module"
                return 1
            }
            log "Unloaded $module"
        fi
    done
    
    sleep 2
    
    # Reload nvidia module
    log "Reloading NVIDIA modules..."
    modprobe nvidia || {
        log "Failed to load nvidia module"
        return 1
    }
    
    sleep 2
    
    # Test if it worked
    if check_nvidia; then
        log "Driver reload successful!"
        
        # Restart Ollama services
        log "Restarting Ollama services..."
        systemctl start 'ollama-gpu*' 2>/dev/null || true
        
        return 0
    else
        log "Driver reload did not fix the issue"
        return 1
    fi
}

# Attempt to fix nvidia-persistenced issues
fix_persistenced() {
    log "Checking nvidia-persistenced..."
    
    if systemctl is-active --quiet nvidia-persistenced 2>/dev/null; then
        log "Restarting nvidia-persistenced..."
        systemctl restart nvidia-persistenced || true
        sleep 2
    fi
}

# Main fix routine
attempt_fix() {
    local error_type="$1"
    
    case "$error_type" in
        *"Driver/library version mismatch"*)
            fix_driver_mismatch
            return $?
            ;;
        *"NVIDIA-SMI has failed"*)
            # Try reloading modules
            fix_driver_mismatch
            return $?
            ;;
        *"No devices were found"*)
            log "No NVIDIA devices found - may be hardware issue"
            fix_persistenced
            return 1
            ;;
        *)
            log "Unknown error type, attempting generic fix..."
            fix_driver_mismatch
            return $?
            ;;
    esac
}

# Request reboot
request_reboot() {
    log "Requesting system reboot..."
    
    # Schedule reboot in 1 minute to allow logging
    shutdown -r +1 "FrankenLLM: Rebooting to fix GPU issues (attempt $FAIL_COUNT of $MAX_RETRIES)" &
    
    log "Reboot scheduled in 1 minute"
}

# Main auto-fix logic
main() {
    local action="${1:-check}"
    
    case "$action" in
        check|"")
            # Normal boot check
            read_state
            
            log "=== FrankenLLM Auto-Fix Check ==="
            log "Boot attempt: $((FAIL_COUNT + 1)) of $MAX_RETRIES max failures"
            
            # Check if nvidia is working
            if check_nvidia; then
                log "NVIDIA GPU check passed!"
                reset_state
                exit 0
            fi
            
            log "NVIDIA check failed: $LAST_ERROR"
            
            # Check if we've exceeded max retries
            if [ "$FAIL_COUNT" -ge "$MAX_RETRIES" ]; then
                log "Max retries ($MAX_RETRIES) exceeded. Giving up on auto-fix."
                
                if [ "$ALERT_SHOWN" != "true" ]; then
                    create_alert
                    ALERT_SHOWN=true
                    write_state
                fi
                
                exit 1
            fi
            
            # Attempt to fix
            log "Attempting automatic fix..."
            if attempt_fix "$LAST_ERROR"; then
                log "Fix successful!"
                reset_state
                exit 0
            fi
            
            # Fix failed, increment counter
            FAIL_COUNT=$((FAIL_COUNT + 1))
            write_state
            
            log "Fix attempt failed. Fail count: $FAIL_COUNT"
            
            # If still under max retries, reboot
            if [ "$FAIL_COUNT" -lt "$MAX_RETRIES" ]; then
                log "Will reboot to retry..."
                request_reboot
            else
                log "Max retries reached. Creating alert..."
                create_alert
                ALERT_SHOWN=true
                write_state
            fi
            
            exit 1
            ;;
            
        fix)
            # Manual fix attempt (doesn't count toward retries)
            log "=== Manual Fix Attempt ==="
            
            if check_nvidia; then
                log "NVIDIA is already working!"
                reset_state
                exit 0
            fi
            
            log "Attempting fix for: $LAST_ERROR"
            
            if attempt_fix "$LAST_ERROR"; then
                log "Fix successful!"
                reset_state
                exit 0
            else
                log "Fix failed. Manual intervention may be required."
                log "Consider: sudo reboot"
                exit 1
            fi
            ;;
            
        reset|reset-alerts)
            # Reset state and remove alerts
            log "Resetting auto-fix state and alerts..."
            reset_state
            log "State reset complete"
            exit 0
            ;;
            
        status)
            # Show current state
            read_state
            echo "FrankenLLM Auto-Fix Status"
            echo "=========================="
            echo "Failure Count: $FAIL_COUNT / $MAX_RETRIES"
            echo "Last Error: ${LAST_ERROR:-None}"
            echo "Last Attempt: ${LAST_ATTEMPT:-Never}"
            echo "Alert Shown: $ALERT_SHOWN"
            echo ""
            echo "Current NVIDIA Status:"
            if check_nvidia; then
                echo "  ✓ Working"
            else
                echo "  ✗ Failed: $LAST_ERROR"
            fi
            ;;
            
        *)
            echo "Usage: $0 {check|fix|reset|status}"
            echo ""
            echo "Commands:"
            echo "  check   - Check GPU and attempt auto-fix (default, run at boot)"
            echo "  fix     - Manually attempt to fix GPU issues"
            echo "  reset   - Reset failure counter and clear alerts"
            echo "  status  - Show current auto-fix state"
            exit 1
            ;;
    esac
}

main "$@"
