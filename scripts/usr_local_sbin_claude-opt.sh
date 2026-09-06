#!/usr/bin/env bash
# claude-opt — start Claude Code as the `claude` user, in /opt, from a root shell.
#
#   claude-opt                              # interactive session, cwd /opt
#   claude-opt --resume                     # arguments pass straight through
#   CLAUDE_OPT_DIR=/opt/uzelhub-web claude-opt
#
# Root has no Claude install of its own any more (the root -> claude
# consolidation): one user owns the transcripts, the settings and the
# credentials. This is that trip written down, so an ssh-as-root session is one
# word away from a session in the right place as the right user.
#
# NOT a candidate for a sudoers NOPASSWD rule: the CLAUDE_OPT_* overrides let
# the caller choose what runs as `claude`, which is unremarkable for root (it
# could already do that) and a hole for anyone else.

set -uo pipefail

TARGET_USER="${CLAUDE_OPT_USER:-claude}"
TARGET_DIR="${CLAUDE_OPT_DIR:-/opt}"
TARGET_CMD="${CLAUDE_OPT_CMD:-claude}"

[ -d "$TARGET_DIR" ] || { echo "claude-opt: no such directory: $TARGET_DIR" >&2; exit 1; }

# Already the target user (a claude session shelling out, say): no reason to
# make the round trip through sudo.
if [ "$(id -un)" = "$TARGET_USER" ]; then
    cd "$TARGET_DIR" || exit 1
    exec "$TARGET_CMD" "$@"
fi

id -u "$TARGET_USER" >/dev/null 2>&1 || {
    echo "claude-opt: no such user: $TARGET_USER" >&2; exit 1; }

# -H plus `bash -l` buys the login environment (~/.local/bin on PATH, which is
# where the Claude launcher lives) while leaving argv exactly as typed. `sudo -i`
# would re-quote every argument through the login shell on the way in, which is
# fine for a fixed string and a trap for `-p "some prompt with spaces"`.
exec sudo -u "$TARGET_USER" -H -- bash -lc '
    cd "$1" || exit 1
    shift
    cmd=$1
    shift
    exec "$cmd" "$@"
' claude-opt "$TARGET_DIR" "$TARGET_CMD" "$@"
