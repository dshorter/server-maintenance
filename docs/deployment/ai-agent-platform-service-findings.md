# `ai-agent-platform.service` / `agent-platform-health` — investigation findings

**Date:** 2026-07-11
**Trigger:** `ai-agent-platform.service` had been in `failed` state since at least
2026-05-10 (tracked as calendar VTODO
`investigate-ai-agent-platform-service-failed@ai-agent-platform`, since marked
COMPLETED — the *investigation* is done; the underlying issue described below
is not yet fixed).
**Status:** ~~Read-only investigation. No systemd units, scripts, or containers
were changed.~~ **RESOLVED 2026-07-14 — see [Resolution](#resolution-2026-07-14)
at the end.** The findings below are kept as written for the record.

---

## TL;DR

Both `ai-agent-platform.service` (a oneshot "bring the stack up" unit) and
`agent-platform-health.service`/`.timer` (an hourly health-check + auto-recovery
job) were installed together by `docs/01-infrastructure/deployment/safe-reboot/install.sh`
back on 2025-10-14, originally scoped to `/opt/ai-agent-platform`. At some point
— almost certainly during the 2026-04-05 server-maintenance extraction — the
live `ai-agent-platform.service` unit on disk got overwritten with a copy whose
`WorkingDirectory` points at `/opt/server-maintenance` instead. The health-check
script has the same directory hardcoded and was never updated either.

Practical effect:
- `ai-agent-platform.service` fails immediately on every attempted start (oneshot,
  no retry) and has been dead since ~2026-05-10. **Nothing depends on it** — the
  real stack (`ngrok`, `postgres`/`hvac-postgres`, `n8n` from ai-agent-platform's
  actual `docker-compose.yml`) is up and healthy, kept alive by Docker's own
  `restart: unless-stopped` policy, not by this unit.
- `agent-platform-health.timer` is **live and still firing hourly** (enabled,
  active, last fired 2026-07-11 15:40 EDT). Its script also `cd`s into
  `/opt/server-maintenance` and runs `docker compose up -d` there every single
  run, then checks n8n/ngrok/predictor-pipeline health and disk space in that
  wrong context, and will `docker restart` n8n or ngrok as "recovery" if a check
  fails. It has been failing (exit 1) at least as of this run. This is the part
  that actually matters operationally — it's not dead weight, it's live
  automation running hourly against the wrong directory.

## What was found, in detail

### 1. `ai-agent-platform.service` — misconfigured, not just broken

Live unit at `/etc/systemd/system/ai-agent-platform.service`:

```ini
[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/server-maintenance
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0
```

No service filter on `ExecStart` — if it ran successfully, it would bring up
server-maintenance's *entire* compose file (`postgres`, `predictor`, `web`,
`ngrok`, `ghost-mysql`, `ghost`), which duplicates service names already
running under the real `ai-agent-platform` compose project. `server-maintenance.service`'s
own unit file has a comment explicitly warning about this exact collision
("Bringing them all up would fight for :80, :5432, :5678. Always target the
ghost services explicitly.") — this unit does the thing that comment warns against.

No `Restart=` directive means systemd doesn't retry it; it just sits `failed`
until something intervenes.

### 2. `agent-platform-health.service` / `.timer` — live, hourly, same bug

`/usr/local/sbin/agent-platform-health` (installed 2025-10-14, unmodified since):

```bash
PROJECT_DIR="/opt/server-maintenance"
...
ensure_stack_running() {
    cd "$PROJECT_DIR" || { alert "..."; return 1; }
    $COMPOSE up -d || { alert "Failed to start Docker Compose stack"; return 1; }
}
```

Every hourly run: `cd /opt/server-maintenance && docker compose up -d`, then
checks `n8n` (container status + `:5678/healthz`), `ngrok` (container status +
`:4040/api/tunnels`), `predictor-pipeline` (container status + DB file size +
recent-backup check), disk space on `$PROJECT_DIR`, and recent n8n error-log
volume. On `n8n`/`ngrok` failure it auto-`docker restart`s the container.

Timer: `agent-platform-health.timer`, enabled, active, fires 2 min after boot
then hourly. Both timer and service share a start timestamp of
2026-06-18 22:50 with the moment `ai-agent-platform.service` last failed —
almost certainly a reboot or `daemon-reload` event, not a coincidence.

Manually re-running the script during this investigation: exit code 1
(couldn't confirm which specific check failed — `/var/log/agent-platform-health.log`
isn't writable by the investigating session; `journalctl -u agent-platform-health.service`
needs broader permissions than were available).

**Since `predictor-pipeline` doesn't exist as a running container** (confirmed
separately: exited 3 months ago, pipeline is dormant per predictor's own
CLAUDE.md/ADR-010), `check_predictor_health` is one very plausible standing
failure source on every run, independent of the directory bug.

### 3. The two tracked copies of `ai-agent-platform.service` disagree

| Location | `WorkingDirectory` |
|---|---|
| `/etc/systemd/system/ai-agent-platform.service` (live) | `/opt/server-maintenance` |
| `server-maintenance/systemd/etc_systemd_system_ai-agent-platform.service` | `/opt/server-maintenance` (matches live) |
| `ai-agent-platform/docs/01-infrastructure/deployment/safe-reboot/etc_systemd_system_ai-agent-platform.service` | `/opt/ai-agent-platform` (the original/correct scoping) |

