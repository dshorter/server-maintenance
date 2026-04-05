# 🚀 Landing Page Deployment - Complete Setup Guide

**Created:** 2025-01-13  
**Time Required:** 25 minutes  
**Difficulty:** Intermediate  
**Result:** Live landing pages with "Ascension by Repo is a Lie"

---

## 📋 Prerequisites

- ✅ VPS running with n8n + ngrok
- ✅ SSH access configured
- ✅ ngrok domain: `agents-platform.ngrok.io`
- ✅ Basic command line comfort

---

## 🔧 Step 1: Create nginx Config (NEW!)

**Time:** 3 minutes

```bash
ssh agent-vps
cd /opt/ai-agent-platform

# Create nginx config folder
mkdir -p nginx

# Create nginx.conf
cat > nginx/nginx.conf << 'EOF'
events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    server {
        listen 80;
        server_name _;

        # Static pages served from /public
        location / {
            root /usr/share/nginx/html;
            try_files $uri $uri/ /index.html;
        }

        # API endpoint for timestamp
        location /api/timestamp {
            add_header Content-Type application/json;
            return 200 '{"timestamp":"'$date_gmt'","server":"nginx"}';
        }

        # n8n UI at /n8n
        location /n8n/ {
            proxy_pass http://n8n:5678/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
        }

        # Webhooks still work at root (for Twilio)
        location /webhook/ {
            proxy_pass http://n8n:5678/webhook/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
}
EOF

echo "✅ nginx config created!"
```

**What this does:**
- Routes `/` to your landing pages
- Routes `/n8n/` to n8n UI
- Routes `/webhook/` to n8n webhooks (Twilio still works!)
- All on one domain!

---

## 📄 Step 2: Create Landing Pages

**Time:** 5 minutes

```bash
# Still on VPS, still in /opt/ai-agent-platform
mkdir -p public

# Create landing page
cat > public/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Intelligence Moat</title>
    <script>
        window.addEventListener('DOMContentLoaded', function() {
            document.getElementById('timestamp').textContent = 
                'Built: ' + new Date().toISOString();
        });
    </script>
    <style>
        body {
            margin: 0;
            padding: 0;
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #1e3c72 0%, #2a5298 100%);
            color: white;
            height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .timestamp {
            position: fixed;
            top: 20px;
            right: 20px;
            color: #FFD700;
            font-size: 0.8rem;
            opacity: 0.8;
        }
        .slide {
            text-align: center;
            width: 90%;
            max-width: 1200px;
        }
        h1 {
            font-size: 4rem;
            margin: 0;
            margin-bottom: 40px;
            line-height: 1.2;
        }
        .tagline {
            font-size: 1.2rem;
            color: #FFD700;
            text-transform: uppercase;
            letter-spacing: 3px;
            margin-bottom: 20px;
            font-weight: 600;
        }
        .cta {
            margin-top: 60px;
        }
        .button {
            display: inline-block;
            padding: 15px 40px;
            background: #FFD700;
            color: #1e3c72;
            text-decoration: none;
            font-weight: bold;
            border-radius: 8px;
            margin: 0 10px;
            transition: transform 0.2s;
            font-size: 1.1rem;
        }
        .button:hover {
            transform: translateY(-2px);
            box-shadow: 0 4px 12px rgba(255, 215, 0, 0.4);
        }
    </style>
</head>
<body>
    <div class="timestamp" id="timestamp">Loading...</div>
    
    <div class="slide">
        <div class="tagline">Ascension by Repo is a Lie</div>
        <h1>Everyone Has AI.<br>Not Everyone Has INTELLIGENCE.</h1>
        
        <div class="cta">
            <a href="/demo.html" class="button">See The Proof 🎯</a>
        </div>
    </div>
</body>
</html>
EOF

# Create demo page
cat > public/demo.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Monday Morning Advantage - PROOF</title>
    <script>
        window.addEventListener('DOMContentLoaded', function() {
            document.getElementById('timestamp').textContent = 
                'Built: ' + new Date().toISOString();
        });
    </script>
    <style>
        body {
            margin: 0;
            padding: 0;
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #0f2027 0%, #203a43 50%, #2c5364 100%);
            color: white;
            min-height: 100vh;
            padding: 40px 20px;
        }
        .timestamp {
            position: fixed;
            top: 20px;
            right: 20px;
            color: #FFD700;
            font-size: 0.8rem;
            opacity: 0.8;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
        }
        h1 {
            font-size: 3rem;
            text-align: center;
            margin-bottom: 10px;
        }
        .case-study {
            color: #4ade80;
            text-align: center;
            text-transform: uppercase;
            letter-spacing: 2px;
            margin-bottom: 30px;
        }
        .results {
            display: flex;
            justify-content: space-around;
            margin: 60px 0;
            text-align: center;
            flex-wrap: wrap;
        }
        .result-box {
            flex: 1;
            margin: 15px;
            min-width: 200px;
        }
        .result-number {
            font-size: 3rem;
            font-weight: 700;
            color: #4ade80;
        }
        .result-label {
            color: rgba(255, 255, 255, 0.8);
            text-transform: uppercase;
            letter-spacing: 1px;
            margin-top: 10px;
        }
        .insight {
            background: rgba(255, 255, 255, 0.1);
            padding: 30px;
            border-radius: 10px;
            text-align: center;
            margin-top: 40px;
        }
        .insight-text {
            font-size: 1.4rem;
            color: #FFD700;
            font-weight: 600;
            margin-bottom: 15px;
        }
        .back-button {
            display: inline-block;
            margin-top: 40px;
            padding: 12px 30px;
            background: rgba(255, 255, 255, 0.1);
            color: white;
            text-decoration: none;
            border-radius: 8px;
            border: 1px solid rgba(255, 255, 255, 0.3);
            transition: all 0.2s;
        }
        .back-button:hover {
            background: rgba(255, 255, 255, 0.2);
        }
    </style>
</head>
<body>
    <div class="timestamp" id="timestamp">Loading...</div>
    
    <div class="container">
        <div class="case-study">Real Proof of Concept</div>
        <h1>The Monday Morning Advantage</h1>
        <p style="text-align: center; color: #FFD700; font-size: 1.2rem;">Java Junction vs. Starbucks</p>
        
        <div class="results">
            <div class="result-box">
                <div class="result-number">$2,100</div>
                <div class="result-label">Weekly Advantage</div>
            </div>
            <div class="result-box">
                <div class="result-number">847</div>
                <div class="result-label">Unique Data Points</div>
            </div>
            <div class="result-box">
                <div class="result-number">3 hrs</div>
                <div class="result-label">Beats 3 Weeks</div>
            </div>
        </div>
        
        <div class="insight">
            <div class="insight-text">Every Week This Intelligence Compounds</div>
            <p style="margin-top: 15px;">
                Year 1: $109,200 in revenue Starbucks literally CANNOT capture<br>
                <strong>Because they don't have Bob's phone number. And never will.</strong>
            </p>
        </div>
        
        <div style="text-align: center;">
            <a href="/" class="back-button">← Back to Home</a>
        </div>
    </div>
</body>
</html>
EOF

echo "✅ Landing pages created!"
ls -lh public/
```

