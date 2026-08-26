#!/usr/bin/env bash
# disk-audit.sh — find what is actually consuming the root filesystem.
#
# READ-ONLY. Makes no changes, deletes nothing, writes only to the report path.
# Needs sudo purely to traverse root-owned directories; an unprivileged run
# silently skips them, which is exactly the blind spot this script exists to close.
#
#   sudo /opt/server-maintenance/scripts/disk-audit.sh
#
# Context (2026-08-26): root is 38G / 94% full with ~2.2G free. An unprivileged
# walk accounted for only 20G of the 34G in use, so roughly 14G sits somewhere
# only root can see. Docker is NOT a suspect — it lives on /dev/sdb.

set -uo pipefail

REPORT="/tmp/disk-audit-$(date +%Y%m%d-%H%M%S).txt"
TOPN="${TOPN:-25}"

if [[ $EUID -ne 0 ]]; then
    echo "WARNING: not running as root — root-owned paths will be skipped," >&2
    echo "         which is the whole point of this audit. Re-run with sudo." >&2
    echo >&2
fi

exec > >(tee "$REPORT") 2>&1

echo "=== disk audit $(date -Is) — running as $(id -un) ==="
echo

echo "--- filesystems ---"
df -h -x tmpfs -x devtmpfs
echo

echo "--- root filesystem only (-x: does not cross into /mnt, /boot/efi) ---"
du -shx / 2>/dev/null
echo "  ^ compare against the 'Used' column for / above."
echo "    A large gap means directories even root cannot stat (rare), or"
echo "    deleted-but-open files — see the section at the bottom."
echo

echo "--- top $TOPN directories on the root filesystem ---"
du -x --max-depth=4 / 2>/dev/null | sort -rn | head -n "$TOPN" | awk '{printf "%8.2f GB  %s\n", $1/1048576, $2}'
echo

echo "--- top $TOPN individual files on the root filesystem ---"
find / -xdev -type f -size +50M -printf '%s\t%p\n' 2>/dev/null \
    | sort -rn | head -n "$TOPN" \
    | awk -F'\t' '{printf "%8.2f GB  %s\n", $1/1073741824, $2}'
echo

echo "--- systemd journal ---"
journalctl --disk-usage 2>/dev/null
echo "configured limits (empty = defaults to 10% of the filesystem):"
grep -E '^\s*(SystemMaxUse|SystemKeepFree|MaxRetentionSec)' \
    /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf 2>/dev/null \
    || echo "  (none set — journald will grow to ~10% of /)"
echo

echo "--- deleted-but-still-open files (space not reclaimed until the holder restarts) ---"
lsof -nP +L1 2>/dev/null | awk 'NR==1 || $5=="REG"' | head -n 20 \
    || echo "  (lsof unavailable — install it or skip)"
echo

echo "--- package cache / logs / crash dumps ---"
for d in /var/cache/apt /var/log /var/crash /var/lib/snapd /root; do
    [[ -e "$d" ]] && printf '%10s  %s\n' "$(du -sh "$d" 2>/dev/null | cut -f1)" "$d"
done
echo

echo "=== end of audit ==="
echo "Report saved to: $REPORT"
