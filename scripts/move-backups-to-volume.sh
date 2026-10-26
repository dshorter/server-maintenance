#!/usr/bin/env bash
# move-backups-to-volume.sh — move the local backups off the root disk onto
# the 70 GB volume, leaving /var/backups/host as a symlink to the new place.
#
#   sudo /opt/server-maintenance/scripts/move-backups-to-volume.sh --dry-run  # check, change nothing
#   sudo /opt/server-maintenance/scripts/move-backups-to-volume.sh
#
# Why (2026-10-26): the root disk reached 98%. /var/backups/host held about
# 8 GB of it, 7.1 GB of that predictor database snapshots, while the volume
# (Docker's data-root) sat at 12% of 70 GB. Moving frees the root disk and
# keeps all 14 days of local history. That history matters while off-site
# uploads fail on the B2 storage cap: on those days local is the only copy.
#
# Steps: copy to <volume>/backups/host.partial; check every file against the
# original (an rsync checksum pass: content, size, mtime, owner, mode); rename
# it into place; swap /var/backups/host for a symlink; check readers see the
# files through it; then delete the original. A failure at any step before the
# delete puts the original back and removes the copy. Nothing on the root
# disk is deleted until the new copy is verified and live.
#
# backup.sh sees the symlink and writes straight to the volume from its next
# run, staging off-site files there too (hard links can't cross disks). mtimes
# are kept, so the 14-day retention carries on where it was.
#
# Undo, after a successful run (needs ~8 GB free on root):
#   sudo rm /var/backups/host
#   sudo rsync -aHAX /mnt/HC_Volume_103575430/backups/host/ /var/backups/host/

set -Eeuo pipefail   # -E: the rollback trap also fires inside functions

SRC="/var/backups/host"
VOLUME="/mnt/HC_Volume_103575430"
DEST="$VOLUME/backups/host"
PARTIAL="$DEST.partial"
OLD="$SRC.moved-$(date +%Y%m%d-%H%M%S)"
BACKUP_SH="/opt/server-maintenance/scripts/backup.sh"

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "must run as root (sudo)"; exit 1; }

backup_running() {
    # backup.sh takes no lock, and safe-reboot runs it outside the unit. Both
    # run it by its shebang, so match that exact command line: a bare
    # pattern also matches an editor or pager open on the file.
    case "$(systemctl is-active backup.service 2>/dev/null || true)" in
        active|activating) return 0 ;;
    esac
    pgrep -f "^(/usr)?/bin/bash $BACKUP_SH( |$)" >/dev/null 2>&1
}

echo "=== move local backups to the volume ==="

# ── Preconditions ────────────────────────────────────────────────
if [[ -L "$SRC" ]]; then
    echo "$SRC is already a symlink to $(readlink "$SRC"); nothing to do."
    exit 0
fi
[[ -d "$SRC" ]] || { echo "no directory at $SRC" >&2; exit 1; }
mountpoint -q "$VOLUME" || { echo "$VOLUME is not mounted" >&2; exit 1; }
[[ ! -e "$DEST" ]] || { echo "$DEST already exists; refusing to overwrite it. Look at it first." >&2; exit 1; }
if backup_running; then
    echo "a backup is running; re-run this after it finishes (journalctl -fu backup.service)" >&2
    exit 1
fi
# Without the matching backup.sh, the next run would write through the
# symlink but stage under /root, the hard links would fail across disks, and
# the off-site bundle would carry no dumps.
grep -q 'offsite-staging' "$BACKUP_SH" || {
    echo "$BACKUP_SH doesn't know about the volume yet; update server-maintenance first" >&2
    exit 1
}
NEED=$(du -sb "$SRC" | cut -f1)
FREE=$(df -B1 --output=avail "$VOLUME" | tail -1 | tr -d ' ')
(( FREE > NEED + NEED / 10 )) || { echo "not enough room on $VOLUME: need $NEED bytes plus 10%, have $FREE" >&2; exit 1; }
N_SRC=$(find "$SRC" | wc -l)

