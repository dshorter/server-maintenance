#!/usr/bin/env bash
# Host Safe Reboot Script
# Last updated: 2026-09-07
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
# If a future service needs pre-reboot quiescing, add it to QUIESCE_UNITS
# below — do not reintroduce a blanket container stop.
#
# 2026-09-07 — what the estate's scheduled work moved to, and what that
# broke here. This script used to quiesce the predictor by exec'ing into the
# `predictor-pipeline` container and testing for a lock file. That container
# exited in March 2026 and has not run since, so `docker exec` fails, the
# guard takes its own else-branch, and it reports "no active pipeline"
# without ever having looked. It has been a no-op for roughly six months.
#
# Meanwhile the real work moved onto the host as systemd timers, and there
# are now several of them: the predictor's three daily domains (a `make
# daily` per domain — the film run on 2026-09-07 held the box from 06:00 to
# 06:53 and spent $1.70), the Scout's paid prospecting pass, the sysadmin
# reconciliation pass, the Director's morning brief. None of them were
# checked. A reboot landing inside any one kills paid work mid-flight.
#
# So the guard is now unit-based and the list is data: a new timer is a new
# line in QUIESCE_UNITS, not new code. It waits, and on timeout it WARNS and
# proceeds — the only thing that aborts a reboot is a failed backup.
set -euo pipefail

PROJECT_DIR="/opt/server-maintenance"
DATA_DIR="/root/n8n-data"
BACKUP_SCRIPT="$PROJECT_DIR/scripts/backup.sh"
LOG_FILE="/var/log/safe-reboot.log"
NOTIFY="/usr/local/sbin/notify-telegram"
MAX_WAIT_SECONDS=300  # 5 minutes max wait for active executions

# Scheduled work that costs money or moves durable state. Killing one of
# these mid-run wastes a paid call; for the Scout it also abandons a walk
# whose cursor only advances on persisted jewels, so the loss is the spend,
# not the coverage. Instance units are listed per instance on purpose —
# `systemctl is-active` does not glob.
QUIESCE_UNITS=(
    "predictor-daily@film.service"
    "predictor-daily@semiconductors.service"
    "predictor-daily@weapons_detection.service"
    "predictor-staleness.service"
    "scout-pass.service"
    "sysadmin-daily.service"
    "director-morning-brief.service"
    "backup.service"
)
# The film domain has run to 53 minutes. This is deliberately shorter: past
# 20 minutes a human is waiting at a terminal, and proceeding costs one
# re-run of a job that is idempotent by the next timer anyway.
AGENT_WAIT_SECONDS="${SAFE_REBOOT_AGENT_WAIT:-1200}"

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
    for tool in docker jq curl systemctl; do
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

# KNOWN GAP, measured 2026-09-07: there is no working probe here.
#
# This asked `n8n execute:list --status=running`, a subcommand this n8n does
# not have — its CLI offers execute, execute-batch and list:workflow, and no
# way to enumerate running executions. So the probe has always failed, always
# taken the else-branch, slept 10 seconds and reported success. Together with
# the predictor guard (dead container, see the header) that made BOTH of this
# script's quiesce waits no-ops: the whole wait was a 10-second sleep.
#
# It is left in place, and left loud. Closing it properly means either an
# n8n API key for /api/v1/executions?status=running or a read of n8n's
# sqlite, and picking between those is a decision, not a detail — see
# TODO.md. What changed today is that a missing probe now says so every run
# instead of printing a checkmark.
wait_for_executions() {
    log "Checking for active n8n executions..."

    local active_count
    if active_count=$(docker exec n8n n8n execute:list --status=running --json 2>/dev/null | jq '. | length' 2>/dev/null) \
       && [[ -n "$active_count" ]]; then
        local elapsed=0
        while [[ $elapsed -lt $MAX_WAIT_SECONDS ]]; do
            if [[ "$active_count" -eq 0 ]]; then
                log "✓ No active executions - safe to proceed"
                return 0
            fi
            log "Waiting for $active_count active execution(s)... ($elapsed/$MAX_WAIT_SECONDS seconds elapsed)"
            sleep 10
            elapsed=$((elapsed + 10))
            active_count=$(docker exec n8n n8n execute:list --status=running --json 2>/dev/null | jq '. | length' 2>/dev/null) || break
        done
        log "WARNING: Timeout waiting for executions. Proceeding anyway (some data loss may occur)"
        return 1
    fi

    log "WARNING: n8n execution probe UNAVAILABLE (no running-execution query in this n8n CLI)."
    log "WARNING: n8n is NOT being quiesced — rebooting may interrupt a running workflow."
    return 1
}

