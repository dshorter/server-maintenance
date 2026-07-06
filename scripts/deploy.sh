#!/bin/bash
# Deploy script — called by GitHub Actions after push to main.
#
# SCOPE (2026-07-05): this repo owns ONLY ghost + ghost-mysql. The compose
# file also defines the ai-agent-platform services as legacy — a bare
# `docker compose down` / `up -d` here would spin up duplicates and fight
# for :80/:5432/:5678 (see README "What this repo does NOT own"). The old
# version of this script did exactly that on every push. Deploy is now:
# pull the repo, ensure the ghost pair is up. Installed system files
# (/usr/local/sbin, /etc/systemd) are NOT auto-synced — apply those
# deliberately, by hand.

set -euo pipefail

cd /opt/server-maintenance || exit 1

echo "Pulling latest changes..."
git pull origin main

echo "Ensuring ghost stack is up (ghost-mysql ghost ONLY)..."
docker compose up -d ghost-mysql ghost

echo "Status:"
docker compose ps ghost-mysql ghost

echo "Deployment complete."
