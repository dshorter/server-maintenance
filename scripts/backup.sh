#!/bin/bash
# Server Maintenance Backup Script
# Backs up: n8n data, system config, predictor databases & extractions
set -euo pipefail

# Staging lives OUTSIDE /root/n8n-data on purpose (moved 2026-07-02): that
# dir is mounted into the n8n container as /data/backups, which let a
# compromised n8n read every dump and delete all local backups. Root-only 700.
BACKUP_DIR="/var/backups/host"
# n8n can only write exports inside its own mount; each run's export is moved
# into $BACKUP_DIR immediately after.
N8N_EXPORT_DIR="/root/n8n-data/backups"
SYSTEM_BACKUP_DIR="$BACKUP_DIR/system"
PREDICTOR_BACKUP_DIR="$BACKUP_DIR/predictor"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

# Warnings are counted so the end of the run can page the operator once via
# Telegram — backup.service exits 0 on warnings, so OnFailure= alone would
# never catch a broken off-site upload (that's how June 2026 went silent).
WARN_COUNT=0
warn() { WARN_COUNT=$((WARN_COUNT+1)); log "WARNING: $*"; }

log "Starting backup at $TIMESTAMP"

# Create backup directories
mkdir -p "$BACKUP_DIR" "$SYSTEM_BACKUP_DIR" "$PREDICTOR_BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# ── n8n backups (original) ────────────────────────────────────────

log "Backing up n8n workflows..."
docker exec n8n n8n export:workflow --all \
    --output=/data/backups/workflows_$TIMESTAMP.json 2>/dev/null || \
    warn "n8n workflow export failed (container may be stopped)"
if [ -f "$N8N_EXPORT_DIR/workflows_$TIMESTAMP.json" ]; then
    mv "$N8N_EXPORT_DIR/workflows_$TIMESTAMP.json" "$BACKUP_DIR/" || \
        warn "could not move n8n workflow export into staging"
fi

if [ -d "/root/n8n-data/transactions" ]; then
    log "Backing up n8n transaction data..."
    tar -czf "$BACKUP_DIR/transactions_$TIMESTAMP.tar.gz" \
        -C /root/n8n-data transactions/
fi

if [ -f "/root/n8n-data/database.sqlite" ]; then
    log "Backing up n8n database..."
    # sqlite3 .backup captures WAL contents and gives a consistent snapshot;
    # plain cp of a live DB can miss recent writes sitting in the -wal file.
    if command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 /root/n8n-data/database.sqlite \
            ".backup '$BACKUP_DIR/database_$TIMESTAMP.sqlite'" 2>/dev/null || \
            cp /root/n8n-data/database.sqlite "$BACKUP_DIR/database_$TIMESTAMP.sqlite"
    else
        cp /root/n8n-data/database.sqlite "$BACKUP_DIR/database_$TIMESTAMP.sqlite"
    fi
fi

# ── System config backups ─────────────────────────────────────────

log "Backing up Caddy config..."
cp /etc/caddy/Caddyfile "$SYSTEM_BACKUP_DIR/Caddyfile_$TIMESTAMP"

# Merged from the retired ai-agent-platform cron script: /var/lib/caddy holds
# LE certs + ACME account state (re-issuable, but rate-limited). Contains
# private keys, so keep it 600.
log "Backing up Caddy TLS state (/var/lib/caddy)..."
if tar -czf "$SYSTEM_BACKUP_DIR/caddy_state_$TIMESTAMP.tar.gz" \
        -C / etc/caddy var/lib/caddy 2>/dev/null; then
    chmod 600 "$SYSTEM_BACKUP_DIR/caddy_state_$TIMESTAMP.tar.gz"
else
    warn "caddy TLS state backup failed"
fi

log "Backing up UFW firewall rules..."
tar -czf "$SYSTEM_BACKUP_DIR/ufw_$TIMESTAMP.tar.gz" -C /etc ufw/

