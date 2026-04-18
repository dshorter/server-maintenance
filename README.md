# Server Maintenance

Server-level infrastructure scripts, configuration, and documentation for the Hetzner VPS hosting the AI Agent Platform stack.

This repo is **project-agnostic** — it manages the server and Docker services, not application logic.

---

## Repository Layout

```
server-maintenance/
├── docker-compose.yml          # Docker stack definition (postgres, n8n, nginx, ngrok)
├── docker/
│   └── daemon.json             # Docker daemon config (data-root, log rotation, builder GC)
├── nginx/
│   └── nginx.conf              # Reverse proxy / routing config
├── scripts/
│   ├── deploy.sh               # Pull + restart stack
│   ├── backup.sh               # n8n workflow + DB backup (7-day rotation)
│   ├── monitor.sh              # Health check with auto-restart
│   ├── install.sh              # One-command installer for safe-reboot system
│   ├── usr_local_sbin_safe-reboot.sh         # Graceful shutdown + reboot
│   └── usr_local_sbin_agent-platform-health.sh  # Health checks + auto-recovery
├── systemd/
│   ├── etc_systemd_system_ai-agent-platform.service     # Boot-time docker compose up
│   ├── etc_systemd_system_agent-platform-health.service  # Health check service
│   ├── etc_systemd_system_agent-platform-health.timer    # Hourly health check timer
│   ├── etc_systemd_system_docker-prune.service           # Dangling image + build cache prune
│   └── etc_systemd_system_docker-prune.timer             # Weekly prune timer (Sun 03:00)
├── docs/
│   ├── deployment/
│   │   ├── DEPLOYMENT.md       # Full deployment workflow (local → GitHub → VPS)
│   │   ├── Changes.md          # Safe-reboot system changelog
│   │   └── landing_page_deployment.md  # Nginx + landing page setup
│   ├── networking/
│   │   └── security-architecture.md    # Zero-trust architecture doc
│   └── secrets/
│       └── 1Password-Vault-Structure-Guide.md  # Secrets management
├── .github/workflows/
│   └── deploy.yml              # CI/CD: auto-deploy on push to main
├── .env                        # Environment variables
├── .gitignore
└── LICENSE
```

---

## Quick Reference

```bash
# Deploy (pull latest + restart stack)
./scripts/deploy.sh

# Backup n8n workflows + database
./scripts/backup.sh

# Health check (manual run)
./scripts/monitor.sh

# Install safe-reboot system (systemd units + scripts)
sudo ./scripts/install.sh

# Safe reboot (drains executions, backs up, then reboots)
sudo safe-reboot

# Check health timer
systemctl status agent-platform-health.timer
```

---

## Services (docker-compose.yml)

| Service    | Container        | Port (localhost) | Purpose                    |
|------------|------------------|------------------|----------------------------|
| PostgreSQL | hvac-postgres    | 5432             | Database                   |
| n8n        | n8n              | 5678             | Workflow automation        |
| Nginx      | web-server       | 80               | Reverse proxy + static     |
| ngrok      | ngrok            | 4040             | Secure tunnel to internet  |

All services bind to `127.0.0.1` except SSH. Public access is via ngrok tunnel only.

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

## Origin

Extracted from [ai-agent-platform](https://github.com/dshorter/ai-agent-platform) to separate server ops from application code.
