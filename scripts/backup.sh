#!/bin/bash
# Server Maintenance Backup Script
# Backs up: n8n data, system config, predictor databases & extractions
set -euo pipefail

# Everything this script creates is root-only. Root's default umask (022) made
# the pg_dumpall / ghost dumps 644 — combined with staging inside the n8n
# mount, that left full DB dumps container-readable until 2026-07-11.
umask 077

# Staging lives OUTSIDE /root/n8n-data on purpose (moved 2026-07-02): that
# dir is mounted into the n8n container as /data/backups, which let a
# compromised n8n read every dump and delete all local backups. Root-only 700.
#
# Since 2026-10-26 it lives on the 70 GB volume instead of the 38 GB root
# disk, and /var/backups/host is a symlink to it, so every reader keeps its
# path. move-backups-to-volume.sh made the move; until it has run,
# /var/backups/host is still a real directory and is used as before. The
# volume mounts with nofail, so if it is missing the symlink dangles: write
# to a fallback directory on root and warn, since a backup on the wrong disk
# beats no backup.
#
# STAGE_PARENT holds the off-site staging dir. That step hard-links this
# run's files, and hard links can't cross filesystems, so it sits on the same
# disk as BACKUP_DIR.
BACKUP_VOLUME="/mnt/HC_Volume_103575430"
BACKUP_DIR="/var/backups/host"
STAGE_PARENT="/root"
VOLUME_MISSING=0
if [ -L "$BACKUP_DIR" ]; then
    if mountpoint -q "$BACKUP_VOLUME" && [ -d "$BACKUP_VOLUME/backups/host" ]; then
        BACKUP_DIR="$BACKUP_VOLUME/backups/host"
        STAGE_PARENT="$BACKUP_VOLUME/offsite-staging"
    else
        BACKUP_DIR="/var/backups/host-fallback"
        VOLUME_MISSING=1
    fi
fi
# n8n can only write exports inside its own mount; each run's export is moved
# into $BACKUP_DIR immediately after.
N8N_EXPORT_DIR="/root/n8n-data/backups"
SYSTEM_BACKUP_DIR="$BACKUP_DIR/system"
PREDICTOR_BACKUP_DIR="$BACKUP_DIR/predictor"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# pigz where available — the predictor snapshots are ~1 GB of SQLite per run
# and pigz uses every core instead of pinning one for minutes at 03:33.
# (Named COMPRESSOR, not GZIP: gzip reads GZIP from the environment.)
if command -v pigz >/dev/null 2>&1; then COMPRESSOR="pigz"; else COMPRESSOR="gzip"; fi

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

# Warnings are counted so the end of the run can page the operator once via
# Telegram — backup.service exits 0 on warnings, so OnFailure= alone would
# never catch a broken off-site upload (that's how June 2026 went silent).
WARN_COUNT=0
warn() { WARN_COUNT=$((WARN_COUNT+1)); log "WARNING: $*"; }

