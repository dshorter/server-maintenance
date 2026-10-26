# Server Maintenance

Host-level housekeeping for the Hetzner VPS that hosts uzelhub.com and friends.

**What this repo owns:**

- **The Ghost blog stack** (`ghost` + `ghost-mysql` containers) serving `blog.uzelhub.com`
- **`safe-reboot`** — graceful shutdown + reboot orchestration (installed at `/usr/local/sbin/safe-reboot`, source under `scripts/`)
- **`claude-opt`** — one word from a root shell into a Claude Code session as the `claude` user in `/opt` (installed at `/usr/local/sbin/claude-opt`, source under `scripts/`)
- **The off-site backup system** — daily `backup.timer` → `backup.service` running `scripts/backup.sh` → Backblaze B2
- **Docker disk hygiene** — `docker-prune.timer` + `daemon.json` log/cache caps
- **Host health checks** — `agent-platform-health.timer` + script
- **Operator alerting** — `notify-telegram` (shared Telegram channel, `[AGENT]`-prefixed messages) + `notify-telegram@.service` OnFailure template — see `docs/alerting/telegram-notifications.md` (added 2026-07-02)

**What this repo does NOT own** (despite what `docker-compose.yml` might suggest):

- **`n8n`, `hvac-postgres`, `ngrok`, `web-server` containers** — all run from `/opt/ai-agent-platform/docker-compose.yml`. This repo's compose file *also* defines them as a legacy of when this project ran the whole stack, but per `com.docker.compose.project` labels they belong to `ai-agent-platform`. **Never `docker compose up` from this directory without naming services explicitly** — it will fight for `:80`, `:5432`, `:5678`. The installed `server-maintenance.service` correctly targets only `ghost-mysql ghost`.

See `/opt/_host/README.md` for the cross-project map of the whole `/opt` tree.

---

## Repository Layout

```
server-maintenance/
├── docker-compose.yml          # Compose file — IMPORTANT: this repo only owns ghost+ghost-mysql.
│                               # Other services defined here are legacy; run from ai-agent-platform.
├── server-maintenance.service  # Boot-time ghost autostart (installed 2026-05-27 — was a file-on-disk-only since 2026-05-10)
├── docker/
│   └── daemon.json             # Docker daemon config (data-root, log rotation, builder GC)
├── nginx/
│   └── nginx.conf              # Reverse proxy / routing config (legacy — caddy handles this now)
├── scripts/
│   ├── backup.sh               # Daily backup: local staging + off-site B2 upload (14d local / 7d off-site)
│   ├── rclone.conf.example     # Template for /root/.config/rclone/rclone.conf (B2 credentials)
│   ├── deploy.sh               # Pull + restart stack
│   ├── monitor.sh              # Health check with auto-restart
│   ├── install.sh              # One-command installer for safe-reboot system
│   ├── usr_local_sbin_safe-reboot.sh         # Graceful shutdown + reboot
│   ├── usr_local_sbin_agent-platform-health.sh  # Health checks + auto-recovery
│   ├── usr_local_sbin_notify-telegram.sh     # Shared-channel Telegram pager ([AGENT]-prefixed)
│   ├── usr_local_sbin_claude-opt.sh          # root -> Claude Code as `claude`, cwd /opt
│   └── install-claude-opt.sh                 # Installer + smoke tests for claude-opt
├── systemd/
│   ├── etc_systemd_system_agent-platform-health.service # Health check service
│   ├── etc_systemd_system_agent-platform-health.timer   # 2 min after boot + hourly
│   ├── etc_systemd_system_backup.service                # Calls scripts/backup.sh (oneshot)
│   ├── etc_systemd_system_backup.timer                  # Daily ~03:30 with ±15 min jitter
│   ├── etc_systemd_system_docker-prune.service          # Dangling image + build cache prune
│   ├── etc_systemd_system_docker-prune.timer            # Weekly prune timer (Sun 03:00)
│   └── etc_systemd_system_notify-telegram@.service      # OnFailure= template → Telegram page
├── docs/
│   ├── alerting/
│   │   └── telegram-notifications.md  # notify-telegram: usage, wiring, rate cap, token rotation
│   ├── deployment/
│   │   ├── DEPLOYMENT.md       # Full deployment workflow (local → GitHub → VPS)
│   │   ├── Changes.md          # Safe-reboot system changelog (Phase 1, 2025-10-14)
│   │   └── landing_page_deployment.md  # Nginx + landing page setup (legacy reference)
│   ├── networking/
│   │   └── security-architecture.md    # Zero-trust architecture doc
│   └── secrets/
│       └── 1Password-Vault-Structure-Guide.md  # Secrets management
├── .github/workflows/
│   └── deploy.yml              # CI/CD: auto-deploy on push to main
├── .env                        # GHOST_MYSQL_ROOT_PASSWORD, GHOST_DB_PASSWORD, etc.
├── .gitignore
└── LICENSE
```