**What you now have:**
- `public/index.html` - Landing page with timestamp
- `public/demo.html` - Demo proof with numbers

---

## 🐳 Step 3: Update docker-compose.yml

**Time:** 3 minutes

```bash
# Still on VPS
cd /opt/ai-agent-platform
nano docker-compose.yml
```

**Replace entire file with this:**

```yaml
version: '3.8'

services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      - N8N_HOST=localhost
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - WEBHOOK_URL=https://agents-platform.ngrok.io/webhook/
      - GENERIC_TIMEZONE=America/New_York
      - N8N_METRICS=true
      - N8N_LOG_LEVEL=info
      - N8N_LOG_OUTPUT=console
      - EXECUTIONS_PROCESS=main
      - N8N_PERSONALIZATION_ENABLED=false
      - N8N_VERSION_NOTIFICATIONS_ENABLED=true
      - N8N_DIAGNOSTICS_ENABLED=false
    volumes:
      - /root/n8n-data:/home/node/.n8n
      - /root/n8n-data/transactions:/data/transactions
      - /root/n8n-data/backups:/data/backups
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  web:
    image: nginx:alpine
    container_name: web-server
    restart: unless-stopped
    volumes:
      - ./public:/usr/share/nginx/html:ro
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
    ports:
      - "127.0.0.1:8080:80"
    depends_on:
      - n8n

  ngrok:
    image: ngrok/ngrok:alpine
    container_name: ngrok
    restart: unless-stopped
    command: 
      - "http"
      - "web:80"
      - "--domain=agents-platform.ngrok.io"
      - "--log-level=info"
    environment:
      - NGROK_AUTHTOKEN=${NGROK_AUTHTOKEN}
    ports:
      - "127.0.0.1:4040:4040"
    depends_on:
      - web
```

**Save:** Ctrl+O, Enter, Ctrl+X

