#!/usr/bin/env bash
# notify-telegram — push a message to the shared operator Telegram chat.
# Design: /opt/ai-agent-platform/docs/uzelhub-crew/sysadmin-agent-design.md §Notifications
#
# Usage:  notify-telegram <agent-name> <message...>
#         echo "message" | notify-telegram <agent-name>
#
# All agents share ONE chat; every message is prefixed "[AGENT]" (uppercased)
# so the sender is obvious on the client side. Outbound sendMessage only —
# this is a pager, not a control channel.
#
# Exit codes: 0 for anything delivery-related (no config, Telegram down,
# rate-capped) so callers like backup.sh / safe-reboot / OnFailure= hooks are
# never blocked; 2 only for usage errors. Delivery problems go to syslog
# (tag: notify-telegram).

set -u

CONF=/etc/default/notify-telegram
STATE_DIR=/var/lib/notify-telegram

slog() { logger -t notify-telegram -- "$*" 2>/dev/null || true; }

if [ $# -lt 1 ]; then
    echo "usage: notify-telegram <agent-name> <message...>" >&2
    exit 2
fi

AGENT=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
shift
if [ $# -gt 0 ]; then
    MSG="$*"
else
    MSG=$(cat)
fi
if [ -z "$MSG" ]; then
    echo "notify-telegram: empty message" >&2
    exit 2
fi

if [ ! -r "$CONF" ]; then
    slog "no readable $CONF — dropped: [$AGENT] $MSG"
    exit 0
fi
# shellcheck disable=SC1090
. "$CONF"
: "${NOTIFY_MAX_PER_DAY:=10}"

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    slog "config incomplete — dropped: [$AGENT] $MSG"
    exit 0
fi

# Daily rate cap shared across ALL agents: NOTIFY_MAX_PER_DAY real messages,
# then one "storm" notice, then silent drops (still visible in syslog).
#
# The state dir is shared by root senders (backup.sh, OnFailure= hooks) AND
# the claude-run uzella-proxy (contact-form / ask-budget pages). Both must be
# able to append to the same day's count file, or one sender's messages
# silently bypass the cap — live behavior until 2026-07-11: the root-only dir
# made every proxy-sent page uncounted. Root normalizes perms each run
# (setgid claude group, group-writable); non-root senders use what's there.
# NOTE: the proxy's unit needs ReadWritePaths=/var/lib/notify-telegram —
# ProtectSystem=strict otherwise mounts /var read-only for its children.
mkdir -p "$STATE_DIR" 2>/dev/null || true
if [ "$(id -u)" = 0 ]; then
    chgrp claude "$STATE_DIR" 2>/dev/null || true
    chmod 2770 "$STATE_DIR" 2>/dev/null || true
fi
COUNT_FILE="$STATE_DIR/count-$(date +%Y%m%d)"
find "$STATE_DIR" -name 'count-*' -mtime +7 -delete 2>/dev/null || true

exec 9>>"$COUNT_FILE" 2>/dev/null || true
chmod 660 "$COUNT_FILE" 2>/dev/null || true   # creator opens it up for the other sender
flock -w 30 9 2>/dev/null || slog "count-file lock timeout — proceeding uncounted"

COUNT=$(wc -l <"$COUNT_FILE" 2>/dev/null || echo 0)
if [ "$COUNT" -gt "$NOTIFY_MAX_PER_DAY" ]; then
    slog "suppressed (daily cap): [$AGENT] $MSG"
    exit 0
elif [ "$COUNT" -eq "$NOTIFY_MAX_PER_DAY" ]; then
    slog "cap reached — sending storm notice; suppressed: [$AGENT] $MSG"
    AGENT="NOTIFY"
    MSG="notification storm: daily cap of $NOTIFY_MAX_PER_DAY reached — further messages suppressed until midnight; see syslog (notify-telegram) for what was dropped"
fi

TEXT="[$AGENT] $MSG"
TEXT=${TEXT:0:4000}   # Telegram hard limit is 4096 chars

RESP=$(curl -sS --max-time 10 -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${TEXT}" 2>&1)

if printf '%s' "$RESP" | grep -q '"ok":true'; then
    printf '%s [%s]\n' "$(date -Is)" "$AGENT" >&9 2>/dev/null || true
    slog "sent: [$AGENT] ${MSG:0:120}"
else
    slog "send FAILED: [$AGENT] ${MSG:0:120} — resp: ${RESP:0:200}"
fi
exit 0
