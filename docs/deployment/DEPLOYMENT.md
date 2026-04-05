# Safe Reboot System - Local to VPS Deployment
**Your Workflow:** Local → GitHub → Auto-deploy to VPS → Run installer  
**Date:** 2025-10-14

---

## 📁 Step 1: Create Local Directory Structure

On your **local machine** in your `ai-agent-platform` repo:

```
ai-agent-platform/
└── docs/
    └── safe-reboot/
        ├── install.sh                                          # NEW - Installer script
        ├── usr_local_sbin_safe-reboot.sh                      # IMPROVED VERSION
        ├── usr_local_sbin_agent-platform-health.sh            # IMPROVED VERSION
        ├── etc_systemd_system_ai-agent-platform.service       # KEEP EXISTING
        ├── etc_systemd_system_agent-platform-health.service   # KEEP EXISTING
        ├── etc_systemd_system_agent-platform-health.timer     # KEEP EXISTING
        ├── INSTALL_COMMANDS.txt                               # KEEP EXISTING (for reference)
        ├── INSTALLATION.md                                     # NEW - Full install guide
        └── CHANGES.md                                          # NEW - Change log
```

---

## 🔧 Step 2: Download Improved Artifacts

### 2.1 Save Artifacts Locally

From the Claude chat, copy each artifact content to your local files:

**PowerShell (Windows):**
```powershell
# Navigate to your repo
cd C:\Users\YOUR_USERNAME\projects\ai-agent-platform\docs\safe-reboot

# Open files in your editor
code usr_local_sbin_safe-reboot.sh
code usr_local_sbin_agent-platform-health.sh
code install.sh
code INSTALLATION.md
code CHANGES.md

# Paste the improved content from artifacts into each file
# Save all files
```

**Bash (Mac/Linux):**
```bash
# Navigate to your repo
cd ~/projects/ai-agent-platform/docs/safe-reboot

# Open files in your editor
code usr_local_sbin_safe-reboot.sh
code usr_local_sbin_agent-platform-health.sh
code install.sh
code INSTALLATION.md
code CHANGES.md

# Paste the improved content from artifacts into each file
# Save all files
```

### 2.2 Artifact → File Mapping

| Artifact Name | Save As |
|---------------|---------|
| `install.sh - Improved Installation Script` | `install.sh` |
| `safe-reboot.sh - Improved Version` | `usr_local_sbin_safe-reboot.sh` |
| `agent-platform-health.sh - Improved Version` | `usr_local_sbin_agent-platform-health.sh` |
| `INSTALLATION.md - Complete Installation Guide` | `INSTALLATION.md` |
| `CHANGES.md - What's Fixed in Phase 1` | `CHANGES.md` |

**Keep existing files:**
- `etc_systemd_system_ai-agent-platform.service` ← Don't change
- `etc_systemd_system_agent-platform-health.service` ← Don't change
- `etc_systemd_system_agent-platform-health.timer` ← Don't change

---

## 📤 Step 3: Commit and Push to GitHub

**PowerShell (Windows):**
```powershell
cd C:\Users\YOUR_USERNAME\projects\ai-agent-platform

# Check what changed
git status
git diff docs/safe-reboot/

# Add all changes
git add docs/safe-reboot/

# Commit with descriptive message
git commit -m "Phase 1: Add improved safe-reboot system with health monitoring

- Add automated install.sh script
- Improve safe-reboot.sh with backup validation and execution waiting
- Improve agent-platform-health.sh with real health checks and auto-recovery
- Add comprehensive INSTALLATION.md guide
- Add CHANGES.md documenting Phase 1 improvements
- All scripts validated against VPS environment"

# Push to GitHub (triggers auto-deploy!)
git push origin main
```

**Bash (Mac/Linux):**
```bash
cd ~/projects/ai-agent-platform

# Check what changed
git status
git diff docs/safe-reboot/

# Add all changes
git add docs/safe-reboot/

# Commit with descriptive message
git commit -m "Phase 1: Add improved safe-reboot system with health monitoring

- Add automated install.sh script
- Improve safe-reboot.sh with backup validation and execution waiting
- Improve agent-platform-health.sh with real health checks and auto-recovery
- Add comprehensive INSTALLATION.md guide
- Add CHANGES.md documenting Phase 1 improvements
- All scripts validated against VPS environment"

# Push to GitHub (triggers auto-deploy!)
git push origin main
```