**KEY CHANGES:**
- ✅ Added `web` service (nginx)
- ✅ Changed ngrok to point to `web:80` (not `n8n:5678`)
- ✅ Updated WEBHOOK_URL to include `/webhook/` path

---

## 🚀 Step 4: Deploy!

**Time:** 3 minutes

```bash
# Still on VPS
cd /opt/ai-agent-platform

# Stop everything
docker compose down

# Start with new config
docker compose up -d

# Wait for services to start
sleep 5

# Check status
docker compose ps
```

**You should see:**
```
NAME          STATUS
n8n           running (healthy)
web-server    running
ngrok         running
```

✅ All three services running!

---

## ✅ Step 5: Test Everything

**Time:** 5 minutes

### Test 1: Landing Page
```bash
# From VPS
curl https://agents-platform.ngrok.io/

# Should return HTML with "Ascension by Repo is a Lie"
```

### Test 2: Demo Page
```bash
curl https://agents-platform.ngrok.io/demo.html

# Should return HTML with "$2,100"
```

### Test 3: n8n UI
```bash
curl https://agents-platform.ngrok.io/n8n/

# Should return n8n login page
```

### Test 4: Webhooks
```bash
# Your Twilio webhooks should still work at:
# https://agents-platform.ngrok.io/webhook/twilio
```

---

## 🎉 Step 6: Verify Live!

**Time:** 2 minutes

### From Your Browser:

1. **Landing Page:** `https://agents-platform.ngrok.io/`
   - Should see: "Everyone Has AI. Not Everyone Has INTELLIGENCE."
   - Timestamp should show in top-right corner

2. **Demo Page:** `https://agents-platform.ngrok.io/demo.html`
   - Should see: "$2,100 Weekly Advantage"
   - Timestamp in top-right
   - "Back to Home" button works

3. **n8n UI:** `https://agents-platform.ngrok.io/n8n/`
   - Should see: n8n login screen
   - Your workflows still accessible

---

## 📊 Resource Check

```bash
# Check resources
docker stats --no-stream

# Should show:
# n8n:        ~200MB RAM
# web-server: ~15MB RAM
# ngrok:      ~10MB RAM
# TOTAL:      ~225MB (out of 2GB)
```

**You're using less than 15% of your VPS!** ✅

---

## 🔧 Troubleshooting

### If landing page doesn't load:
```bash
# Check nginx logs
docker logs web-server

# Check if files exist
ls -la /opt/ai-agent-platform/public/

# Restart nginx
docker restart web-server
```

### If n8n UI doesn't work:
```bash
# Check n8n logs
docker logs n8n

# Verify URL path includes /n8n/
# Wrong: https://agents-platform.ngrok.io
# Right: https://agents-platform.ngrok.io/n8n/
```

### If webhooks break:
```bash
# Check nginx config
cat /opt/ai-agent-platform/nginx/nginx.conf

# Should have /webhook/ location block
# Restart everything
docker compose restart
```

---

## 🎯 Quick Reference URLs

| What | URL |
|------|-----|
| **Landing Page** | `https://agents-platform.ngrok.io/` |
| **Demo Page** | `https://agents-platform.ngrok.io/demo.html` |
| **n8n UI** | `https://agents-platform.ngrok.io/n8n/` |
| **Webhooks** | `https://agents-platform.ngrok.io/webhook/*` |
| **ngrok Dashboard** | `http://localhost:4040` (via SSH) |

---

## 📝 Commit to Git

```bash
# On VPS
cd /opt/ai-agent-platform

git add nginx/ public/ docker-compose.yml
git commit -m "Add landing pages with nginx - Ascension by Repo is a Lie"
git push origin main
```

---

## 🚀 Next Steps

1. **Screenshot your live pages** ✅
2. **Post on LinkedIn** - "Just shipped..."
3. **Send to one potential customer**
4. **Update DNS** (optional - get custom domain)
5. **Add analytics** (optional - track visitors)

---

## 🎉 Success Criteria

- ✅ Landing page live with timestamp
- ✅ Demo page accessible
- ✅ n8n UI still works at `/n8n/`
- ✅ Webhooks still functional
- ✅ All containers running healthy
- ✅ Using <15% of VPS resources
- ✅ Security model intact (localhost only)

---

**🔥 YOU DID IT! Your landing pages are LIVE!**

**Total time:** ~25 minutes  
**Monthly cost:** $0 additional (using existing VPS)  
**Impact:** Professional presence for demos and customers

*Now go share that URL with the world! 🚀*