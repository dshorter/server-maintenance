# 🏰 AI Agent Platform - Security Architecture

**Last Updated:** 2025-01-13  
**Status:** Production-Ready  
**Security Model:** Zero Trust, Localhost-Only with Encrypted Tunnels

-----

## 🔐 Visual Architecture

```
                    INTERNET
                       │
                       │
            ╔══════════▼══════════╗
            ║   FIREWALL (ufw)    ║
            ║   Only Port 22 Open ║
            ╚══════════╤══════════╝
                       │
           ┌───────────┴───────────┐
           │                       │
           │                       │
    ┌──────▼──────┐         ┌─────▼─────┐
    │ SSH Tunnel  │         │   ngrok   │
    │             │         │  Tunnel   │
    │ (You Only)  │         │ (Public)  │
    └──────┬──────┘         └─────┬─────┘
           │                      │
           └──────────┬───────────┘
                      │
            ╔═════════▼═════════╗
            ║  Inside VPS       ║
            ║  127.0.0.1 ONLY   ║
            ╚═════════╤═════════╝
                      │
         ┌────────────┼────────────┐
         │            │            │
    ┌────▼────┐  ┌───▼────┐  ┌───▼────┐
    │  nginx  │  │  n8n   │  │ ngrok  │
    │  :8080  │  │ :5678  │  │ :4040  │
    └────┬────┘  └───┬────┘  └───┬────┘
         │           │            │
    ┌────▼────┐ ┌───▼─────┐ ┌───▼──────┐
    │ Landing │ │Workflow │ │ Tunnel   │
    │  Pages  │ │ Builder │ │ Monitor  │
    └─────────┘ └─────────┘ └──────────┘
```

-----

## 🔐 Access Control Matrix

|Component       |Port |Binding  |Access             |Purpose      |
|----------------|-----|---------|-------------------|-------------|
|**SSH**         |22   |0.0.0.0  |Your key only      |Admin access |
|**nginx**       |8080 |127.0.0.1|localhost only     |Web server   |
|**n8n**         |5678 |127.0.0.1|localhost only     |Workflows    |
|**ngrok**       |4040 |127.0.0.1|localhost only     |Dashboard    |
|**ngrok tunnel**|HTTPS|via ngrok|Public (controlled)|Landing pages|

-----

## 🛡️ Security Boundaries

```
╔═══════════════════════════════════════════════════╗
║  PUBLIC INTERNET                                  ║
║  ❌ Cannot access ports directly                  ║
║  ✅ Can access: https://agents-platform.ngrok.io  ║
╚═══════════════════════════════════════════════════╝
                       ▲
                       │ Encrypted HTTPS
                       │
╔═══════════════════════════════════════════════════╗
║  FIREWALL LAYER (ufw)                             ║
║  ✅ Port 22: SSH (key auth only)                  ║
║  ❌ Port 8080: BLOCKED                            ║
║  ❌ Port 5678: BLOCKED                            ║
╚═══════════════════════════════════════════════════╝
                       ▲
                       │ SSH or ngrok tunnel
                       │
╔═══════════════════════════════════════════════════╗
║  INSIDE VPS (localhost)                           ║
║  ✅ Full access to all services                   ║
║  ✅ nginx (:8080) ──→ Static pages                ║
║  ✅ n8n (:5678) ──→ Workflow engine               ║
║  ✅ ngrok (:4040) ──→ Tunnel dashboard            ║
╚═══════════════════════════════════════════════════╝
```

-----

## 🎯 Traffic Flow Examples

### Public User Visiting Landing Page

```
User Browser
    │
    │ HTTPS
    ▼
agents-platform.ngrok.io
    │
    │ Encrypted Tunnel
    ▼
ngrok container (localhost)
    │
    │ HTTP
    ▼
nginx (:8080)
    │
    │ Serves file
    ▼
/public/index.html
```

### You Building Workflows

```
Your Laptop
    │
    │ SSH (key auth)
    ▼
agent-vps
    │
    │ localhost access
    ▼
n8n (:5678)
    │
    │ Build workflows
    ▼
Save to /root/n8n-data
```

### Twilio Webhook

