#!/usr/bin/env bash
# compress-backup-snapshots.sh — one-time: gzip the raw database snapshots
# already sitting in the backup staging tree.
#
#   sudo /opt/server-maintenance/scripts/compress-backup-snapshots.sh --dry-run
#   sudo /opt/server-maintenance/scripts/compress-backup-snapshots.sh
#
# Why: backup.sh compresses every artifact it writes — tar -czf for the config
# and content trees, gzip for the ghost and postgres dumps — except the raw
# SQLite snapshots. The 2026-09-03 audit found /var/backups/host at 12.18 GB,
# 10.20 GB of it predictor snapshots, on a 38 GB root filesystem that had just
# paged at 96%. Retention was working correctly the whole time: 14 days at
# ~0.7 GB/day is simply what uncompressed SQLite costs.
#
# backup.sh now gzips these at write time, so this script exists only to clean
# up the window that accumulated before that change. It should need to run once.
# SQLite gzips ~4.6x, so the same 14-day window costs roughly 2.2 GB after.
#
# SAFETY — each file is compressed to a NEW .gz and the original is removed
# only after the .gz round-trips back to a byte-identical checksum. On any
# mismatch the original stays and the .gz is dropped. Nothing is deleted that
# has not first been proven readable.
#
# The mtime is copied onto the .gz deliberately. Both the 14-day retention
# sweep in backup.sh and the 48-hour freshness check in the health script are
# mtime-based, so writing a fresh timestamp would quietly hold every snapshot
# for another full window AND make a stale backup look current — the failure
# would be invisible in exactly the way the June 2026 off-site outage was.

set -uo pipefail

BACKUP_DIR="/var/backups/host"
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "must run as root (sudo)"; exit 1; }
[[ -d "$BACKUP_DIR" ]] || { echo "no backup dir at $BACKUP_DIR — nothing to do"; exit 1; }

# Never race a live backup: it hardlinks this run's artifacts into an off-site
# staging dir and tars them while we would be renaming them out from under it.
if systemctl is-active --quiet backup.service; then
    echo "backup.service is running — refusing to touch the staging tree." >&2
    echo "Re-run once it finishes (it starts 03:33 daily)." >&2
    exit 1
fi

command -v pigz >/dev/null 2>&1 && COMPRESSOR="pigz" || COMPRESSOR="gzip"

echo "=== compress raw backup snapshots ==="
[[ $DRY_RUN -eq 1 ]] && echo "*** DRY RUN — nothing will be changed ***"
echo "compressor: $COMPRESSOR"
echo "before: $(df -h / | awk 'NR==2 {print $4" free ("$5" used)"}')"
echo

mapfile -t TARGETS < <(
    find "$BACKUP_DIR" -type f \( -name '*.db' -o -name '*.sqlite' \) 2>/dev/null | sort
)

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo "No raw .db/.sqlite snapshots found — already compressed, nothing to do."
    exit 0
fi

echo "found ${#TARGETS[@]} raw snapshot(s)"
echo

saved_kb=0
done_n=0
failed_n=0

for f in "${TARGETS[@]}"; do
    name="${f#$BACKUP_DIR/}"
    src_kb=$(du -sk "$f" | cut -f1)

    if [[ -e "$f.gz" ]]; then
        echo "  SKIP  $name — $f.gz already exists"
        continue
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        awk -v n="$name" -v s="$src_kb" \
            'BEGIN{printf "  [dry-run] would compress %-52s %6.0f MB\n", n, s/1024}'
        continue
    fi

    # Compress to a new file; the original is still untouched at this point.
    if ! "$COMPRESSOR" -c "$f" > "$f.gz" 2>/dev/null; then
        echo "  FAIL  $name — compression failed, original kept"
        rm -f "$f.gz"
        failed_n=$((failed_n+1))
        continue
    fi

    # Prove the archive round-trips before removing anything.
    orig_sum=$(md5sum < "$f" | cut -d' ' -f1)
    gz_sum=$(gzip -cd "$f.gz" 2>/dev/null | md5sum | cut -d' ' -f1)
    if [[ -z "$gz_sum" || "$orig_sum" != "$gz_sum" ]]; then
        echo "  FAIL  $name — checksum mismatch, original kept"
        rm -f "$f.gz"
        failed_n=$((failed_n+1))
        continue
    fi

    # Retention and the freshness alarm both read mtime — carry it across.
    touch -r "$f" "$f.gz"
    chmod --reference="$f" "$f.gz" 2>/dev/null || chmod 600 "$f.gz"
    rm -f "$f"

    out_kb=$(du -sk "$f.gz" | cut -f1)
    saved_kb=$((saved_kb + src_kb - out_kb))
    done_n=$((done_n+1))
    awk -v n="$name" -v s="$src_kb" -v o="$out_kb" \
        'BEGIN{printf "  ok    %-52s %6.0f MB -> %5.0f MB  (%.1fx)\n", n, s/1024, o/1024, (o?s/o:0)}'
done

echo
if [[ $DRY_RUN -eq 1 ]]; then
    echo "dry run complete — re-run without --dry-run to apply."
    exit 0
fi

awk -v k="$saved_kb" -v d="$done_n" -v f="$failed_n" \
    'BEGIN{printf "compressed %d file(s), %d failure(s), freed %.2f GB\n", d, f, k/1048576}'

# ── Self-verify ──────────────────────────────────────────────────────
echo
echo "--- post-check ---"
echo "  raw .db/.sqlite left in staging: $(find "$BACKUP_DIR" -type f \( -name '*.db' -o -name '*.sqlite' \) 2>/dev/null | wc -l)"
echo "  gzipped snapshots:               $(find "$BACKUP_DIR" -type f \( -name '*.db.gz' -o -name '*.sqlite.gz' \) 2>/dev/null | wc -l)"
echo "  staging tree total:              $(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)"

# The health check reads this exact window; confirm it still sees a snapshot.
fresh=$(find "$BACKUP_DIR/predictor" \( -name '*.db.gz' -o -name '*.db' \) -mtime -2 -print -quit 2>/dev/null)
if [[ -n "$fresh" ]]; then
    echo "  freshness check:                 OK ($(basename "$fresh"))"
else
    echo "  freshness check:                 NO snapshot within 48h — investigate" >&2
fi

echo "after:  $(df -h / | awk 'NR==2 {print $4" free ("$5" used)"}')"
echo "=== done ==="

[[ $failed_n -eq 0 ]] || exit 1
