#!/bin/bash
# Server Maintenance Backup Script
# Backs up: n8n data, system config, predictor databases & extractions
set -euo pipefail

BACKUP_DIR="/root/n8n-data/backups"
SYSTEM_BACKUP_DIR="$BACKUP_DIR/system"
PREDICTOR_BACKUP_DIR="$BACKUP_DIR/predictor"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

log "Starting backup at $TIMESTAMP"

# Create backup directories
mkdir -p "$BACKUP_DIR" "$SYSTEM_BACKUP_DIR" "$PREDICTOR_BACKUP_DIR"

# ── n8n backups (original) ────────────────────────────────────────

log "Backing up n8n workflows..."
docker exec n8n n8n export:workflow --all \
    --output=/data/backups/workflows_$TIMESTAMP.json 2>/dev/null || \
    log "WARNING: n8n workflow export failed (container may be stopped)"

if [ -d "/root/n8n-data/transactions" ]; then
    log "Backing up n8n transaction data..."
    tar -czf "$BACKUP_DIR/transactions_$TIMESTAMP.tar.gz" \
        -C /root/n8n-data transactions/
fi

if [ -f "/root/n8n-data/database.sqlite" ]; then
    log "Backing up n8n database..."
    cp /root/n8n-data/database.sqlite "$BACKUP_DIR/database_$TIMESTAMP.sqlite"
fi

# ── System config backups ─────────────────────────────────────────

log "Backing up Caddy config..."
cp /etc/caddy/Caddyfile "$SYSTEM_BACKUP_DIR/Caddyfile_$TIMESTAMP"

log "Backing up UFW firewall rules..."
tar -czf "$SYSTEM_BACKUP_DIR/ufw_$TIMESTAMP.tar.gz" -C /etc ufw/

log "Backing up systemd units..."
tar -czf "$SYSTEM_BACKUP_DIR/systemd_units_$TIMESTAMP.tar.gz" \
    -C /etc/systemd/system \
    ai-agent-platform.service \
    agent-platform-health.service \
    agent-platform-health.timer 2>/dev/null || \
    log "WARNING: Some systemd units not found"

# ── Predictor pipeline backups ────────────────────────────────────

PREDICTOR_DATA="/opt/predictor_ingest/data"

if [ -d "$PREDICTOR_DATA/db" ]; then
    log "Backing up predictor databases (SQLite safe copy)..."
    for db in "$PREDICTOR_DATA"/db/*.db; do
        [ -f "$db" ] || continue
        dbname=$(basename "$db" .db)
        # Use sqlite3 .backup for consistency if available, else cp
        if command -v sqlite3 >/dev/null 2>&1; then
            sqlite3 "$db" ".backup '$PREDICTOR_BACKUP_DIR/${dbname}_$TIMESTAMP.db'" 2>/dev/null || \
                cp "$db" "$PREDICTOR_BACKUP_DIR/${dbname}_$TIMESTAMP.db"
        else
            cp "$db" "$PREDICTOR_BACKUP_DIR/${dbname}_$TIMESTAMP.db"
        fi
        log "  backed up: $dbname ($(du -sh "$db" | cut -f1))"
    done
fi

if [ -d "$PREDICTOR_DATA/extractions" ]; then
    log "Backing up predictor extractions..."
    tar -czf "$PREDICTOR_BACKUP_DIR/extractions_$TIMESTAMP.tar.gz" \
        -C "$PREDICTOR_DATA" extractions/
fi

# ── Retention ─────────────────────────────────────────────────────

log "Cleaning up backups older than 14 days..."
find "$BACKUP_DIR" -type f -mtime +14 -delete

# ── Summary ───────────────────────────────────────────────────────

log "Backup completed: $TIMESTAMP"
log "Backup sizes:"
du -sh "$BACKUP_DIR"/* 2>/dev/null | sed 's/^/  /'