The ai-agent-platform repo's copy is the original — `docs/01-infrastructure/deployment/safe-reboot/DEPLOYMENT.md`
(dated 2025-10-14) describes installing this whole bundle (`safe-reboot` script,
health check script + service + timer, and this service) scoped to
`/opt/ai-agent-platform`. The server-maintenance repo's copy is a divergent
fork with the path swapped — most likely produced during the 2026-04-05
"extract server maintenance from ai-agent-platform" work (server-maintenance's
own TODO.md documents that migration explicitly rewrote hardcoded
`/opt/ai-agent-platform` → `/opt/server-maintenance` paths across the extracted
files) — but this particular unit kept its original name
(`ai-agent-platform.service`) instead of being renamed the way
`server-maintenance.service` was properly split out as its own distinct,
correctly-scoped unit. The live system currently matches server-maintenance's
(wrong-for-its-own-name) copy, not ai-agent-platform's (correct) one.

## What's NOT affected

The actually-running stack is fine and doesn't depend on any of this:
- `ngrok`, `postgres` (container name `hvac-postgres`), `n8n` — running 13
  days, healthy, under the real `/opt/ai-agent-platform/docker-compose.yml`
  compose project, kept up by Docker's `restart: unless-stopped` policy and
  the (separately healthy, enabled) Docker daemon.
- `ghost`, `ghost-mysql` — running 13 days, healthy, correctly managed by
  `server-maintenance.service` (properly scoped, `Restart=on-failure`).
- The Director agent (`pipelines/director`) — runs as a detached `nohup`
  process, entirely independent of Docker/systemd. Already self-flagged in
  `docs/director/devlog.md` as needing "a proper systemd unit" of its own
  eventually — a different, forward-looking piece of work, not a fix to
  either broken unit above.

## Open questions (not decided — no action taken)

1. Does the hourly `agent-platform-health` recovery logic (`docker restart`
   on n8n/ngrok failure) need to keep running at all, given it's operating
   against the wrong `PROJECT_DIR` and one of its checks (`predictor-pipeline`)
   targets a container that no longer exists? Worth checking `/var/log/agent-platform-health.log`
   (root-readable) or `journalctl -u agent-platform-health.service` with
   broader permissions to see the actual failure pattern and whether the
   `docker restart` recovery has ever fired unexpectedly.
2. If the safe-reboot bundle is still wanted, the fix is: re-point
   `WorkingDirectory` (and the health script's `PROJECT_DIR`) at
   `/opt/ai-agent-platform`, reconcile which repo owns the tracked copy,
   and either drop or update the `predictor-pipeline` check. If it's not
   wanted, all three units (`ai-agent-platform.service`,
   `agent-platform-health.service`, `agent-platform-health.timer`) plus
   `/usr/local/sbin/agent-platform-health` and `/usr/local/sbin/safe-reboot`
   are candidates for removal — but that's a live-host change requiring root,
   not something to do without deciding the above first.
3. Which repo should own the reconciled copy going forward, given it's really
   an ai-agent-platform-scoped concern that got forked into server-maintenance
   mid-migration.

---

## Resolution (2026-07-14)

All three open questions were decided and applied after the first `safe-reboot`
run through the overhauled backup pipeline (root access available this time).

**Q2 — keep or remove the bundle?** Split decision: the health check and
safe-reboot are wanted; the "bring the stack up" unit is not.

- **`ai-agent-platform.service` retired.** Disabled and its unit file removed
  from `/etc/systemd/system/` (timestamped `.backup.*` copies remain there).
  Nothing replaces it because nothing needs to: the ai-agent-platform stack
  (`n8n`, `hvac-postgres`, `ngrok`) revives at boot via
  `restart: unless-stopped`, and the ghost pair is owned by
  `server-maintenance.service`. The tracked copy
  `systemd/etc_systemd_system_ai-agent-platform.service` was deleted from this
  repo, and `install.sh` no longer installs or enables it.
- **`agent-platform-health` rewritten** (live at `/usr/local/sbin/`, synced to
  `scripts/usr_local_sbin_agent-platform-health.sh`). Key changes: the
  `ensure_stack_running`/`compose up -d` step is gone entirely (that was the
  wrong-directory hazard — boot revival is owned by restart policies and
  `server-maintenance.service`, never by the health check); expected containers
  are verified by exact-name `docker inspect` (the old `--filter name=` was a
  substring match, so a down `ghost` hid behind a running `ghost-mysql`); the
  predictor check now inspects on-host data
  (`/opt/predictor_ingest/data/db/predictor.db` + the `/var/backups/host/predictor`
  staging dir) instead of exec'ing into the long-dead `predictor-pipeline`
  container. The unit gained `OnFailure=notify-telegram@%n.service`, so a
  failing hourly run pages the shared Telegram channel instead of failing
  silently. Verified passing on the hourly timer since the rewrite.
- **`safe-reboot` rewritten** (same sync). It now quiesces (n8n executions,
  predictor pipeline lock), takes a verified backup, and reboots **without
  stopping any containers** — an explicit stop is exactly what strands
  `unless-stopped` containers at next boot. Rationale is in the script header.

**Q1 — does the hourly recovery logic need to keep running?** Yes, kept — but
only the `docker restart` recovery for n8n/ngrok. With the directory bug and
the dead-container probe removed, the checks are meaningful again.

**Q3 — which repo owns the reconciled copies?** server-maintenance. Live files
under `/usr/local/sbin/` and `/etc/systemd/system/` are the runtime truth;
`scripts/usr_local_sbin_*.sh` and `systemd/etc_systemd_system_agent-platform-health.*`
here are the tracked sources, synced 2026-07-14. The stale original bundle in
ai-agent-platform's `docs/01-infrastructure/deployment/safe-reboot/` (including
a runnable `install.sh` that would have overwritten the rewritten scripts) was
deleted from that repo's working tree on 2026-07-14 — git history retains it.
