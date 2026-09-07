#!/usr/bin/env bash
# install-safe-reboot.sh — deploy the repo copy of safe-reboot to /usr/local/sbin.
#
#   sudo /opt/server-maintenance/scripts/install-safe-reboot.sh --dry-run
#   sudo /opt/server-maintenance/scripts/install-safe-reboot.sh
#
# Back up, parse-check, install, then prove the installed copy actually runs
# by executing its own --check mode, which exercises preflight, the status
# export and both quiesce waiters and stops before the backup and the
# reboot. Roll back if that fails.
#
# The self-verification is the point. Until 2026-09-07 this script had no
# rehearsal mode, so nothing ever ran it except a real reboot — which is how
# its predictor guard stayed dead for six months and a `set -e` trap that
# would have skipped the backup entirely went unnoticed for two.

set -euo pipefail

SRC=/opt/server-maintenance/scripts/usr_local_sbin_safe-reboot.sh
DST=/usr/local/sbin/safe-reboot
DRY=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "must run as root (sudo)"; exit 1; }
[[ -r "$SRC" ]] || { echo "missing source: $SRC"; exit 1; }

echo "=== install safe-reboot ==="
bash -n "$SRC" || { echo "source does not parse — refusing"; exit 1; }
echo "source parses."

# A reboot script that lost its abort-on-failed-backup is worse than no
# script, so check the two invariants the file must never be installed
# without.
grep -q 'ABORTING REBOOT' "$SRC" || { echo "source lost its backup abort — refusing"; exit 1; }
grep -q 'wait_for_agent_units || true' "$SRC" || { echo "source lost the set -e guard — refusing"; exit 1; }
echo "invariants present: backup abort, waiter guard."

if cmp -s "$SRC" "$DST" 2>/dev/null; then
    echo "already identical — nothing to install."
    exit 0
fi

if [[ -e "$DST" ]]; then
    echo "diff against installed:"
    diff -u "$DST" "$SRC" | head -60 || true
else
    echo "fresh install (no $DST yet)."
fi

if [[ $DRY -eq 1 ]]; then
    echo "[dry-run] would install $SRC -> $DST"
    exit 0
fi

BACKUP=""
if [[ -e "$DST" ]]; then
    BACKUP="${DST}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$DST" "$BACKUP"
    echo "backup: $BACKUP"
fi

restore() {
    if [[ -n "$BACKUP" && -e "$BACKUP" ]]; then
        cp -a "$BACKUP" "$DST"
        echo "ROLLED BACK to $BACKUP"
    else
        rm -f "$DST"
        echo "removed $DST (there was nothing to roll back to)"
    fi
}

install -o root -g root -m 0755 "$SRC" "$DST"
echo "installed $DST"

echo "--- self-verify: running the installed copy's --check ---"
if "$DST" --check; then
    echo "✓ --check passed on the installed copy"
else
    echo "✗ --check FAILED on the installed copy"
    restore
    exit 1
fi

echo "=== done ==="
echo "safe-reboot is installed. Rehearse any time with: sudo safe-reboot --check"
