 #!/usr/bin/env bash
# AI Agent Platform Safe Reboot - Installation Script
# Created: 2025-10-14
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEMD_DIR="$(cd "$SCRIPT_DIR/../systemd" && pwd)"
DOCKER_DIR="$(cd "$SCRIPT_DIR/../docker" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

log() { 
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "/var/log/agent-platform-install.log"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root (use sudo)"
        exit 1
    fi
}

backup_if_exists() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.backup.${TIMESTAMP}"
        log "Backing up existing file: $file -> $backup"
        cp "$file" "$backup"
    fi
}

validate_files() {
    local missing=()
    
    [[ -f "$SCRIPT_DIR/usr_local_sbin_safe-reboot.sh" ]] || missing+=("safe-reboot.sh")
    [[ -f "$SCRIPT_DIR/usr_local_sbin_agent-platform-health.sh" ]] || missing+=("agent-platform-health.sh")
    [[ -f "$SYSTEMD_DIR/etc_systemd_system_ai-agent-platform.service" ]] || missing+=("ai-agent-platform.service")
    [[ -f "$SYSTEMD_DIR/etc_systemd_system_agent-platform-health.service" ]] || missing+=("agent-platform-health.service")
    [[ -f "$SYSTEMD_DIR/etc_systemd_system_agent-platform-health.timer" ]] || missing+=("agent-platform-health.timer")
    [[ -f "$SYSTEMD_DIR/etc_systemd_system_docker-prune.service" ]] || missing+=("docker-prune.service")
    [[ -f "$SYSTEMD_DIR/etc_systemd_system_docker-prune.timer" ]] || missing+=("docker-prune.timer")
    [[ -f "$DOCKER_DIR/daemon.json" ]] || missing+=("docker/daemon.json")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required files:"
        printf '  - %s\n' "${missing[@]}"
        exit 1
    fi
    
    log "All required files found"
}

install_scripts() {
    log "Installing scripts to /usr/local/sbin..."
    
    backup_if_exists "/usr/local/sbin/safe-reboot"
    backup_if_exists "/usr/local/sbin/agent-platform-health"
    
    install -m 0755 "$SCRIPT_DIR/usr_local_sbin_safe-reboot.sh" /usr/local/sbin/safe-reboot
    install -m 0755 "$SCRIPT_DIR/usr_local_sbin_agent-platform-health.sh" /usr/local/sbin/agent-platform-health
    
    log "Scripts installed successfully"
}

install_systemd_units() {
    log "Installing systemd units..."
    
    backup_if_exists "/etc/systemd/system/ai-agent-platform.service"
    backup_if_exists "/etc/systemd/system/agent-platform-health.service"
    backup_if_exists "/etc/systemd/system/agent-platform-health.timer"
    backup_if_exists "/etc/systemd/system/docker-prune.service"
    backup_if_exists "/etc/systemd/system/docker-prune.timer"

    install -m 0644 "$SYSTEMD_DIR/etc_systemd_system_ai-agent-platform.service" \
        /etc/systemd/system/ai-agent-platform.service
    install -m 0644 "$SYSTEMD_DIR/etc_systemd_system_agent-platform-health.service" \
        /etc/systemd/system/agent-platform-health.service
    install -m 0644 "$SYSTEMD_DIR/etc_systemd_system_agent-platform-health.timer" \
        /etc/systemd/system/agent-platform-health.timer
    install -m 0644 "$SYSTEMD_DIR/etc_systemd_system_docker-prune.service" \
        /etc/systemd/system/docker-prune.service
    install -m 0644 "$SYSTEMD_DIR/etc_systemd_system_docker-prune.timer" \
        /etc/systemd/system/docker-prune.timer

    log "Systemd units installed successfully"
}

install_docker_hygiene() {
    log "Installing Docker daemon hygiene config..."

    local target="/etc/docker/daemon.json"
    local source="$DOCKER_DIR/daemon.json"
    local restart_needed=0

    mkdir -p /etc/docker

    if [[ -f "$target" ]] && cmp -s "$source" "$target"; then
        log "daemon.json unchanged — skipping restart"
    else
        backup_if_exists "$target"
        install -m 0644 "$source" "$target"
        restart_needed=1
        log "daemon.json installed"
    fi

    if [[ "$restart_needed" -eq 1 ]]; then
        log "Restarting docker.service to apply daemon.json..."
        systemctl restart docker.service
        log "docker.service restarted"
    fi
}

configure_systemd() {
    log "Configuring systemd..."
    
    systemctl daemon-reload
    
    # Enable services
    systemctl enable ai-agent-platform.service
    systemctl enable agent-platform-health.service
    systemctl enable agent-platform-health.timer
    systemctl enable docker-prune.timer

    # Start the timers (health check + weekly prune)
    systemctl start agent-platform-health.timer
    systemctl start docker-prune.timer

    log "Systemd configuration complete"
}

verify_installation() {
    log "Verifying installation..."
    
    # Check if scripts are executable
    [[ -x /usr/local/sbin/safe-reboot ]] || {
        echo "ERROR: safe-reboot is not executable"
        exit 1
    }
    [[ -x /usr/local/sbin/agent-platform-health ]] || {
        echo "ERROR: agent-platform-health is not executable"
        exit 1
    }
    
    # Check systemd units
    systemctl is-enabled ai-agent-platform.service >/dev/null || {
        echo "ERROR: ai-agent-platform.service is not enabled"
        exit 1
    }
    systemctl is-active agent-platform-health.timer >/dev/null || {
        echo "ERROR: agent-platform-health.timer is not active"
        exit 1
    }
    systemctl is-active docker-prune.timer >/dev/null || {
        echo "ERROR: docker-prune.timer is not active"
        exit 1
    }
    [[ -f /etc/docker/daemon.json ]] || {
        echo "ERROR: /etc/docker/daemon.json not installed"
        exit 1
    }

    log "✓ All checks passed"
}

show_status() {
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "  Installation Complete!"
    echo "════════════════════════════════════════════════════════"
    echo ""
    echo "Scripts installed:"
    echo "  • /usr/local/sbin/safe-reboot"
    echo "  • /usr/local/sbin/agent-platform-health"
    echo ""
    echo "Systemd services:"
    echo "  • ai-agent-platform.service (enabled)"
    echo "  • agent-platform-health.service (enabled)"
    echo "  • agent-platform-health.timer (enabled and running)"
    echo "  • docker-prune.timer (enabled and running, weekly Sun 03:00)"
    echo ""
    echo "Docker daemon config:"
    echo "  • /etc/docker/daemon.json (log rotation + builder GC)"
    echo ""
    echo "Usage:"
    echo "  • Safe reboot:     sudo safe-reboot"
    echo "  • Manual health:   sudo agent-platform-health"
    echo "  • Check status:    systemctl status agent-platform-health.timer"
    echo "  • View logs:       journalctl -u agent-platform-health.service"
    echo ""
    echo "Next steps:"
    echo "  1. Verify your /opt/server-maintenance directory exists"
    echo "  2. Ensure your backup script is at /opt/server-maintenance/scripts/backup.sh"
    echo "  3. Test with: sudo safe-reboot"
    echo ""
    echo "════════════════════════════════════════════════════════"
}

main() {
    log "Starting AI Agent Platform installation..."
    
    check_root
    validate_files
    install_scripts
    install_systemd_units
    install_docker_hygiene
    configure_systemd
    verify_installation
    show_status
    
    log "Installation completed successfully"
}

main "$@"