---

## 🤖 Step 4: GitHub Actions Auto-Deploy

Your GitHub Actions workflow will automatically:

1. ✅ Detect push to `main` branch
2. ✅ SSH into your VPS
3. ✅ Navigate to `/opt/ai-agent-platform`
4. ✅ Pull latest changes from GitHub
5. ✅ Files now on VPS at: `/opt/ai-agent-platform/docs/safe-reboot/`

**Wait for GitHub Actions to complete** (usually 30-60 seconds)

You can watch it here:
- Go to: `https://github.com/YOUR_USERNAME/ai-agent-platform/actions`
- Watch the workflow run
- Wait for green checkmark ✅

---

## 🖥️ Step 5: SSH to VPS and Install

Once GitHub Actions completes:

```bash
# SSH to your VPS
ssh agent-vps

# Navigate to the deployed files
cd /opt/ai-agent-platform/docs/safe-reboot

# Verify files are there
ls -la

# Expected output:
# -rw-r--r-- install.sh
# -rw-r--r-- usr_local_sbin_safe-reboot.sh
# -rw-r--r-- usr_local_sbin_agent-platform-health.sh
# -rw-r--r-- etc_systemd_system_*.service
# etc...

# Make install.sh executable
chmod +x install.sh

# Run the installer as root
sudo ./install.sh
```

---

## ✅ Step 6: Verify Installation

After `install.sh` completes:

### 6.1 Check Installation Summary

The installer will show you a summary like:

```
════════════════════════════════════════════════════════
  Installation Complete!
════════════════════════════════════════════════════════

Scripts installed:
  • /usr/local/sbin/safe-reboot
  • /usr/local/sbin/agent-platform-health

Systemd services:
  • ai-agent-platform.service (enabled)
  • agent-platform-health.service (enabled)
  • agent-platform-health.timer (enabled and running)
```

### 6.2 Manual Verification

```bash
# Check scripts exist and are executable
ls -l /usr/local/sbin/safe-reboot
ls -l /usr/local/sbin/agent-platform-health

# Check systemd services
systemctl is-enabled ai-agent-platform.service
systemctl is-enabled agent-platform-health.service
systemctl is-enabled agent-platform-health.timer

# Check timer is running
systemctl is-active agent-platform-health.timer
systemctl status agent-platform-health.timer

# Run a test health check
sudo agent-platform-health
```

### 6.3 Check Logs

```bash
# View health check logs
tail -f /var/log/agent-platform-health.log

# View systemd logs
journalctl -u agent-platform-health.service -n 20

# Check timer schedule
systemctl list-timers | grep agent-platform
```

---

## 🎯 Step 7: Test the System

### 7.1 Test Health Check

```bash
# Manual health check
sudo agent-platform-health

# Expected output:
# [2025-10-14 14:30:00] Starting health checks...
# [2025-10-14 14:30:01] ✓ n8n is healthy
# [2025-10-14 14:30:02] ✓ n8n API is responding
# [2025-10-14 14:30:03] ✓ ngrok is running - Tunnel: https://xxx.ngrok.io
# [2025-10-14 14:30:04] ✓ Disk space OK: 45% used
# [2025-10-14 14:30:05] ✓ All health checks passed
```

### 7.2 Test Safe Reboot (Optional - Only if Ready!)

⚠️ **WARNING:** This will actually reboot your VPS!

```bash
# Only run this if you're ready to reboot
sudo safe-reboot

# This will:
# 1. Check prerequisites
# 2. Wait for n8n executions to finish
# 3. Run backup
# 4. Stop containers
# 5. Reboot system

# After reboot, SSH back in and verify:
ssh agent-vps
systemctl status ai-agent-platform.service
docker ps
```

---

## 🔄 Future Updates Workflow

When you make changes later:

