# Telegram Alerting — `notify-telegram`

> **Installed:** 2026-07-02. Operational doc — the *why* and the agent-facing
> constraints live in
> `/opt/ai-agent-platform/docs/uzelhub-crew/sysadmin-agent-design.md`
> §"Notifications — Telegram push". Cross-project map entries:
> `/opt/_host/README.md` §Backups and §Host-level systemd units.

## What it is

One shared Telegram chat for **all** agents and automation on this box. Every
message is prefixed `[AGENT]` (uppercased automatically) so the sender is
obvious client-side — one chat, many senders. The bot is the same one the
Director listens on; this helper **only sends** (`sendMessage`, outbound
HTTPS only). It is a pager, not a control channel.

## Usage

```bash
notify-telegram <agent-name> <message...>
echo "message" | notify-telegram <agent-name>
```

- `<agent-name>` is uppercased into the `[AGENT]` prefix (`backup` → `[BACKUP]`).
- Exit code is **0 even when delivery fails** (no config, Telegram down,
  rate-capped) — callers like `backup.sh` and `safe-reboot` must never be
  blocked by the pager. Exit 2 only for usage errors.
- Delivery log: `journalctl -t notify-telegram` (sent / suppressed / failed).

## Installed pieces

| Live path | Source of record (this repo) |
|---|---|
| `/usr/local/sbin/notify-telegram` | `scripts/usr_local_sbin_notify-telegram.sh` |
| `/etc/systemd/system/notify-telegram@.service` | `systemd/etc_systemd_system_notify-telegram@.service` |
| `/etc/default/notify-telegram` | *not in repo* — contains the bot token (**root:claude, 640**; see below) |
| `/var/lib/notify-telegram/` | state: daily counter files, auto-cleaned after 7 days (**root:claude, 2770**; see below) |

The config file *is* captured by `backup.sh` into the system backup staging
(mode 600), so it survives a rebuild.

### Permissions — the claude-run senders (deliberate, 2026-07)

Not everything that pages is root: **uzella-proxy runs as `claude`** and calls
this helper for contact-form submissions and ask-endpoint budget caps. Two
things make that work, and both must survive a rebuild:

- `/etc/default/notify-telegram` is **root:claude, 640** (not root:root 600):
  the claude group must read the token to send. Trade-off accepted — any
  claude-user process can read the bot token; it's a send-only pager bot.
- `/var/lib/notify-telegram` is **root:claude, 2770** (setgid, group-writable):
  root units and the claude-run proxy append to the *same* daily count file,
  so they share one cap. Before 2026-07-11 the dir was root-only and every
  proxy-sent page silently bypassed the cap. The script normalizes these
  perms on every root-invoked run; count files are opened up to 660.
- Services sandboxed with `ProtectSystem=strict` that exec this helper also
  need `ReadWritePaths=/var/lib/notify-telegram` in their unit (uzella-proxy
  has it), or /var is mounted read-only and their sends go uncounted.

## Config & token rotation

`/etc/default/notify-telegram` sets `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`,
and optionally `NOTIFY_MAX_PER_DAY` (default 10).

The values **mirror** `DIRECTOR_TELEGRAM_TOKEN` / `DIRECTOR_TELEGRAM_ALLOWED_USER`
in `/opt/ai-agent-platform/.env`. The duplication is deliberate: root helpers
must not source a claude-writable file (privilege-escalation vector). **If the
bot token rotates, update both files.**

## Current senders / wiring

- **`backup.service`** — `OnFailure=notify-telegram@%n.service` pages
  `[SYSTEM] unit backup.service FAILED …` on hard unit failure.
- **`backup.sh`** — counts its `warn()` calls and sends one
  `[BACKUP] run … finished with N warning(s)` page at the end of any run that
  warned. This path matters most: the unit exits 0 on warnings, so
  `OnFailure=` alone would miss a broken off-site upload — exactly the
  failure mode that went silent for three weeks in June 2026.
- **`uzella-proxy`** (runs as claude) — `[CONTACT]` on each contact-form
  submission; `[ASK]` once when the ask endpoint's daily budget cap trips.
- **Any other unit:** add `OnFailure=notify-telegram@%n.service` under
  `[Unit]` — nothing else needed.
- **Any script/agent:** call the helper with its own agent name.

## Rate cap / storm behavior

The daily cap (default 10) is shared across **all** senders. When it's hit,
the next message is replaced by a single `[NOTIFY] notification storm …`
notice; everything after that is dropped silently but still logged to syslog.
Counters live in `/var/lib/notify-telegram/count-YYYYMMDD` (one line per sent
message, flock-guarded). Cap resets at midnight.

## Testing

```bash
notify-telegram test "hello from $(hostname -s)"        # expect: [TEST] hello …
systemctl start notify-telegram@test-unit.service        # expect: [SYSTEM] unit test-unit FAILED …
```

The second one *looks* like a real failure page — `test-unit` doesn't exist;
it just exercises the template path. Both count against the daily cap.

## Constraints (from the design spec — non-negotiable)

- Outbound-only. No polling, no inbound commands, ever.
- No secrets, tokens, or dump contents in message bodies — Telegram is an
  external service; treat every message as published.
- Delivery failures never propagate to the caller.
