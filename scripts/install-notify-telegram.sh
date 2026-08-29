#!/usr/bin/env bash
# install-notify-telegram.sh — deploy the repo copy of notify-telegram to
# /usr/local/sbin, safely.
#
#   sudo /opt/server-maintenance/scripts/install-notify-telegram.sh --dry-run
#   sudo /opt/server-maintenance/scripts/install-notify-telegram.sh
#
# This script is the pager for EVERY agent on the box. A broken copy means no
# alerts at all and no error to tell you so. Hence: back up, syntax-check,
# install, smoke-test against a scratch state dir, and roll back on any
# failure. The smoke test stubs curl, so nothing is sent to Telegram.

set -euo pipefail

SRC=/opt/server-maintenance/scripts/usr_local_sbin_notify-telegram.sh
DST=/usr/local/sbin/notify-telegram
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

[[ $EUID -eq 0 ]] || { echo "must run as root (sudo)"; exit 1; }
[[ -r "$SRC" ]] || { echo "missing source: $SRC"; exit 1; }

echo "=== install notify-telegram ==="
bash -n "$SRC" || { echo "source does not parse — refusing"; exit 1; }
echo "source parses."

if cmp -s "$SRC" "$DST" 2>/dev/null; then
    echo "already identical — nothing to do."
    exit 0
fi
echo "diff against installed:"
diff -u "$DST" "$SRC" 2>/dev/null | head -40 || true

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

# Smoke test: stubbed curl, scratch state dir, real script. Verifies the
# backoff actually suppresses and that a second agent still gets through.
T=$(mktemp -d)
mkdir -p "$T/bin" "$T/state"
printf 'TELEGRAM_BOT_TOKEN=test\nTELEGRAM_CHAT_ID=test\n' > "$T/conf"
printf '#!/bin/sh\necho "{\\"ok\\":true}"\n' > "$T/bin/curl"
chmod +x "$T/bin/curl"

for i in $(seq 1 24); do
    PATH="$T/bin:$PATH" NOTIFY_CONF="$T/conf" NOTIFY_STATE_DIR="$T/state" \
        "$DST" HEALTH "Disk space critical: $((88 + i % 7))% used" >/dev/null 2>&1 || true
done
PATH="$T/bin:$PATH" NOTIFY_CONF="$T/conf" NOTIFY_STATE_DIR="$T/state" \
    "$DST" PREDICTOR "film daily — PARTIAL: failed: trending" >/dev/null 2>&1 || true

SENT=$(cat "$T/state"/count-* 2>/dev/null | wc -l)
HEALTH_SENT=$(grep -c '\[HEALTH\]' "$T/state"/count-* 2>/dev/null || echo 0)
PRED_SENT=$(grep -c '\[PREDICTOR\]' "$T/state"/count-* 2>/dev/null || echo 0)
rm -rf "$T"

echo "smoke test: 24 repeat alerts + 1 other -> $SENT sent (HEALTH $HEALTH_SENT, PREDICTOR $PRED_SENT)"
if [[ "$HEALTH_SENT" -gt 8 ]] || [[ "$PRED_SENT" -lt 1 ]]; then
    echo "smoke test FAILED: backoff or per-agent quota not working" >&2
    false
fi
echo "smoke test passed."

trap - ERR
echo
echo "installed. Live state dir is untouched: /var/lib/notify-telegram"
echo "Today's suppressed backlog is visible with:"
echo "  journalctl --since today | grep 'notify-telegram.*suppressed'"
echo "=== done ==="
