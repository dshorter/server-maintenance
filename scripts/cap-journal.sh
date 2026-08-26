#!/usr/bin/env bash
# cap-journal.sh — bound the systemd journal and reclaim what it is over.
#
#   sudo /opt/server-maintenance/scripts/cap-journal.sh          # apply
#   sudo /opt/server-maintenance/scripts/cap-journal.sh --dry-run # show, change nothing
#
# Why: /etc/systemd/journald.conf sets no SystemMaxUse, so journald defaults to
# 10% of the filesystem — ~3.8G on this 38G root. It sits at ~1.9G and climbs.
# This pins it at 200M and vacuums the excess, recovering ~1.7G.
#
# Vacuuming discards OLD journal entries. Anything the sysadmin agent or a
# post-mortem still needs should be exported first; 200M holds roughly the
# last few weeks at current volume.

set -euo pipefail

CONF="/etc/systemd/journald.conf"
CAP="${CAP:-200M}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

[[ $EUID -eq 0 ]] || { echo "must run as root (sudo)"; exit 1; }

echo "=== journal cap ==="
echo "before: $(journalctl --disk-usage)"
echo "target: SystemMaxUse=$CAP"
echo

if grep -qE '^\s*SystemMaxUse=' "$CONF"; then
    echo "SystemMaxUse is already set in $CONF:"
    grep -nE '^\s*SystemMaxUse=' "$CONF"
    echo "Refusing to overwrite an existing deliberate setting. Edit it by hand."
    exit 1
fi

if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] would append 'SystemMaxUse=$CAP' under [Journal] in $CONF"
    echo "[dry-run] would run: journalctl --vacuum-size=$CAP"
    echo "[dry-run] would restart systemd-journald"
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
journalctl --vacuum-size="$CAP"

trap - ERR

echo
echo "after:  $(journalctl --disk-usage)"
echo "effective config:"
grep -E '^\s*SystemMaxUse=' "$CONF"
echo
df -h / | tail -1
echo "=== done ==="