log "Backing up systemd units..."
# Capture all real *.service / *.timer files at top of /etc/systemd/system,
# skipping .backup.* snapshots and the package-managed subdirectories.
( cd /etc/systemd/system && \
    find . -maxdepth 1 \( -name '*.service' -o -name '*.timer' \) \
        ! -name '*.backup.*' -print0 \
    | tar -czf "$SYSTEM_BACKUP_DIR/systemd_units_$TIMESTAMP.tar.gz" --null -T - \
) 2>/dev/null || warn "systemd units backup failed"

log "Backing up /usr/local/sbin scripts..."
tar -czf "$SYSTEM_BACKUP_DIR/usr_local_sbin_$TIMESTAMP.tar.gz" \
    -C /usr/local/sbin \
    --exclude='*.backup.*' \
    agent-platform-health safe-reboot notify-telegram 2>/dev/null || \
    warn "/usr/local/sbin scripts backup failed"

# notify-telegram config holds the bot token — 600, same handling as .env.
log "Backing up notify-telegram config..."
if [ -f /etc/default/notify-telegram ]; then
    cp /etc/default/notify-telegram "$SYSTEM_BACKUP_DIR/notify_telegram_conf_$TIMESTAMP" && \
        chmod 600 "$SYSTEM_BACKUP_DIR/notify_telegram_conf_$TIMESTAMP" || \
        warn "notify-telegram config backup failed"
fi

# ── Critical items previously missing from the backup set ────────

# n8n encryption key: without this file every credential in database.sqlite
# is unrecoverable ciphertext. It only ever existed live + in the off-site
# bundle before; keep a local copy too.
log "Backing up n8n encryption key/config..."
if [ -f /root/n8n-data/config ]; then
    cp /root/n8n-data/config "$SYSTEM_BACKUP_DIR/n8n_config_$TIMESTAMP" && \
        chmod 600 "$SYSTEM_BACKUP_DIR/n8n_config_$TIMESTAMP" || \
        warn "n8n config backup failed"
else
    warn "/root/n8n-data/config not found"
fi

# sshd config + host keys (host keys avoid MITM warnings after a rebuild).
log "Backing up /etc/ssh..."
if tar -czf "$SYSTEM_BACKUP_DIR/etc_ssh_$TIMESTAMP.tar.gz" -C /etc ssh/ 2>/dev/null; then
    chmod 600 "$SYSTEM_BACKUP_DIR/etc_ssh_$TIMESTAMP.tar.gz"
else
    warn "/etc/ssh backup failed"
fi

# Compose secrets (.env: GHOST_MYSQL_ROOT_PASSWORD, NGROK_AUTHTOKEN, ...).
log "Backing up compose .env..."
if [ -f /opt/server-maintenance/.env ]; then
    cp /opt/server-maintenance/.env "$SYSTEM_BACKUP_DIR/compose_env_$TIMESTAMP" && \
        chmod 600 "$SYSTEM_BACKUP_DIR/compose_env_$TIMESTAMP" || \
        warn "compose .env backup failed"
fi

log "Backing up root crontab..."
crontab -l > "$SYSTEM_BACKUP_DIR/crontab_root_$TIMESTAMP" 2>/dev/null || \
    warn "root crontab backup failed"

log "Backing up package selections..."
dpkg --get-selections > "$SYSTEM_BACKUP_DIR/dpkg_selections_$TIMESTAMP" 2>/dev/null || \
    warn "dpkg selections backup failed"