# Which of QUIESCE_UNITS are running right now. A unit that does not exist
# on this box is simply not active, which is the answer we want — this list
# is shared across a changing estate and a missing unit is not an error.
active_agent_units() {
    local unit active=()
    for unit in "${QUIESCE_UNITS[@]}"; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            active+=("$unit")
        fi
    done
    printf '%s\n' "${active[@]:-}"
}

wait_for_agent_units() {
    log "Checking for scheduled agent work in flight..."

    local elapsed=0 running
    while [[ $elapsed -lt $AGENT_WAIT_SECONDS ]]; do
        mapfile -t running < <(active_agent_units)
        # mapfile over an empty printf yields one empty element, not zero.
        if [[ ${#running[@]} -eq 0 || -z "${running[0]}" ]]; then
            log "✓ No scheduled agent work running - safe to proceed"
            return 0
        fi
        log "Waiting for ${running[*]}... ($elapsed/$AGENT_WAIT_SECONDS seconds elapsed)"
        sleep 15
        elapsed=$((elapsed + 15))
    done

    mapfile -t running < <(active_agent_units)
    log "WARNING: Timeout waiting for: ${running[*]}. Proceeding — paid work may be lost"
    [[ -x "$NOTIFY" ]] && "$NOTIFY" safe-reboot \
        "Rebooting with agent work still running: ${running[*]}" || true
    return 1
}

export_status() {
    log "Exporting current status (all containers, all compose projects)..."

    docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Label "com.docker.compose.project"}}' \
        | tee -a "$LOG_FILE" || true

    log "Scheduled units and their last result:"
    systemctl list-timers --all --no-pager 2>/dev/null | tee -a "$LOG_FILE" || true

    log "Any agent unit currently in a failed state:"
    systemctl list-units --state=failed --no-pager 2>/dev/null | tee -a "$LOG_FILE" || true

    log "n8n container logs (last 30 lines):"
    docker logs --tail=30 n8n 2>&1 | tee -a "$LOG_FILE" || true
}

run_backup() {
    # backup.timer fires at 03:30 and backup.sh takes no lock of its own, so
    # a reboot run near that hour could put two of them on the same staging
    # directory and the same B2 prune. wait_for_agent_units already waited
    # for backup.service; this is the last-moment re-check.
    if systemctl is-active --quiet backup.service 2>/dev/null; then
        error "backup.service is running — refusing to start a second backup"
    fi

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
    # Both waiters return 1 on timeout, and both are advisory: the timeout
    # has already been logged and paged. They MUST be called with `|| true`.
    # Bare, `set -e` unwinds quiesce and main on that 1, so the script exits
    # before run_backup — no backup, no reboot, and no page either, because
    # error() is never reached. A silent no-op that looks like a reboot.
    # (Latent since 2026-07-14; found 2026-09-07 while adding the second
    # waiter, which would have doubled the ways to trip it.)
    wait_for_executions || true
    wait_for_agent_units || true
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
# --check runs every read-only part — preflight, the status export, the
# health check and both waiters — and stops before the backup and the
# reboot. It exists because a reboot script that cannot be rehearsed is a
# script nobody ever verifies: this one's predictor guard was dead for six
# months and its `set -e` trap latent for two, and neither was findable
# without running the real thing. Safe to run any time, including from the
# health timer.
main() {
    local mode="${1:-reboot}"

    case "$mode" in
        --check)
            log "════════════════════════════════════════════════════════"
            log "Host Safe Reboot - CHECK ONLY (no backup, no reboot)"
            log "════════════════════════════════════════════════════════"
            preflight
            export_status
            check_n8n_health || log "WARNING: n8n health check failed"
            wait_for_executions || true
            wait_for_agent_units || true
            if systemctl is-active --quiet backup.service 2>/dev/null; then
                log "WARNING: backup.service is running — a real run would refuse"
            fi
            log "✓ Check complete. A real run would now back up, then reboot."
            ;;
        reboot)
            log "════════════════════════════════════════════════════════"
            log "Host Safe Reboot - Starting"
            log "════════════════════════════════════════════════════════"
            preflight
            quiesce
            sync_disks
            reboot_now
            ;;
        *)
            echo "usage: safe-reboot [--check]" >&2
            exit 2
            ;;
    esac
}

main "$@"
