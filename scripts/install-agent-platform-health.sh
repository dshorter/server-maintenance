#!/usr/bin/env bash
# install-agent-platform-health.sh — deploy the repo copy of
# agent-platform-health to /usr/local/sbin, safely.
#
#   sudo /opt/server-maintenance/scripts/install-agent-platform-health.sh --dry-run
#   sudo /opt/server-maintenance/scripts/install-agent-platform-health.sh
#
# Why this exists: 2f4917a (2026-09-03) taught the snapshot freshness check to
# match the .db.gz files backup.sh now writes, and nothing installed it. The
# copy running hourly out of /usr/local/sbin dated from 2026-08-04 and still
# globbed '*.db' alone, so from the moment the last uncompressed snapshot aged
# past 48 hours it would have logged "No predictor snapshot ... within last 48
# hours" on every run, forever, while backups were fine. That branch logs rather
# than pages, which is the worse half: a warning that is always present cannot
# report a backup that has genuinely stopped.
#
# Same shape as install-notify-telegram.sh: back up, syntax-check, install,
# verify the thing that actually changed, roll back on any failure.
#
# The verification deliberately does NOT run the whole health check. That script
# pages the operator through alert() on a real failure, and an install should
# not be able to send a page. It runs the freshness expression alone — which is
# the only behaviour this change touches — against the live backup tree.

set -euo pipefail

SRC=/opt/server-maintenance/scripts/usr_local_sbin_agent-platform-health.sh
DST=/usr/local/sbin/agent-platform-health
SNAPDIR=/var/backups/host/predictor
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

[[ $EUID -eq 0 ]] || { echo "must run as root (sudo)"; exit 1; }
[[ -r "$SRC" ]] || { echo "missing source: $SRC"; exit 1; }

echo "=== install agent-platform-health ==="
bash -n "$SRC" || { echo "source does not parse — refusing"; exit 1; }
echo "source parses."

# State the problem before fixing it, so a dry run is also a diagnosis.
OLD_MATCH=$(find "$SNAPDIR" -name '*.db' -mtime -2 -print -quit 2>/dev/null || true)
NEW_MATCH=$(find "$SNAPDIR" \( -name '*.db.gz' -o -name '*.db' \) -mtime -2 -print -quit 2>/dev/null || true)
echo "freshness check against $SNAPDIR:"
echo "  installed expression ('*.db' only) : ${OLD_MATCH:-NO MATCH}"
echo "  repo expression ('*.db.gz' or .db) : ${NEW_MATCH:-NO MATCH}"
if [[ -z "$NEW_MATCH" ]]; then
    echo "the repo expression finds nothing either — that is a real backup problem," >&2
    echo "not an install problem. Refusing to install into an unclear state." >&2
    exit 1
fi

if cmp -s "$SRC" "$DST" 2>/dev/null; then
    echo "already identical — nothing to do."
    exit 0
fi
echo "diff against installed:"
diff -u "$DST" "$SRC" 2>/dev/null | head -60 || true

if [[ $DRY -eq 1 ]]; then
    echo "[dry-run] would install $SRC -> $DST"
    exit 0
fi

BACKUP="${DST}.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$DST" "$BACKUP"
echo "backup: $BACKUP"

rollback() {
    echo "FAILED — restoring $DST from $BACKUP" >&2
    cp -a "$BACKUP" "$DST"
    exit 1
}
trap rollback ERR

install -m 0755 -o root -g root "$SRC" "$DST"
bash -n "$DST" || false

# Verify the installed copy carries the fix, rather than trusting the copy.
grep -q 'db\.gz' "$DST" || {
    echo "installed copy does not contain the .gz match — wrong source?" >&2
    false
}
echo "installed copy matches compressed snapshots."

trap - ERR
echo
echo "installed. The hourly timer picks this up on its next run:"
echo "  systemctl list-timers agent-platform-health.timer"
echo "Confirm the next run reports a snapshot rather than a warning:"
echo "  journalctl -u agent-platform-health.service --since '10 min ago' | grep -i snapshot"
echo "=== done ==="
