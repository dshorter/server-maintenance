#!/usr/bin/env bash
# prune-root-claude.sh — remove root's leftover Claude CLI binaries.
#
#   sudo /opt/server-maintenance/scripts/prune-root-claude.sh --dry-run
#   sudo /opt/server-maintenance/scripts/prune-root-claude.sh
#
# Background: root's Claude install was merged into claude@ on 2026-07-16; the
# uninstall never happened and ~2GB of superseded binaries have sat under /root
# since. This finishes that job.
#
# SESSION LOGS ARE NEVER DELETED. Every *.jsonl under /root/.claude is first
# mirrored into the snapshot at /home/claude/root-claude-snapshot and verified
# by checksum. If a single file fails to verify, the script deletes NOTHING and
# exits non-zero. The originals are left in place afterwards regardless — only
# version binaries and the puppeteer browser cache are removed.
#
# Explicitly never touched: /root/.config (rclone.conf lives there and gates the
# off-site backup), /root/n8n-data, /root/.ssh, and any *.jsonl anywhere.

set -euo pipefail

SNAPSHOT="/home/claude/root-claude-snapshot"
ROOT_CLAUDE="/root/.claude"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

[[ $EUID -eq 0 ]] || { echo "must run as root (sudo)"; exit 1; }
[[ -d "$SNAPSHOT" ]] || { echo "snapshot dir missing: $SNAPSHOT — aborting"; exit 1; }

echo "=== prune root's Claude install ==="
[[ $DRY_RUN -eq 1 ]] && echo "*** DRY RUN — nothing will be changed ***"
echo "before: $(df -h / | awk 'NR==2 {print $4" free ("$5" used)"}')"
echo

# ── 1. Preserve every session log ────────────────────────────────────
echo "--- session logs ---"
mapfile -t LOGS < <(find "$ROOT_CLAUDE" -name '*.jsonl' -type f 2>/dev/null | sort)
echo "found ${#LOGS[@]} *.jsonl under $ROOT_CLAUDE"

if [[ ${#LOGS[@]} -gt 0 ]]; then
    copied=0 already=0
    for src in "${LOGS[@]}"; do
        rel="${src#$ROOT_CLAUDE/}"
        dst="$SNAPSHOT/$rel"
        if [[ -f "$dst" ]] && [[ "$(md5sum < "$src")" == "$(md5sum < "$dst")" ]]; then
            already=$((already+1)); continue
        fi
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "  [dry-run] would copy $rel"
        else
            mkdir -p "$(dirname "$dst")"
            cp -a "$src" "$dst"
        fi
        copied=$((copied+1))
    done
    echo "  already in snapshot: $already    newly copied: $copied"

    # ── 2. Verify before deleting anything ───────────────────────────
    if [[ $DRY_RUN -eq 0 ]]; then
        echo "--- verifying every log is in the snapshot ---"
        bad=0
        for src in "${LOGS[@]}"; do
            dst="$SNAPSHOT/${src#$ROOT_CLAUDE/}"
            if [[ ! -f "$dst" ]] || [[ "$(md5sum < "$src")" != "$(md5sum < "$dst")" ]]; then
                echo "  MISMATCH: $src"; bad=$((bad+1))
            fi
        done
        if [[ $bad -gt 0 ]]; then
            echo "$bad file(s) failed verification — DELETING NOTHING." >&2
            exit 1
        fi
        echo "  all ${#LOGS[@]} verified."
        chown -R claude:claude "$SNAPSHOT"
    fi
fi
echo

# ── 3. Remove binaries only ──────────────────────────────────────────
echo "--- superseded binaries ---"
freed=0
shopt -s nullglob
TARGETS=(
    /root/.local/share/claude/versions/*
    /root/.claude/remote/ccd-cli/*
    /root/.cache/puppeteer
)
for t in "${TARGETS[@]}"; do
    # Version paths must look like a version number; puppeteer is named exactly.
    base="$(basename "$t")"
    if [[ "$base" != "puppeteer" ]] && [[ ! "$base" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "  SKIP (unrecognized name): $t"; continue
    fi
    [[ -e "$t" ]] || continue
    kb=$(du -sk "$t" | cut -f1); sz=$(du -sh "$t" | cut -f1)
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  [dry-run] would remove $sz  $t"
    else
        rm -rf "$t"; echo "  removed $sz  $t"
    fi
    freed=$((freed+kb))
done
echo
printf 'total: %.2f GB %s\n' "$(echo "$freed/1048576" | bc -l)" \
    "$([[ $DRY_RUN -eq 1 ]] && echo 'would be freed' || echo 'freed')"
echo

# ── 4. Self-verify ───────────────────────────────────────────────────
echo "--- post-check ---"
echo "  *.jsonl still under /root/.claude: $(find "$ROOT_CLAUDE" -name '*.jsonl' 2>/dev/null | wc -l)"
echo "  *.jsonl in snapshot:               $(find "$SNAPSHOT" -name '*.jsonl' 2>/dev/null | wc -l)"
for keep in /root/.config/rclone/rclone.conf /root/n8n-data; do
    [[ -e "$keep" ]] && echo "  intact: $keep" || echo "  NOTE: $keep not present"
done
echo "after:  $(df -h / | awk 'NR==2 {print $4" free ("$5" used)"}')"
echo "=== done ==="
