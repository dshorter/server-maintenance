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

# Overridable only so the backoff logic can be exercised in a test harness;
# both default to the real paths in every production call.
CONF=${NOTIFY_CONF:-/etc/default/notify-telegram}
STATE_DIR=${NOTIFY_STATE_DIR:-/var/lib/notify-telegram}

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
: "${NOTIFY_MAX_PER_DAY:=20}"
: "${NOTIFY_MAX_PER_AGENT:=8}"

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
SEEN_FILE="$STATE_DIR/seen-$(date +%Y%m%d)"
find "$STATE_DIR" -name 'count-*' -mtime +7 -delete 2>/dev/null || true
find "$STATE_DIR" -name 'seen-*'  -mtime +7 -delete 2>/dev/null || true

# ── Repeat backoff ────────────────────────────────────────────────────
# A stuck condition must not consume the whole estate's daily budget. Live
# failure 2026-08-22..29: the disk check paged hourly (24/day) against a
# shared cap of 10, so it exhausted the budget by mid-morning every day and
# every other agent was suppressed as collateral — the predictor reported
# "failed: trending" daily for 23 days and none of it was delivered.
#
# Fingerprint ignores digits, so "disk at 91%" and "disk at 94%" are the same
# recurring condition. Send on occurrences 1, 2, 4, 8, 16 ... — the operator
# still learns it is ongoing, at five pages a day instead of twenty-four.
FP=$(printf '%s|%s' "$AGENT" "$MSG" \
     | tr -d '0-9' | tr '[:upper:]' '[:lower:]' \
     | md5sum 2>/dev/null | cut -c1-12)
[ -n "$FP" ] || FP="nofp"

exec 8>>"$SEEN_FILE" 2>/dev/null || true
chmod 660 "$SEEN_FILE" 2>/dev/null || true
flock -w 5 8 2>/dev/null || true
printf '%s\n' "$FP" >&8 2>/dev/null || true
REPEAT=$(grep -c "^$FP\$" "$SEEN_FILE" 2>/dev/null) || REPEAT=1
[ -n "$REPEAT" ] || REPEAT=1

# Powers of two only.
if [ "$REPEAT" -gt 0 ] && [ $(( REPEAT & (REPEAT - 1) )) -ne 0 ]; then
    slog "suppressed (repeat #$REPEAT, backoff): [$AGENT] ${MSG:0:120}"
    exit 0
fi
if [ "$REPEAT" -gt 1 ]; then
    MSG="$MSG  (repeat #$REPEAT today)"
fi

exec 9>>"$COUNT_FILE" 2>/dev/null || true
chmod 660 "$COUNT_FILE" 2>/dev/null || true   # creator opens it up for the other sender
flock -w 30 9 2>/dev/null || slog "count-file lock timeout — proceeding uncounted"

# Per-agent quota, so one chatty sender cannot censor the others even when
# its messages are genuinely distinct.
AGENT_SENT=$(grep -c "\[$AGENT\]" "$COUNT_FILE" 2>/dev/null) || AGENT_SENT=0
[ -n "$AGENT_SENT" ] || AGENT_SENT=0
if [ "$AGENT_SENT" -ge "$NOTIFY_MAX_PER_AGENT" ]; then
    slog "suppressed (agent cap $NOTIFY_MAX_PER_AGENT): [$AGENT] ${MSG:0:120}"
    exit 0
fi

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
