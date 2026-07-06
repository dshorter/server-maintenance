# Server Maintenance — TODO

## Pending

- [ ] **🔴 OFF-SITE BACKUPS DOWN since 2026-06-09 — B2 storage cap exceeded** (found 2026-06-10). Uploads fail with `403 storage_cap_exceeded` (`/tmp/backup-tar-20260610_033348.err`); backup.sh only WARNs by design so the unit still reports success. Root cause: the B2 lifecycle rule never deletes anything — backups use unique filenames so no file is ever "hidden", and a keep-prior-versions-for-7-days rule only deletes *hidden* versions. Bucket sits at 9.4 GiB / 16 objects going back to 2026-05-26. **Operator fix in B2 web UI (on-box key can't delete, by design):** (1) set lifecycle rule on `uzelhub-backups` to `daysFromUploadingToHiding: 7`, `daysFromHidingToDeleting: 1` (hides files 7 days after upload, deletes a day later); (2) check Caps & Alerts — cap is likely 10 GB; (3) optionally delete the pre-Jun-3 files manually to resume uploads immediately. Local backups unaffected.

- [ ] **Restore-verification oddity to check during first drill:** `host-2026060{6,7,8}*.tar.gz` are byte-identical in size (684841818) three days running — plausible for stable content but worth a checksum/extract comparison to rule out a stale-staging bug.

- [ ] **Investigate `ai-agent-platform.service` failed state** — In `failed` state since at least 2026-05-10. Containers run anyway via `unless-stopped`, so it's silently broken. `journalctl -u ai-agent-platform.service -n 100` before next reboot.

- [ ] **Remove `web-server` from `docker-compose.yml`** — Conflicts with caddy on `:80`, stays in `Created` state, not used. Caddy handles all reverse-proxying now.

- [ ] **Decide on retention review window** — Current setup: 14-day local + 7-day off-site B2. Originally wanted to check what pipeline stats are preserved in `predictor_ingest` gist summaries to confirm 14 days is enough. Re-open if that analysis hasn't happened and a real restore-need ever arises.

- [ ] **Add `claude` user to docker group** — Requires root: `sudo usermod -aG docker claude` + session restart. Needed so Claude Code can run `docker system df` and other Docker commands directly.

- [ ] **Clean up old predictor data** — In `/opt/predictor_ingest/data/`:
  - 43 `metrics_snapshot_*` dirs (~3M total) — keep latest 3, delete rest
  - 6 `feed_test_*` dirs (~60K) — safe to delete

- [ ] **Clean up typo'd dirs at `/opt/` root** — `Clone/`, `repo/`, `your/`, `=p`, `ai=agent-platform/`. Empty/no-content. Deferred from the _host reorg.

## Completed (2026-06-10)

- [x] **Added `pg_dumpall` to `backup.sh`** — dumps both `hvac_demo` and `ai_agent_platform` (the agents history: `agent_decisions`/`pipeline_runs`/`posts`) to `backups/postgres/postgres_all_<TS>.sql.gz`. Verified: dump is valid gzip, contains both databases and all 276 crew pipeline rows.
- [x] **Fixed off-site bundles containing NO database dumps** — the off-site tar's `--exclude='backups'` silently dropped the entire staging dir, so every bundle uploaded before 2026-06-10 lacks the ghost/predictor/n8n dumps the restore docs referenced. Fix: this run's dump files are hardlinked into `root/n8n-data/offsite-dumps-<TS>/` (not named "backups", so the exclude can't catch it) and removed after upload. `_host/README.md` backups + restore sections corrected.
- [x] **Blog outage (down since 2026-06-02 reboot) + self-heal for `server-maintenance.service`** — At the 2026-06-02 boot, `docker compose up` raced the docker daemon ("container name `/ghost-mysql` already in use" while old containers were still loading) and the oneshot unit gave up; blog stayed down ~8 days. Restarted ghost+ghost-mysql, then added `Restart=on-failure` + `RestartSec=10` to the unit (same pattern as `uzella-proxy.service`) so a transient boot failure retries instead of staying dead. Updated both `/etc/systemd/system/` and the repo copy.

## Completed (2026-05-29)

- [x] **Reorganized host-level docs into `/opt/_host/`** — `/opt/README.md` and `/opt/incident-2026-05-11/` moved into `/opt/_host/{README.md, incidents/2026-05-11/}`. Tiny pointer left at `/opt/README.md`. backup.sh tar arg list collapsed `opt/README.md + opt/incident-2026-05-11 + opt/incident-2026-05-11.tar.gz` to one `opt/_host`.

## Completed (2026-05-27)

- [x] **Installed `server-maintenance.service`** — file existed since 2026-05-10 but was never `install`-ed to `/etc/systemd/system/` + enabled. `ExecStart` corrected to target only `ghost-mysql ghost` (avoids compose-file overlap). Resolved the recurring "ghost in `Created` state after reboot" pattern (3 occurrences: 2026-05-09, 2026-05-26, 2026-05-27). Verified surviving a reboot the same day.
- [x] **`backup.sh` defaults `BACKUP_OFFSITE_REMOTE=b2:uzelhub-backups`** when env var not set, so `safe-reboot`'s direct invocation also gets off-site coverage. Override with explicit empty value for local-only.

## Completed (2026-05-26)

- [x] **Off-site backup to Backblaze B2 wired end-to-end** — `scripts/backup.sh` extended to stream a single `.tar.gz` to B2 via `rclone rcat`. New `backup.timer` + `backup.service` units. B2 application key scoped Read+Write minus `deleteFiles` (compromise-resistant). 7-day server-side lifecycle.
- [x] **Fixed ghost-content volume name bug in `scripts/backup.sh`** — was backing up the orphan `ghost-content` volume instead of the live `server-maintenance_ghost-content`.
- [x] **README rewritten** — corrected services table (only ghost+ghost-mysql actually owned here, not the legacy postgres/n8n/nginx/ngrok), removed the wrong "ngrok is the public listener" claim, added Backups section, added repository-layout entries for the new files.

## Completed (2026-04-18)

- [x] **Clean up full Docker volume** — Reclaimed ~61GB:
  `docker image prune -f` (~10GB) + `docker builder prune -f` (51.36GB of build
  cache from 3-4 months of rebuilds). Permanent fix landed in this repo:
  `docker/daemon.json` caps log + builder cache; `docker-prune.timer` runs
  weekly. See "Docker Disk Hygiene" section in README.

## Completed (2026-04-05)

- [x] Extract server maintenance files from ai-agent-platform into `/opt/server-maintenance`
- [x] Update all hardcoded paths from `/opt/ai-agent-platform` → `/opt/server-maintenance`
- [x] Expand backup script: Caddy config, UFW rules, systemd units, predictor DBs, extractions
- [x] Set backup retention to 14 days (pending gist summary review)
- [x] Initialize git repo and push to github.com/dshorter/server-maintenance