---

## Quick Reference

```bash
# Manual backup run (local + off-site B2)
sudo systemctl start backup.service
sudo journalctl -u backup.service --since '5 minutes ago' --no-pager

# Local-only backup (skip off-site — useful for testing without B2 reachability)
sudo BACKUP_OFFSITE_REMOTE= /opt/server-maintenance/scripts/backup.sh

# Check daily backup schedule
systemctl list-timers backup.timer

# Verify off-site upload landed
sudo rclone ls b2:uzelhub-backups/ | tail -5

# Deploy (pull latest + restart ghost)
./scripts/deploy.sh

# Safe reboot (waits for scheduled agent work, backs up local+off-site, reboots)
# Containers are NOT stopped — see the script header for why (2026-07-14).
sudo safe-reboot

# Rehearse it: every read-only check, stopping before the backup and the reboot
sudo safe-reboot --check

# Install/refresh safe-reboot itself (backs up, verifies with --check, rolls back on failure)
sudo ./scripts/install-safe-reboot.sh --dry-run
sudo ./scripts/install-safe-reboot.sh

# Install/refresh the wider safe-reboot system (systemd units + scripts)
sudo ./scripts/install.sh

# Manually bring ghost back if it didn't restart after a reboot
sudo systemctl start server-maintenance.service
docker ps --filter 'name=ghost'

# Check host-level timers
systemctl list-timers agent-platform-health.timer docker-prune.timer backup.timer
```

---

## Public access

Caddy (`/etc/caddy/Caddyfile`) is the only thing bound to `:80`/`:443`. All
backends listen on `127.0.0.1`. The Ghost blog backend (this repo's primary
service) sits at `127.0.0.1:2368`; Caddy reverse-proxies `blog.uzelhub.com` to
it.

> **Legacy note:** older versions of this README claimed "Public access is via
> ngrok tunnel only." That stopped being true once Caddy was introduced. ngrok
> is now used only as a webhook target for n8n (`agents-platform.ngrok.io` →
> the ai-agent-platform stack), not as a general public listener.

---

## Services actually owned (live state)

| Container     | Image          | Port (localhost) | Purpose                    | Notes                                              |
|---------------|----------------|------------------|----------------------------|----------------------------------------------------|
| `ghost`       | `ghost:5-alpine` | 2368           | Ghost blog (blog.uzelhub.com) | Caddy fronts it; admin at `/ghost`               |
| `ghost-mysql` | `mysql:8.0`    | (internal only)  | Ghost's MySQL backend      | `--innodb-buffer-pool-size=64M` for 2GB host       |

The volumes `server-maintenance_ghost-mysql-data` and `server-maintenance_ghost-content`
hold the data; both captured by the daily backup.

> **Orphan volumes** to be aware of: `ghost-content` (anonymous, not the live
> one) and `server-maintenance_postgres-data` (left over from when this project
> ran postgres). Neither is in use. `docker volume rm` when convenient.

---

## What safe-reboot waits for

Reviewed 2026-09-07. The estate's scheduled work lives in systemd timers, not
in containers, so the quiesce list is a list of **units** and it is data —
adding a timer means adding a line to `QUIESCE_UNITS` in the script, not
writing code.

| Waits for | Why |
|---|---|
| `predictor-daily@{film,semiconductors,weapons_detection}` | A `make daily` per domain. The film run on 2026-09-07 held the box 06:00–06:53 and spent $1.70. |
| `predictor-staleness` | Every 6h. |
| `scout-pass` | The Scout's paid prospecting pass, 05:45. Its forward cursor only advances on persisted jewels, so a kill costs the spend, not the coverage. |
| `sysadmin-daily`, `director-morning-brief` | Scheduled agent passes. |
| `backup.service` | 03:30, and `backup.sh` takes no lock of its own — two concurrent runs would share a staging dir and a B2 prune. A real run refuses rather than waits. |

