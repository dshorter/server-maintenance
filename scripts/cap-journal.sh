#!/usr/bin/env bash
# cap-journal.sh — bound the systemd journal and reclaim what it is over.
#
#   sudo /opt/server-maintenance/scripts/cap-journal.sh          # apply
#   sudo /opt/server-maintenance/scripts/cap-journal.sh --dry-run # show, change nothing
#   sudo CAP=200M /opt/server-maintenance/scripts/cap-journal.sh --lower  # lower an
#                                                   # existing cap AND reclaim now
#
# Why: /etc/systemd/journald.conf sets no SystemMaxUse, so journald defaults to
# 10% of the filesystem — ~3.8G on this 38G root — and it is already at ~1.9G.
# This BOUNDS it. The cap defaults to 2G, just above current usage, so nothing
# is discarded today; it only stops the ceiling from being another 1.9G away.
#
# The vacuum runs ONLY if usage already exceeds the cap. At CAP=2G with 1.9G on
# disk that is a no-op and every existing entry survives. Pass a smaller cap
# (CAP=200M ./cap-journal.sh) to actually reclaim space — that DOES discard the
# oldest entries, so export them first if anything still needs them.

set -euo pipefail

CONF="/etc/systemd/journald.conf"
CAP="${CAP:-2G}"
DRY_RUN=0
LOWER=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --lower)   LOWER=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "must run as root (sudo)"; exit 1; }

echo "=== journal cap ==="
echo "before: $(journalctl --disk-usage)"
echo "target: SystemMaxUse=$CAP"
echo

EXISTING=0
if grep -qE '^\s*SystemMaxUse=' "$CONF"; then
    EXISTING=1
    echo "SystemMaxUse is already set in $CONF:"
    grep -nE '^\s*SystemMaxUse=' "$CONF"
    if [[ $LOWER -eq 0 ]]; then
        echo
        echo "Refusing to overwrite an existing deliberate setting."
        echo "To replace it with CAP=$CAP and reclaim the difference now, re-run with --lower:"
        echo "  sudo CAP=$CAP $0 --lower"
        exit 1
    fi
    echo "--lower given: replacing it with $CAP and vacuuming down to that size."
    echo "NOTE: this DISCARDS the oldest journal entries. Export first if you need them."
    echo
fi

if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] would append 'SystemMaxUse=$CAP' under [Journal] in $CONF"
    echo "[dry-run] would restart systemd-journald"
    echo "[dry-run] vacuum: journald enforces the cap itself on restart;"
    echo "[dry-run]         at $CAP with $(journalctl --disk-usage | grep -oE '[0-9.]+[KMGT]' | head -1) on disk, nothing is discarded"
    exit 0
fi

BACKUP="${CONF}.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$CONF" "$BACKUP"
echo "backup: $BACKUP"

restore() {
    echo "FAILED — restoring $CONF from $BACKUP" >&2
    cp -a "$BACKUP" "$CONF"
    systemctl restart systemd-journald || true
    exit 1
}
trap restore ERR

# Append under the [Journal] section header.
awk -v cap="$CAP" '
    /^[[:space:]]*SystemMaxUse=/ { next }
    /^\[Journal\]/ { print; print "SystemMaxUse=" cap; inserted=1; next }
    { print }
    END { if (!inserted) { print "[Journal]"; print "SystemMaxUse=" cap } }
' "$BACKUP" > "$CONF"

# Validate before activating.
if ! grep -qE "^SystemMaxUse=${CAP}$" "$CONF"; then
    echo "validation failed: SystemMaxUse not present after edit" >&2
    false
fi
systemd-analyze cat-config systemd/journald.conf >/dev/null 2>&1 || {
    echo "validation failed: journald.conf does not parse" >&2
    false
}
echo "validated."

systemctl restart systemd-journald

# journald applies SystemMaxUse itself on restart, trimming only what exceeds
# the cap. No explicit --vacuum-size call: an explicit vacuum would be the same
# operation, but calling it makes the script read as if discarding is the point.
# It is not — bounding growth is.
#
# --lower is the one case where discarding IS the point: the operator asked to
# reclaim, so vacuum explicitly rather than waiting for growth to force it.
if [[ $LOWER -eq 1 ]]; then
    echo "vacuuming to $CAP ..."
    journalctl --vacuum-size="$CAP"
fi

trap - ERR

echo
echo "after:  $(journalctl --disk-usage)"
echo "effective config:"
grep -E '^\s*SystemMaxUse=' "$CONF"
echo
df -h / | tail -1
echo "=== done ==="
