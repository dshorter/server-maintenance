#!/usr/bin/env bash
# Host Safe Reboot Script
# Last updated: 2026-07-14
#
# Gates a reboot behind quiesce checks and a verified backup, then reboots
# WITHOUT stopping any containers. That is deliberate (decided 2026-07-14,
# after the first reboot through the overhauled backup pipeline):
#
#   - dockerd (no live-restore on this box) already delivers every
#     container's stop signal at shutdown, with a ~15s grace window;
#     everything stateful here (mysql, postgres, n8n's sqlite) is
#     crash-safe behind that.
#   - every container runs restart=unless-stopped, which only revives it
#     at boot if it was NOT manually stopped. An explicit stop here is
#     what strands the stack at next boot.
#   - the ghost pair is additionally owned by server-maintenance.service
#     (ExecStart: compose up -d ghost-mysql ghost), which restarts it at
#     boot regardless.
#
# If a future service needs pre-reboot quiescing, add a wait_* guard like
# wait_for_executions below — do not reintroduce a blanket container stop.
set -euo pipefail

PROJECT_DIR="/opt/server-maintenance"
DATA_DIR="/root/n8n-data"
BACKUP_SCRIPT="$PROJECT_DIR/scripts/backup.sh"
LOG_FILE="/var/log/safe-reboot.log"
NOTIFY="/usr/local/sbin/notify-telegram"
MAX_WAIT_SECONDS=300  # 5 minutes max wait for active executions
PREDICTOR_LOCK="/app/data/pipeline.lock"
PREDICTOR_LOCK_WAIT=120  # 2 minutes max wait for predictor pipeline

log() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" | tee -a "$LOG_FILE"
    logger -t safe-reboot "$*"
}

error() {
    log "ERROR: $*"
    # An aborted reboot must never be silent. notify-telegram always
    # exits 0, so paging can't mask the abort itself.
    if [[ -x "$NOTIFY" ]]; then
        "$NOTIFY" safe-reboot "Reboot ABORTED: $*" || true
    fi
    exit 1
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
    fi
}

check_tools() {
    local missing=()
    for tool in docker jq curl; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}"
    fi
}

preflight() {
    log "Running preflight checks..."

    require_root
    check_tools

    [[ -d "$PROJECT_DIR" ]] || error "Project directory missing: $PROJECT_DIR"
    [[ -d "$DATA_DIR" ]] || error "Data directory missing: $DATA_DIR"
    [[ -x "$BACKUP_SCRIPT" ]] || error "Backup script missing or not executable: $BACKUP_SCRIPT"

    log "✓ Preflight checks passed"
}

check_n8n_health() {
    log "Checking n8n health..."

    if docker ps --filter "name=^n8n$" --filter "status=running" | grep -q n8n; then
        if curl -sf http://localhost:5678/healthz >/dev/null 2>&1; then
            log "✓ n8n is healthy"
            return 0
        else
            log "WARNING: n8n container running but health check failed"
            return 1
        fi
    else
        log "WARNING: n8n container not running"
        return 1
    fi
}

wait_for_executions() {
    log "Checking for active n8n executions..."

    local elapsed=0
    local active_count

    while [[ $elapsed -lt $MAX_WAIT_SECONDS ]]; do
        # Try to get active execution count via API or docker exec
        if active_count=$(docker exec n8n n8n execute:list --status=running --json 2>/dev/null | jq '. | length' 2>/dev/null); then
            if [[ "$active_count" -eq 0 ]]; then
                log "✓ No active executions - safe to proceed"
                return 0
            fi
            log "Waiting for $active_count active execution(s)... ($elapsed/$MAX_WAIT_SECONDS seconds elapsed)"
        else
            log "WARNING: Could not check execution status, proceeding after grace period"
            sleep 10
            return 0
        fi

        sleep 10
        elapsed=$((elapsed + 10))
    done

    log "WARNING: Timeout waiting for executions. Proceeding anyway (some data loss may occur)"
    return 1
}

wait_for_predictor_pipeline() {
    log "Checking for active predictor pipeline..."

    local elapsed=0

    while [[ $elapsed -lt $PREDICTOR_LOCK_WAIT ]]; do
        if docker exec predictor-pipeline test -f "$PREDICTOR_LOCK" 2>/dev/null; then
            log "Predictor pipeline is running... ($elapsed/$PREDICTOR_LOCK_WAIT seconds elapsed)"
            sleep 10
            elapsed=$((elapsed + 10))
        else
            log "✓ No active predictor pipeline"
            return 0
        fi
    done

    log "WARNING: Timeout waiting for predictor pipeline. Proceeding anyway"
    return 1
}

export_status() {
    log "Exporting current status (all containers, all compose projects)..."

    docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Label "com.docker.compose.project"}}' \
        | tee -a "$LOG_FILE" || true

    log "n8n container logs (last 30 lines):"
    docker logs --tail=30 n8n 2>&1 | tee -a "$LOG_FILE" || true
}

run_backup() {
    log "Running backup script (output below; reboot aborts on failure)..."

    # Tee the backup output into this log: this run gates the reboot, and
    # it is invoked directly (not via backup.service), so nothing else
    # persists it. pipefail makes the if-guard see backup.sh's own exit.
    if ! "$BACKUP_SCRIPT" 2>&1 | tee -a "$LOG_FILE"; then
        error "Backup failed - ABORTING REBOOT to prevent data loss"
    fi

    log "✓ Backup completed successfully"
}

quiesce() {
    log "Beginning pre-reboot quiesce (containers stay running — see header)..."

    export_status
    check_n8n_health || log "WARNING: n8n health check failed before reboot"
    wait_for_executions
    wait_for_predictor_pipeline
    run_backup
}

sync_disks() {
    log "Syncing filesystems..."
    sync
    sleep 2  # Give kernel time to flush
    log "✓ Filesystems synced"
}

reboot_now() {
    log "════════════════════════════════════════════════════════"
    log "INITIATING SYSTEM REBOOT"
    log "════════════════════════════════════════════════════════"

    # Try systemctl first, fallback to shutdown
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reboot
    else
        shutdown -r now
    fi
}

# Signal handlers for clean interruption
trap 'log "Script interrupted - cleanup may be incomplete!"; exit 130' INT TERM

### MAIN ###
main() {
    log "════════════════════════════════════════════════════════"
    log "Host Safe Reboot - Starting"
    log "════════════════════════════════════════════════════════"

    preflight
    quiesce
    sync_disks
    reboot_now
}

main "$@"