log "Backing up misc /etc files (fstab, hosts, docker daemon.json)..."
for f in /etc/fstab /etc/hosts /etc/docker/daemon.json; do
    [ -f "$f" ] || continue
    cp "$f" "$SYSTEM_BACKUP_DIR/$(echo "${f#/}" | tr / _)_$TIMESTAMP" || \
        warn "backup of $f failed"
done

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

# ── Ghost blog backups ────────────────────────────────────────────

GHOST_BACKUP_DIR="$BACKUP_DIR/ghost"

if docker ps --format '{{.Names}}' | grep -q '^ghost-mysql$'; then
    mkdir -p "$GHOST_BACKUP_DIR"

    log "Backing up Ghost MySQL..."
    # Load password from .env if present (same dir pattern as docker-compose)
    if [ -f "/opt/server-maintenance/.env" ]; then
        set -a; . /opt/server-maintenance/.env; set +a
    fi

    if [ -n "${GHOST_MYSQL_ROOT_PASSWORD:-}" ]; then
        docker exec ghost-mysql mysqldump \
            -uroot -p"$GHOST_MYSQL_ROOT_PASSWORD" \
            --single-transaction --quick ghost_prod \
            2>/dev/null | gzip > "$GHOST_BACKUP_DIR/ghost_db_$TIMESTAMP.sql.gz" || \
            warn "ghost mysqldump failed"
    else
        warn "GHOST_MYSQL_ROOT_PASSWORD not set — skipping ghost db dump"
    fi

    log "Backing up Ghost content volume..."
    # NOTE: real volume is server-maintenance_ghost-content (compose project prefix).
    # An orphan anonymous `ghost-content` volume also exists but is unused.
    docker run --rm \
        -v server-maintenance_ghost-content:/src:ro \
        -v "$GHOST_BACKUP_DIR":/dst \
        alpine \
        tar -czf "/dst/ghost_content_$TIMESTAMP.tar.gz" -C /src . \
        2>/dev/null || warn "ghost content backup failed"
fi

# ── Postgres (hvac-postgres) ──────────────────────────────────────
# Dumps ALL databases in the hvac-postgres container: hvac_demo (demo data)
# and ai_agent_platform (agent_decisions / pipeline_runs / posts — the
# agents' history). The postgres data volume is not captured anywhere else;
# without this dump a restore loses every row.

PG_BACKUP_DIR="$BACKUP_DIR/postgres"

if docker ps --format '{{.Names}}' | grep -q '^hvac-postgres$'; then
    mkdir -p "$PG_BACKUP_DIR"
    log "Backing up Postgres (pg_dumpall: hvac_demo + ai_agent_platform)..."
    docker exec hvac-postgres pg_dumpall -U hvac_user 2>/dev/null \
        | gzip > "$PG_BACKUP_DIR/postgres_all_$TIMESTAMP.sql.gz" || \
        warn "postgres pg_dumpall failed"
else
    warn "hvac-postgres not running — skipping postgres dump"
fi

# ── Retention ─────────────────────────────────────────────────────

log "Cleaning up backups older than 14 days..."
find "$BACKUP_DIR" -type f -mtime +14 -delete
# Stragglers in the n8n-visible export dir (normally moved out same-run)
find "$N8N_EXPORT_DIR" -maxdepth 1 -type f -name 'workflows_*.json' -mtime +14 -delete 2>/dev/null || true

# ── Off-site upload to B2 (via rclone) ────────────────────────────
#
# Streams everything in $BACKUP_DIR + a curated set of /opt + /etc paths
# straight to the remote — nothing extra hits local disk. Skipped silently
# if BACKUP_OFFSITE_REMOTE is unset, so the script stays usable while B2
# creds are being set up.
#
# To enable: set BACKUP_OFFSITE_REMOTE in the systemd unit, e.g.
#   Environment=BACKUP_OFFSITE_REMOTE=b2:uzelhub-backups

# Default to the project bucket so direct invocations (e.g. from safe-reboot)
# get off-site coverage too — not just the scheduled systemd unit. Override
# with BACKUP_OFFSITE_REMOTE= (empty) to force local-only.
OFFSITE_REMOTE="${BACKUP_OFFSITE_REMOTE-b2:uzelhub-backups}"
if [ -n "$OFFSITE_REMOTE" ] && command -v rclone >/dev/null 2>&1; then
    HOST_SHORT=$(hostname -s)
    OFFSITE_PATH="$OFFSITE_REMOTE/$HOST_SHORT/$(date +%Y/%m)/host-$TIMESTAMP.tar.gz"

    # Prune remote bundles older than 8 days BEFORE uploading. The bucket's
    # lifecycle rule (daysFromHidingToDeleting) never fires for us: each
    # bundle is a unique filename that is never hidden, so B2 keeps it
    # forever — that's how we hit the account storage cap in June 2026.
    # --b2-hard-delete frees space immediately instead of leaving hidden
    # versions that still count against the cap for another 7 days.
    # min-age is 8d (not 7d) because the bucket has Object Lock with a 7-day
    # default retention (governance mode, added 2026-07-03): deleting a
    # still-locked file fails, so we only prune files whose lock has expired.
    # The newest week of bundles is therefore immutable even to this key.
    log "Pruning off-site bundles older than 8 days..."
    rclone --config /root/.config/rclone/rclone.conf \
        delete --min-age 8d --b2-hard-delete "$OFFSITE_REMOTE/$HOST_SHORT" 2>/dev/null || \
        warn "off-site prune failed"

    # The blanket --exclude='backups' below drops the whole 14-day staging
    # dir (multi-GB) from the bundle — which also dropped every DB dump:
    # bundles uploaded before 2026-06-10 contain NO dumps despite the
    # restore docs saying otherwise. Hardlink just *this run's* artifacts
    # into a sibling dir (not named "backups") so they ride along.
    OFFSITE_DUMPS_DIR="/root/n8n-data/offsite-dumps-$TIMESTAMP"
    rm -rf /root/n8n-data/offsite-dumps-*    # stale dirs from crashed runs
    mkdir -p "$OFFSITE_DUMPS_DIR"
    find "$BACKUP_DIR" -type f -name "*${TIMESTAMP}*" \
        -exec ln {} "$OFFSITE_DUMPS_DIR/" \; 2>/dev/null || \
        warn "could not stage this run's dumps for off-site"

    log "Uploading off-site bundle to $OFFSITE_PATH ..."

    # Use pipefail (set above) so tar failures propagate even through the pipe.
    if tar -czf - \
        --warning=no-file-changed \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='__pycache__' \
        --exclude='.ragvenv*' \
        --exclude='*.zip' \
        --exclude='backups' \
        -C / \
            opt/_host \
            opt/server-maintenance \
            opt/uzelhub-web \
            opt/predictor_ingest \
            opt/ai-agent-platform \
            opt/rag_pipeline/data \
            root/n8n-data \
            etc/caddy \
        2>>/tmp/backup-tar-$TIMESTAMP.err \
        | rclone --config /root/.config/rclone/rclone.conf \
                 rcat "$OFFSITE_PATH" 2>>/tmp/backup-tar-$TIMESTAMP.err
    then
        log "Off-site upload complete."
        rm -f /tmp/backup-tar-$TIMESTAMP.err
    else
        warn "off-site upload failed — see /tmp/backup-tar-$TIMESTAMP.err"
    fi
    rm -rf "$OFFSITE_DUMPS_DIR"
elif [ -n "$OFFSITE_REMOTE" ]; then
    warn "BACKUP_OFFSITE_REMOTE set but rclone not installed — skipping"
else
    log "BACKUP_OFFSITE_REMOTE not set — skipping off-site upload"
fi

# ── Summary ───────────────────────────────────────────────────────

log "Backup completed: $TIMESTAMP"
log "Backup sizes:"
du -sh "$BACKUP_DIR"/* 2>/dev/null | sed 's/^/  /'

# ── Failure-class Telegram page ───────────────────────────────────
# One message per run, only if something warned. backup.service exits 0 on
# warnings, so the systemd OnFailure= hook alone would miss exactly the
# failure mode that went silent for 3 weeks in June 2026 (off-site upload).
# Guarded so a Telegram problem can never fail the backup or block safe-reboot.
if [ "$WARN_COUNT" -gt 0 ] && command -v notify-telegram >/dev/null 2>&1; then
    notify-telegram BACKUP \
        "run $TIMESTAMP finished with $WARN_COUNT warning(s) on $(hostname -s) — check: journalctl -u backup.service" || true
fi
