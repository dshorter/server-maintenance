#!/usr/bin/env bash
# install-claude-opt.sh — deploy the repo copy of claude-opt to /usr/local/sbin.
#
#   sudo /opt/server-maintenance/scripts/install-claude-opt.sh --dry-run
#   sudo /opt/server-maintenance/scripts/install-claude-opt.sh
#   sudo /opt/server-maintenance/scripts/install-claude-opt.sh --link-as-claude
#
# --link-as-claude also drops /usr/local/sbin/claude as a symlink, so root
# typing plain `claude` lands in the same place. It refuses to clobber an
# existing file that is not already that symlink.
#
# Back up, parse-check, install, then prove the installed copy really does end
# up as the claude user, in /opt, with argv intact — and roll back if it does
# not. The last smoke test starts the real Claude binary with --version, which
# exits immediately and talks to nothing.

set -euo pipefail

SRC=/opt/server-maintenance/scripts/usr_local_sbin_claude-opt.sh
DST=/usr/local/sbin/claude-opt
LINK=/usr/local/sbin/claude
DRY=0
LINK_AS_CLAUDE=0

for arg in "$@"; do
    case "$arg" in
        --dry-run)        DRY=1 ;;
        --link-as-claude) LINK_AS_CLAUDE=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "must run as root (sudo)"; exit 1; }
[[ -r "$SRC" ]] || { echo "missing source: $SRC"; exit 1; }

echo "=== install claude-opt ==="
bash -n "$SRC" || { echo "source does not parse — refusing"; exit 1; }
echo "source parses."

if cmp -s "$SRC" "$DST" 2>/dev/null; then
    echo "already identical — nothing to install."
else
    if [[ -e "$DST" ]]; then
        echo "diff against installed:"
        diff -u "$DST" "$SRC" | head -40 || true
    else
        echo "fresh install (no $DST yet)."
    fi

    if [[ $DRY -eq 1 ]]; then
        echo "[dry-run] would install $SRC -> $DST"
        [[ $LINK_AS_CLAUDE -eq 1 ]] && echo "[dry-run] would link $LINK -> claude-opt"
        exit 0
    fi

    BACKUP=""
    if [[ -e "$DST" ]]; then
        BACKUP="${DST}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$DST" "$BACKUP"
        echo "backup: $BACKUP"
    fi

    rollback() {
        if [[ -n "$BACKUP" ]]; then
            echo "FAILED — restoring $DST from $BACKUP" >&2
            cp -a "$BACKUP" "$DST"
        else
            echo "FAILED — removing the half-installed $DST" >&2
            rm -f "$DST"
        fi
        exit 1
    }
    trap rollback ERR

    install -m 0755 -o root -g root "$SRC" "$DST"
    bash -n "$DST" || false
fi

# --- smoke tests, against the installed copy, as root -----------------------
trap 'echo "smoke test FAILED — see above" >&2; exit 1' ERR

WHERE=$(CLAUDE_OPT_CMD=pwd "$DST")
echo "cwd inside the session:  $WHERE"
[[ "$WHERE" == "/opt" ]] || { echo "expected /opt" >&2; false; }

WHO=$(CLAUDE_OPT_CMD=id "$DST" -un)
echo "user inside the session: $WHO"
[[ "$WHO" == "claude" ]] || { echo "expected claude" >&2; false; }

ARGV=$(CLAUDE_OPT_CMD=printf "$DST" '[%s]' 'a b' 'c"d')
echo "argv pass-through:       $ARGV"
[[ "$ARGV" == '[a b][c"d]' ]] || { echo 'expected [a b][c"d]' >&2; false; }

VERSION=$("$DST" --version)
echo "claude --version:        $VERSION"
[[ -n "$VERSION" ]] || { echo "no version output" >&2; false; }

if [[ $LINK_AS_CLAUDE -eq 1 ]]; then
    if [[ -e "$LINK" && ! -L "$LINK" ]]; then
        echo "refusing to replace the regular file $LINK" >&2
        false
    fi
    ln -sfn claude-opt "$LINK"
    echo "linked: $LINK -> claude-opt"
fi

trap - ERR
echo
echo "installed. From a root shell:"
echo "  claude-opt              # session as claude, in /opt"
echo "  claude-opt --resume     # arguments pass through"
echo "=== done ==="