```
Twilio SMS Gateway
    │
    │ HTTPS POST
    ▼
agents-platform.ngrok.io/webhook/twilio
    │
    │ Tunnel
    ▼
nginx (:8080)
    │
    │ Proxy pass
    ▼
n8n (:5678)
    │
    │ Execute workflow
    ▼
Process SMS
```

-----

## ✅ Security Validation Checklist

### Verify Firewall Status

```bash
sudo ufw status
# Should show: Only port 22 ALLOW
```

### Verify Port Bindings

```bash
netstat -tlnp | grep LISTEN
# Should show:
# 127.0.0.1:8080  (nginx - localhost only)
# 127.0.0.1:5678  (n8n - localhost only)
# 127.0.0.1:4040  (ngrok - localhost only)
# 0.0.0.0:22      (SSH - only public port)
```

### Test External Access (Should Fail)

```bash
# From your local machine:
curl http://YOUR_VPS_IP:8080
# Expected: Connection refused ✅

curl http://YOUR_VPS_IP:5678
# Expected: Connection refused ✅
```

### Test Tunnel Access (Should Work)

```bash
curl https://agents-platform.ngrok.io
# Expected: Returns landing page HTML ✅
```

-----

## 🔒 Security Principles Applied

1. **Principle of Least Privilege**: Only SSH port exposed to internet
1. **Defense in Depth**: Multiple security layers (firewall, localhost binding, tunnel)
1. **Zero Trust**: No direct access to services, everything via controlled channels
1. **Encrypted Transport**: All public traffic via HTTPS tunnel
1. **Auditability**: All access logged and traceable

-----

## 🚨 Attack Surface Analysis

### What Attackers CAN’T Do

- ❌ Port scan your VPS (only SSH visible)
- ❌ Direct access to nginx, n8n, or services
- ❌ Exploit unpatched web services (not exposed)
- ❌ DDoS your VPS directly (ngrok handles it)
- ❌ Brute force services (localhost only)

### What Attackers COULD Try

- ⚠️ Brute force SSH (mitigated: key auth only, no passwords)
- ⚠️ DDoS ngrok tunnel (mitigated: ngrok rate limiting)
- ⚠️ Exploit n8n via tunnel (mitigated: keep n8n updated)

### Mitigation Strategy

- ✅ SSH key authentication (no passwords)
- ✅ Regular security updates
- ✅ Monitoring and alerting
- ✅ Ability to instantly revoke public access (stop ngrok)

-----

## 🔧 Emergency Response Procedures

### Revoke All Public Access

```bash
ssh agent-vps
docker stop ngrok
# Public access immediately stopped
```

### Check for Suspicious Activity

```bash
# Check nginx logs
docker logs web-server | tail -50

# Check n8n logs  
docker logs n8n | tail -50

# Check failed SSH attempts
sudo journalctl -u ssh | grep -i failed
```

### Full Lockdown Mode

```bash
# Stop all services except SSH
docker compose down
# Only SSH access remains
```

-----

## 📊 Resource Usage

```
Service         RAM      CPU      Exposure
nginx           ~15MB    <1%      Via tunnel only
n8n             ~200MB   <5%      Via tunnel only
ngrok           ~10MB    <1%      Via tunnel only
─────────────────────────────────────────────
Total           ~225MB   <10%     Single SSH port
Available       1775MB   >90%     
```

-----

## 🎯 Key Takeaways

1. **Only two access methods exist:**
- SSH tunnel (admin access, you only)
- ngrok tunnel (public access, controlled)
1. **Zero ports exposed except SSH:**
- All services bound to 127.0.0.1
- Firewall blocks everything except port 22
1. **Encrypted end-to-end:**
- SSH uses key authentication
- ngrok uses HTTPS
- No plain HTTP exposed to internet
1. **Can revoke access instantly:**
- `docker stop ngrok` removes public access
- VPS remains secure via SSH
1. **Attack surface is minimal:**
- Only SSH and ngrok tunnel endpoints
- Both encrypted and controlled

-----

**🏰 Fortress Status: LOCKED DOWN ✅**

*This architecture provides production-grade security for a $5/month VPS, suitable for handling sensitive customer data and business operations.*