```bash
# 1. Edit files locally
code ~/projects/ai-agent-platform/docs/safe-reboot/

# 2. Commit and push
git add docs/safe-reboot/
git commit -m "Update safe-reboot: [describe changes]"
git push origin main

# 3. Wait for GitHub Actions
# (Watch at github.com/YOUR_USERNAME/ai-agent-platform/actions)

# 4. SSH and re-run installer
ssh agent-vps
cd /opt/ai-agent-platform/docs/safe-reboot
sudo ./install.sh

# The installer automatically backs up existing files
# and installs the new versions
```

---

## 🐛 Troubleshooting

### Problem: GitHub Actions Deploy Failed

```bash
# Check GitHub Actions logs
# Go to: github.com/YOUR_USERNAME/ai-agent-platform/actions
# Click on failed workflow
# Check error message

# Common issues:
# - SSH key permissions
# - VPS unreachable
# - Git pull failed
```

### Problem: Files Not on VPS After Deploy

```bash
# Verify GitHub Actions completed
# Then check manually on VPS:
ssh agent-vps
cd /opt/ai-agent-platform
git status
git log -1

# If out of sync, manually pull:
git pull origin main
```

### Problem: install.sh Permission Denied

```bash
# Make it executable
chmod +x /opt/ai-agent-platform/docs/safe-reboot/install.sh

# Or run directly with bash
sudo bash /opt/ai-agent-platform/docs/safe-reboot/install.sh
```

### Problem: Installation Fails with Missing Files

```bash
# Check all required files exist
cd /opt/ai-agent-platform/docs/safe-reboot
ls -la

# Required files:
# - install.sh
# - usr_local_sbin_safe-reboot.sh
# - usr_local_sbin_agent-platform-health.sh
# - etc_systemd_system_ai-agent-platform.service
# - etc_systemd_system_agent-platform-health.service
# - etc_systemd_system_agent-platform-health.timer

# If missing, check git status and pull again
```

---

## 📊 Complete Workflow Diagram

```
┌─────────────────┐
│  Local Machine  │
│                 │
│  Edit files in  │
│  docs/safe-     │
│  reboot/        │
└────────┬────────┘
         │
         │ git push origin main
         ▼
┌─────────────────┐
│     GitHub      │
│   Repository    │
│                 │
│  Branch: main   │
└────────┬────────┘
         │
         │ Triggers GitHub Actions
         ▼
┌─────────────────┐
│ GitHub Actions  │
│   Workflow      │
│                 │
│  1. SSH to VPS  │
│  2. cd /opt/... │
│  3. git pull    │
└────────┬────────┘
         │
         │ Auto-deploy
         ▼
┌─────────────────┐
│   Hetzner VPS   │
│                 │
│  Files updated  │
│  at /opt/ai-    │
│  agent-platform │
└────────┬────────┘
         │
         │ SSH + run install.sh
         ▼
┌─────────────────┐
│   Installation  │
│   Complete!     │
│                 │
│  Scripts →      │
│  /usr/local/sbin│
│  Units →        │
│  /etc/systemd/  │
└─────────────────┘
```

---

## ✅ Success Checklist

After deployment, you should have:

- [ ] Files on VPS at `/opt/ai-agent-platform/docs/safe-reboot/`
- [ ] Scripts installed at `/usr/local/sbin/`
- [ ] Systemd units at `/etc/systemd/system/`
- [ ] Services enabled: `systemctl is-enabled ai-agent-platform.service`
- [ ] Timer running: `systemctl is-active agent-platform-health.timer`
- [ ] Health check works: `sudo agent-platform-health`
- [ ] Logs being written: `tail /var/log/agent-platform-health.log`
- [ ] Backups running: `ls /root/n8n-data/backups/`

---

## 🎉 You're Done!

Your workflow is:

1. **Edit locally** (in your IDE)
2. **Commit to GitHub** (version control)
3. **Auto-deploy to VPS** (GitHub Actions)
4. **Run installer** (one command)
5. **System protected** (safe reboot + health monitoring)

**This is a professional deployment pipeline!** 🚀

---

**Next time you need to update:**
Just edit locally, commit, push, and re-run `install.sh` on VPS. Done!