Bounded by `SAFE_REBOOT_AGENT_WAIT` (default 1200s). On timeout it **warns,
pages and proceeds**: the only thing that aborts a reboot is a failed backup.

**Two things it does not wait for.** n8n executions — the probe it used asks
for a subcommand this n8n does not have, so it has never worked; it now says
so on every run rather than printing a checkmark (TODO.md). And any container,
deliberately, since 2026-07-14 — see the script header.

Rehearse the whole read-only half any time with `sudo safe-reboot --check`.

---

## Backups

Daily script + timer, runs at ~03:30 local with 15-minute jitter. Also invoked
by `safe-reboot` before any container shutdown.

**Local staging:** `/var/backups/host/` — root-only 700, 14-day retention via `find -mtime`. **On the 70 GB volume since 2026-10-26:** the files live in `/mnt/HC_Volume_103575430/backups/host/` and `/var/backups/host` is a symlink to it, so readers keep the old path (`scripts/move-backups-to-volume.sh` made the move; the root disk was at 98%). If the volume isn't mounted, `backup.sh` writes to `/var/backups/host-fallback` on root and warns. A predictor database that hasn't changed since its last snapshot keeps one copy, renamed to the latest run (2026-10-20; a paused domain's database otherwise fills the window with identical copies). *(Moved 2026-07-02 from `/root/n8n-data/backups/`, which is mounted into the n8n container and let it read/delete every dump. n8n workflow exports still land there but are moved into staging immediately.)*

**Off-site:** Backblaze B2, bucket `uzelhub-backups`, prefix `<hostname>/<YYYY>/<MM>/host-<TIMESTAMP>.tar.gz`. 4-day retention (2026-10-20, was 7) enforced by `backup.sh` itself: `rclone delete --min-age 4d --b2-hard-delete` after a successful upload, so failed uploads can't empty the bucket, plus the 8-day prune before each upload as the floor. The bucket's Object Lock default retention (7 days, governance) must be 3 days or less for the 4-day prune to take full effect; that is set in the B2 console. Failed uploads now log the error file's tail to the journal, since /tmp is wiped on reboot. The B2 lifecycle rule never applied to these never-hidden unique filenames; see `/opt/_host/README.md` §Backups for the June 2026 storage-cap incident.

**Alerting:** any warning in a run (including off-site failures) sends one `[BACKUP]` Telegram page; hard unit failure pages via `OnFailure=` — see `docs/alerting/telegram-notifications.md`.

### What's captured

`scripts/backup.sh` dumps the running databases (ghost MySQL, predictor SQLite),
copies live config files, then streams a single `.tar.gz` of the host-significant
paths directly to B2 via `rclone rcat` (no intermediate file on local disk).

Covered: `/opt/_host`, `/opt/server-maintenance`, `/opt/uzelhub-web`,
`/opt/predictor_ingest`, `/opt/ai-agent-platform`, `/opt/rag_pipeline/data`,
`/root/n8n-data`, `/etc/caddy`, all `*.service` / `*.timer` at top of
`/etc/systemd/system/`, `/usr/local/sbin/agent-platform-health`,
`/usr/local/sbin/safe-reboot`.

Excluded: `.git`, `node_modules`, `__pycache__`, `.ragvenv*`, `*.zip`, local
backups subdirs (to avoid recursive bloat).

### B2 credentials

- Application key scoped to `uzelhub-backups` only. Capabilities: `writeFiles`,
  `listBuckets`, `listFiles`, `readFiles`. **Excludes `deleteFiles` and
  `writeBuckets`** — a compromised VPS cannot wipe history or create buckets.
- Lives in `/root/.config/rclone/rclone.conf` (chmod 600). Template at
  `scripts/rclone.conf.example`.
- Lifecycle deletion happens server-side at B2, not on the VPS. The key can't
  override it.

### safe-reboot integration

`backup.sh` defaults `BACKUP_OFFSITE_REMOTE=b2:uzelhub-backups` if not set, so
direct invocations from `safe-reboot` get off-site coverage just like the daily
timer. Override with `BACKUP_OFFSITE_REMOTE= ` (explicit empty) to force
local-only.

A failed off-site upload logs `WARNING` but does **not** fail `backup.sh` — so
a transient B2 outage won't block a reboot.

### Restore quick reference

1. Pull the latest `host-*.tar.gz` from B2 (needs an admin-level B2 key with
   read access — the on-box key has it).
2. Extract: `tar xzf host-*.tar.gz -C /restore-staging/`
3. Inside: `offsite-dumps-<TIMESTAMP>/` at the top of the bundle holds that run's dumps
   (bundles before 2026-10-27 have it at `root/offsite-dumps-<TIMESTAMP>/`, and
   before 2026-07-11 at `root/n8n-data/offsite-dumps-<TIMESTAMP>/`)
   with ghost SQL, `postgres_all_*.sql.gz`, predictor `*.db.gz`, n8n sqlite and system
   configs; `etc/`, `opt/`, `usr/local/sbin/` are verbatim trees ready to
   copy back. (Bundles before 2026-06-10 contain no dumps — exclude bug.)
   Predictor snapshots are gzipped as of 2026-09-03; bundles older than that
   carry them as raw `*.db`.
4. Ghost: `gunzip -c ghost_db_*.sql.gz | docker exec -i ghost-mysql mysql -uroot -p"$ROOT_PW" ghost_prod`
5. Postgres (both `hvac_demo` and `ai_agent_platform`): `gunzip -c postgres_all_*.sql.gz | docker exec -i hvac-postgres psql -U hvac_user -d postgres` (`pg_dumpall` added 2026-06-10 — the "known gap" note that used to live here is closed).
6. Predictor: `gunzip -c film_<TIMESTAMP>.db.gz > /opt/predictor_ingest/data/db/film.db` (stop the daily timers first: `systemctl stop predictor-daily@film.timer`).

---

## Docker Disk Hygiene

Docker ships with no automatic cleanup — build cache and container logs grow
unbounded. This repo installs three pieces of protection:

1. **`/etc/docker/daemon.json`** (`docker/daemon.json`):
   - Caps per-container logs at 50MB × 3 files
   - Caps BuildKit cache at 10GB (auto-GC above that)
   - Pins `data-root` to the Hetzner volume (`/mnt/HC_Volume_103575430/docker`)

2. **`docker-prune.service`** — oneshot that runs `docker image prune -f` +
   `docker builder prune -f`. Safe flags only: never touches containers, tagged
   images, or named volumes.

3. **`docker-prune.timer`** — fires the prune weekly (Sun 03:00).

Both are installed and enabled by `scripts/install.sh`. Manual run:
```bash
sudo systemctl start docker-prune.service
journalctl -u docker-prune.service -n 50
```

---

## Recurring failures worth memorizing

- **Ghost in `Created` state after reboot.** Recurred three times before the
  fix landed (2026-05-09, 2026-05-26, 2026-05-27). Root cause: the
  `server-maintenance.service` unit file had been created here but never
  installed to `/etc/systemd/system/`. Fix: `sudo install -m 644
  server-maintenance.service /etc/systemd/system/ && sudo systemctl daemon-reload
  && sudo systemctl enable --now server-maintenance.service`. Verified surviving
  a reboot on 2026-05-27.
- **`web-server` container stuck in `Created`.** Conflicts with caddy on `:80`.
  Not used. Safe to remove from `docker-compose.yml` when convenient.
- **`ai-agent-platform.service` in `failed` state.** Quietly broken since
  2026-05-10 (containers ran anyway via `unless-stopped`). Resolved 2026-07-14
  by retiring the unit entirely — nothing depended on it, and a successful run
  would have collided with the ai-agent-platform compose project. Full history:
  [docs/deployment/ai-agent-platform-service-findings.md](docs/deployment/ai-agent-platform-service-findings.md).

---

## Origin

Extracted from [ai-agent-platform](https://github.com/dshorter/ai-agent-platform)
to separate server ops from application code. Then the Ghost blog stack moved
into this repo (2026-04), so the "project-agnostic" framing of the early days
isn't strictly true anymore — this is now "host ops *and* the Ghost stack."