log "Starting backup at $TIMESTAMP"
[ "$VOLUME_MISSING" -eq 0 ] || \
    warn "backup volume $BACKUP_VOLUME is not mounted — writing to $BACKUP_DIR on the root disk instead"

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
    # Same reasoning as the predictor snapshots below — raw SQLite in a 14-day
    # staging window is the one thing here that was not already compressed.
    "$COMPRESSOR" "$BACKUP_DIR/database_$TIMESTAMP.sqlite" || \
        warn "could not compress n8n database snapshot — keeping it raw"
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
        snap="$PREDICTOR_BACKUP_DIR/${dbname}_$TIMESTAMP.db"
        # Use sqlite3 .backup for consistency if available, else cp
        if command -v sqlite3 >/dev/null 2>&1; then
            sqlite3 "$db" ".backup '$snap'" 2>/dev/null || cp "$db" "$snap"
        else
            cp "$db" "$snap"
        fi
        # Unchanged since the last snapshot? Keep one copy, not one a day.
        # sqlite3 .backup of an unchanged database is byte-identical (checked
        # 2026-10-20), and a paused domain's database stops changing: film's
        # was ~268 MB gzipped a day, 14 identical copies across the window.
        # The previous snapshot is renamed to this run's timestamp and touched,
        # so the 14-day retention below never ages out the only copy and the
        # off-site staging (which matches this run's timestamp) still picks
        # it up. .<db>.last records "<sha256> <file>" of the latest snapshot.
        lastfile="$PREDICTOR_BACKUP_DIR/.${dbname}.last"
        newsum=$(sha256sum "$snap" | cut -d' ' -f1)
        prevsum=""; prevfile=""
        if [ -f "$lastfile" ]; then
            read -r prevsum prevfile < "$lastfile" || true
        fi
        if [ -n "$prevsum" ] && [ "$prevsum" = "$newsum" ] && [ -n "$prevfile" ] \
            && [ -f "$PREDICTOR_BACKUP_DIR/$prevfile" ]; then
            rm -f "$snap"
            mv "$PREDICTOR_BACKUP_DIR/$prevfile" "$snap.gz"
            touch "$snap.gz"
            echo "$newsum $(basename "$snap.gz")" > "$lastfile"
            log "  unchanged: $dbname (same bytes as $prevfile; one copy kept, renamed to this run)"
            continue
        fi
        # Compress it. Every other artifact this script writes is already
        # gzipped; these snapshots were the only raw ones, and at ~0.7 GB/day
        # across the 14-day window they had reached 10.2 GB — a third of the
        # 38G root filesystem (audit 2026-09-03). SQLite gzips ~4.6x, so the
        # window costs ~2.2 GB instead. Restore is `gunzip -c x.db.gz > x.db`.
        #
        # A compression failure is a warning, not a failure: a raw snapshot is
        # still a good snapshot, and losing the backup to save disk would be
        # the wrong trade.
        if "$COMPRESSOR" "$snap"; then
            echo "$newsum $(basename "$snap.gz")" > "$lastfile"
            log "  backed up: $dbname ($(du -sh "$snap.gz" | cut -f1) gzipped)"
        else
            rm -f "$lastfile"
            warn "could not compress $snap — keeping it raw"
            log "  backed up: $dbname ($(du -sh "$snap" | cut -f1) UNCOMPRESSED)"
        fi
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
# Off-site bundles kept after a successful upload (operator, 2026-10-20: 4, was 7).
OFFSITE_KEEP_DAYS="${BACKUP_OFFSITE_KEEP_DAYS:-4}"
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
    # into a dir (not named "backups") that rides along in the tar.
    #
    # Staged in $STAGE_PARENT, on BACKUP_DIR's disk: /root while backups live
    # on root, the volume's offsite-staging dir once they live there. NOT
    # /root/n8n-data: all of n8n-data is mounted into the n8n container
    # (/home/node/.n8n), so dumps staged there were readable from inside the
    # container — the exact exposure the 2026-07-02 staging move was meant to
    # close. Never under a directory named backups either: tar's
    # --exclude='backups' matches that path component.
    OFFSITE_DUMPS_DIR="$STAGE_PARENT/offsite-dumps-$TIMESTAMP"
    # stale dirs from crashed runs, wherever staging has lived
    rm -rf /root/offsite-dumps-* /root/n8n-data/offsite-dumps-* \
        "$BACKUP_VOLUME"/offsite-staging/offsite-dumps-*
    mkdir -p "$OFFSITE_DUMPS_DIR"
    chmod 700 "$OFFSITE_DUMPS_DIR"
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
            var/lib/sysadmin-agent \
        -C "$STAGE_PARENT" "offsite-dumps-$TIMESTAMP" \
        2>>/tmp/backup-tar-$TIMESTAMP.err \
        | rclone --config /root/.config/rclone/rclone.conf \
                 rcat "$OFFSITE_PATH" 2>>/tmp/backup-tar-$TIMESTAMP.err
    then
        log "Off-site upload complete."
        rm -f /tmp/backup-tar-$TIMESTAMP.err

        # Keep $OFFSITE_KEEP_DAYS days off-site. This prune runs only after a
        # bundle has landed, so a run of failed uploads can never empty the
        # bucket; the 8-day prune above stays as the floor and still frees
        # space before each upload.
        #
        # Full effect needs the bucket's Object Lock default retention at
        # (keep days - 1) or less — 3 days for 4 — set in the B2 console.
        # Until then bundles 4-7 days old are still locked, this prune can't
        # remove them, and it says so in the log without paging; a real prune
        # failure (bad key, network) still pages through the 8-day prune.
        # A bundle keeps the lock it was uploaded with, so after the console
        # change the older 7-day locks take up to a week to run out.
        log "Pruning off-site bundles older than $OFFSITE_KEEP_DAYS days..."
        rclone --config /root/.config/rclone/rclone.conf --retries 1 \
            delete --min-age "${OFFSITE_KEEP_DAYS}d" --b2-hard-delete "$OFFSITE_REMOTE/$HOST_SHORT" 2>/dev/null || \
            log "  some bundles older than $OFFSITE_KEEP_DAYS days are still under Object Lock; the 8-day prune removes them"
    else
        # The error file lives in /tmp and a reboot wipes it (2026-10-20 lost
        # the only record of 27 failures in 50 days), so put its tail in the
        # journal too.
        warn "off-site upload failed — last lines of /tmp/backup-tar-$TIMESTAMP.err follow"
        tail -n 20 "/tmp/backup-tar-$TIMESTAMP.err" 2>/dev/null | sed 's/^/    /' || true
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
