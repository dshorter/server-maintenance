# Server Maintenance — TODO

## Pending

- [ ] **Give safe-reboot a working n8n quiesce probe** — Opened 2026-09-07. `wait_for_executions` asked `n8n execute:list --status=running`, a subcommand this n8n does not have (its CLI offers `execute`, `execute-batch`, `list:workflow` and no running-execution query), so the probe had always failed silently and returned success after a 10-second sleep. It now says so loudly every run, but n8n is genuinely not quiesced. Closing it means choosing between an n8n API key for `/api/v1/executions?status=running` and reading n8n's sqlite directly — **a decision, not a detail**: the first adds a credential to the host's plumbing, the second couples this script to n8n's schema. Not urgent while nothing schedules n8n workflows, which is worth confirming before spending anything on it.
- [ ] **`check-anthropic-credit` has a script and no unit** — `/opt/_host/scripts/check-anthropic-credit` exists (2026-07-21) but no `anthropic-credit-check.service`/`.timer` is installed and nothing references it, so the [BILLING] pager described in the backup docs does not run. Same finding as the 2026-09-05 newsroom handoff's "credit monitor — built, committed twice, units never installed". Install or retire it; a monitor that exists only as a file is worse than none, because it is remembered as coverage.
- [ ] **Off-site uploads fail on the B2 storage cap** — Opened 2026-10-21, cause found 2026-10-26. Failed on 27 of 50 days (2026-09-01..10-20). The journal tail that db399e3 added caught the 10-23 and 10-26 failures: `storage cap exceeded (403 storage_cap_exceeded)`. Uploads fail until a prune frees room, then fail again. Fix: raise the cap on B2's Caps & Alerts page, or shrink the bundle (the next item, and maybe predictor_ingest's data/raw at 4.2 GB and data/graphs at 4.8 GB).
- [ ] **Check the bucket before changing Object Lock** — Opened 2026-10-21. On 10-20 the operator was asked to lower the bucket's default retention from 7 to 3 days so the 4-day prune can work. But on 10-21 the 4-day prune exited clean while the 10-16 and 10-17 bundles were in its range, which a 7-day governance lock should have blocked. Either the lock isn't applied to these uploads or the prune found nothing. A read-only listing settles it: `sudo rclone --config /root/.config/rclone/rclone.conf lsl b2:uzelhub-backups/$(hostname -s)`. If 10-16 and 10-17 are gone, the newest week isn't immutable: the console change is moot, and the 8-day prune's comment in backup.sh and the ransomware-resistance note need correcting.
- [ ] **The off-site bundle carries the predictor databases twice** — Opened 2026-10-21. The tar includes opt/predictor_ingest with data/db (2.1 GB) and also this run's gzipped snapshots via offsite-dumps-<TS>. Excluding data/db from the tar would drop the duplicate; the snapshots are the consistent copy.
- [x] **Cap the journal lower** — Opened 2026-10-21, done 2026-10-26: operator ran `CAP=500M scripts/cap-journal.sh --lower`; 1.8 GB → 470 MB.
- [x] **Move local backups off the root disk** — Done 2026-10-26. Root was at 98%; /var/backups/host held about 8 GB. The operator ran `scripts/move-backups-to-volume.sh`: the files now live on the 70 GB volume and /var/backups/host is a symlink to them. Root went 94% → 72%.
- [ ] **Remove root's old Claude Code install** — Pending since 2026-07-16 (root→claude consolidation): about 868 MB under /root/.claude. Copy root's post-07-16 transcripts first.
- [ ] **Decide on retention review window** — Current setup: 14-day local + 4-day off-site B2 (was 7 until 2026-10-20, db399e3). Originally wanted to check what pipeline stats are preserved in `predictor_ingest` gist summaries to confirm 14 days is enough. Re-open if that analysis hasn't happened and a real restore-need ever arises.

## Tracked in the ops calendar (2026-07-11)

Single source of truth for these moved to `/opt/ai-agent-platform/ops/calendar.ics` (see
`ops/CALENDAR.md`) — dated, reminder-bearing, and lifecycle-tracked via `calendar-mark`
instead of a checkbox here. Details preserved in each VTODO's `DESCRIPTION`.

- `investigate-ai-agent-platform-service-failed@ai-agent-platform` — investigation
  complete (marked COMPLETED early, 2026-07-11); underlying issue resolved
  2026-07-14: unit retired, health check + safe-reboot rewritten. See the
  Resolution section of
  [docs/deployment/ai-agent-platform-service-findings.md](docs/deployment/ai-agent-platform-service-findings.md)
- `remove-web-server-from-compose@ai-agent-platform` — due 2026-07-18
- `cleanup-old-predictor-data@ai-agent-platform` — due 2026-07-18
- `cleanup-opt-stray-dirs@ai-agent-platform` — due 2026-07-18
- `restore-verification-checksum-check@ai-agent-platform` — due 2026-08-03 (chained via
  `RELATED-TO` to `backup-restore-drill-monthly@ai-agent-platform`, the next scheduled drill)

## Completed (2026-07-11)

- [x] **Off-site backups (B2 storage cap) resolved** — Was down since 2026-06-09 (`403 storage_cap_exceeded`, root cause: B2 lifecycle rule never hid old unique-named files so nothing aged out). Verified 2026-07-11: no `/tmp/backup-tar-*.err` files since 2026-07-02 17:47, and today's 03:43 `backup.timer` run left no error — uploads have been succeeding since ~2026-07-03. Operator must have applied the B2 lifecycle/cap fix; no code change needed on this end.
- [x] **`claude` user is in the `docker` group** — Verified 2026-07-11 (`groups claude` → `claude users docker`). Already done; no longer blocking direct `docker system df`-type commands.

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
