# Server Maintenance — TODO

## Pending

- [ ] **Review gist summary script** — Find `collect_pipeline_stats_gist.sh` (or similar) in predictor_ingest and assess what pipeline stats are preserved in gist summaries. Determines whether 14-day backup retention is sufficient or needs to increase.

- [ ] **Add `claude` user to docker group** — Requires root: `sudo usermod -aG docker claude` + session restart. Needed so Claude Code can run `docker system df` and other Docker commands directly.

- [ ] **Clean up full Docker volume** — `/mnt/HC_Volume_103575430` is 100% full (70G). Docker data-root lives there. As root, run `docker system df -v` to identify what's consuming space. Likely candidates: old images, build cache, container logs. Critical — full disk can crash containers.

- [ ] **Clean up old predictor data** — In `/opt/predictor_ingest/data/`:
  - 43 `metrics_snapshot_*` dirs (~3M total) — keep latest 3, delete rest
  - 6 `feed_test_*` dirs (~60K) — safe to delete

## Completed (2026-04-05)

- [x] Extract server maintenance files from ai-agent-platform into `/opt/server-maintenance`
- [x] Update all hardcoded paths from `/opt/ai-agent-platform` → `/opt/server-maintenance`
- [x] Expand backup script: Caddy config, UFW rules, systemd units, predictor DBs, extractions
- [x] Set backup retention to 14 days (pending gist summary review)
- [x] Initialize git repo and push to github.com/dshorter/server-maintenance