echo "from: $SRC ($(du -sh "$SRC" | cut -f1), $N_SRC entries)"
echo "to:   $DEST, then $SRC -> $DEST"
df -h / "$VOLUME" | sed 's/^/  /'
echo

if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] preconditions pass; would copy, verify, swap in the symlink, then delete the original"
    exit 0
fi

# ── Copy and verify ──────────────────────────────────────────────
STAGE=copy
restore() {
    echo "FAILED during $STAGE — putting things back" >&2
    if [[ "$STAGE" == swap ]]; then
        [[ -L "$SRC" ]] && rm -f "$SRC"
        [[ -d "$OLD" && ! -e "$SRC" ]] && mv "$OLD" "$SRC"
        rm -rf "$DEST"
    fi
    rm -rf "$PARTIAL"
    echo "now: $SRC is $( [[ -L "$SRC" ]] && echo "a symlink" || echo "a directory" ), $(find "$SRC" | wc -l) entries (was $N_SRC)" >&2
    exit 1
}
trap restore ERR

rm -rf "$PARTIAL"                     # ours, left by an earlier failed run
mkdir -p "$VOLUME/backups"
chmod 700 "$VOLUME/backups"
echo "copying ..."
rsync -aHAX --numeric-ids "$SRC/" "$PARTIAL/"

verify_copy() {
    # Empty output means identical: every file's checksum, size, mtime,
    # owner and mode, and no file on one side only.
    local diffs
    diffs=$(rsync -aHAXc --numeric-ids --delete --dry-run --itemize-changes "$SRC/" "$PARTIAL/")
    if [[ -n "$diffs" ]]; then
        echo "verify failed: the copy differs from the original:" >&2
        echo "$diffs" | head -20 >&2
        return 1
    fi
    [[ $(find "$PARTIAL" | wc -l) -eq $N_SRC ]] || { echo "verify failed: entry count differs" >&2; return 1; }
}
echo "verifying (reads both copies in full) ..."
verify_copy
echo "verified: $N_SRC entries identical"

# ── Swap ─────────────────────────────────────────────────────────
if backup_running; then
    echo "a backup started during the copy; stopping before the swap" >&2
    false
fi
STAGE=swap
mv "$SRC" "$OLD"
mv "$PARTIAL" "$DEST"
ln -s "$DEST" "$SRC"

# ── Check readers see the backups through the symlink ────────────
[[ "$(readlink "$SRC")" == "$DEST" ]] || { echo "symlink points elsewhere" >&2; false; }
[[ $(find "$SRC/" | wc -l) -eq $N_SRC ]] || { echo "entry count through the symlink differs" >&2; false; }
# The health check's own query (agent-platform-health), through the symlink.
recent=$(find "$SRC/predictor" \( -name '*.db.gz' -o -name '*.db' \) -mtime -2 -print -quit 2>/dev/null || true)
[[ -n "$recent" ]] || { echo "no recent predictor snapshot visible through $SRC/predictor" >&2; false; }
# The same test backup.sh makes to choose the volume.
[[ -L "$SRC" ]] && mountpoint -q "$VOLUME" && [[ -d "$VOLUME/backups/host" ]] || {
    echo "backup.sh would not choose the volume" >&2; false; }
echo "readers ok: health check finds $(basename "$recent"); backup.sh will write to $DEST"

# ── Delete the original ──────────────────────────────────────────
# Past this point the new copy is verified and live, so a failed delete is
# left for a look, not rolled back.
trap - ERR
STAGE=done
rm -rf "$OLD" || echo "WARNING: could not fully delete $OLD; remove it by hand" >&2

echo
df -h / "$VOLUME" | sed 's/^/  /'
echo
echo "The next backup run (03:35) writes to $DEST. To check it tomorrow:"
echo "  journalctl -u backup.service --since today | grep -A6 'Backup sizes'"
echo "=== done ==="
