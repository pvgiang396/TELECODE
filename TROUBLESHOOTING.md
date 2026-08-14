# 🔧 Troubleshooting Guide

Chi tiết cách debug các vấn đề thường gặp.

## 🧪 Diagnostic Checklist

### 1. Bot Connectivity
```bash
# Test Telegram API
curl -s https://api.telegram.org/bot<YOUR_TOKEN>/getMe | jq

# Should return:
# {
#   "ok": true,
#   "result": {
#     "id": 123456,
#     "is_bot": true,
#     "first_name": "Your Bot Name"
#   }
# }
```

### 2. Config Loading
```bash
python3 << EOF
import yaml
with open('config.yaml', 'r') as f:
    config = yaml.safe_load(f)
    for key, value in config.items():
        if 'TOKEN' in key or 'PASSWORD' in key:
            print(f"{key}: {'*' * 10}")
        else:
            print(f"{key}: {value}")
EOF
```

### 3. VS Code Server
```bash
# Check if running
netstat -an | grep 8443
# or
lsof -i :8443

# Test connection
curl -v http://localhost:8443
# or
curl -v https://localhost:8443 --insecure
```

### 4. Tunnel Status
```bash
# If using cloudflared
ps aux | grep cloudflared

# Test tunnel URL
curl -v https://your-tunnel-name.trycloudflare.com
```

### 5. Network Connectivity
```bash
# Check internet
ping google.com

# DNS resolution
nslookup api.telegram.org

# Telegram API latency
ping api.telegram.org
```

---

## ❌ Common Issues & Solutions

### Issue: `unexpected status 401 Unauthorized ... /v1/responses` khi chạy Codex

**Symptoms:**
- Codex reconnect 5/5 rồi báo `API key required for remote API access`
- URL lỗi trỏ về endpoint 9Router (`.../v1/responses`)

**Root causes thường gặp:**
- `OPENAI_API_KEY` điền nhầm token Codex dạng `AQ...` (không phải API key router/OpenAI)
- Cấu hình provider custom thiếu `env_key = "OPENAI_API_KEY"` hoặc code-server chưa nạp env mới

**Fix nhanh:**
```bash
# 1) Chạy lại setup để nhập đúng key (sk-...)
bash setup.sh

# 2) Kiểm tra file codex config có env_key
grep -n 'env_key = "OPENAI_API_KEY"' ~/.codex/config.toml

# 3) Kiểm tra code-server env đã có OPENAI_API_KEY (setup mới sẽ tự ghi file này)
grep -n '^OPENAI_API_KEY=' .run/code-server.env

# 4) Restart code-server để nạp env mới
systemctl --user restart code-server 2>/dev/null || true
```

Nếu vẫn lỗi, mở wizard setup và nhập lại `OPENAI_API_KEY` đúng loại key.

### Issue: "Bot no response to /start"

**Symptoms:**
- Send /start, bot doesn't respond
- No errors in bot.py output

**Causes & Solutions:**

```bash
# 1. Check token format (should be: numbers:alphanumeric)
grep TELEGRAM_BOT_TOKEN config.yaml

# 2. Check token is valid
curl -s https://api.telegram.org/bot<TOKEN>/getMe

# 3. Is bot actually running?
ps aux | grep "python bot.py"

# 4. Check for errors
python bot.py  # Run directly to see errors

# 5. Firewall/VPN issues
# If using VPN, try disabling it
# If behind corporate firewall, may need to contact admin
```

**Expected Output:**
```
✅ Bot configured:
   Bot Token: 123456:AB...
   VS Code URL: https://tunnel.trycloudflare.com
   Mini App URL: https://your-domain.com/mini_app.html
✅ Bot started successfully!
📨 Waiting for messages...
```

---

### Issue: "Mini App frame is blank"

**Symptoms:**
- Button opens Mini App
- But iframe shows nothing
- No error messages

**Causes & Solutions:**

```bash
# 1. Check mini_app.html loads
curl http://localhost:8000/mini_app.html | head -20

# 2. Check VS Code URL in mini_app.html
grep "VSCODE_PUBLIC_URL" mini_app.html

# 3. Check VS Code Server is accessible
curl https://your-tunnel.trycloudflare.com

# 4. Enable debug mode in mini_app.html
# Open browser DevTools (F12)
# Check console for errors

# 5. Test iframe directly in browser
# Visit: https://your-tunnel.trycloudflare.com in desktop browser
```

**Debug Mode (mini_app.html):**
```javascript
// Add to mini_app.html script
CONFIG.DEBUG_MODE = true;  // Shows debug panel at bottom
```

---

### Issue: "Connection timeout - VS Code Server offline"

**Symptoms:**
- Mini App loads
- Error: "Connection timeout"
- "VS Code server may be offline"

**Causes & Solutions:**

```bash
# 1. Is code-server running?
ps aux | grep code-server
# If not, start it:
code-server

# 2. Is it on correct port?
netstat -an | grep 8443

# 3. Is tunnel still active?
ps aux | grep cloudflared
# Should see tunnel running with URL

# 4. Test tunnel URL
curl -v https://your-tunnel.trycloudflare.com
# Should get HTTP 200, not Connection refused

# 5. Check firewall
sudo ufw status
# Make sure port 8443 is not blocked

# 6. Is code-server password protected?
cat ~/.config/code-server/config.yaml | grep password
```

---

### Issue: "CORS error in browser console"

**Symptoms:**
- Browser console shows CORS errors
- Mini App loads but can't connect to VS Code

**Causes & Solutions:**

```bash
# If using Cloudflare Tunnel:
# CORS should be automatic, but verify:

# Check tunnel is actually routing to code-server
curl -H "Origin: https://telegram.org" \
     -H "Access-Control-Request-Method: GET" \
     https://your-tunnel.trycloudflare.com -v

# You should see:
# Access-Control-Allow-Origin: *
# Access-Control-Allow-Methods: *

# If not using Cloudflare, need CORS headers in VS Code
# Or use different approach (webhooks instead of direct access)
```

---

### Issue: "Docker containers won't start"

**Symptoms:**
- `docker-compose up -d` fails
- Containers exit immediately

**Solutions:**

```bash
# 1. Check logs
docker-compose logs -f

# 2. Check services individually
docker-compose logs bot
docker-compose logs code-server
docker-compose logs tunnel

# 3. Verify .env exists
ls -la .env

# 4. Check .env syntax
cat .env | grep -v "^#" | grep -v "^$"

# 5. Rebuild containers
docker-compose down
docker-compose build --no-cache
docker-compose up -d

# 6. Check if ports are free
netstat -an | grep 8443
netstat -an | grep 8080
```

---

### Issue: "Too many retries - Max retry attempts reached"

**Symptoms:**
- Mini App keeps showing "Retrying..."
- Error after 3 attempts

**Solutions:**

```bash
# 1. Check all components running
ps aux | grep code-server
ps aux | grep cloudflared
ps aux | grep "python bot.py"

# 2. Test each component
# Test code-server directly
curl http://localhost:8443

# Test tunnel
curl https://your-tunnel-name.trycloudflare.com

# Test bot
curl -s https://api.telegram.org/bot<TOKEN>/getMe

# 3. Check connectivity
ping google.com
ping api.telegram.org

# 4. Increase retry attempts
# Edit mini_app.html:
CONFIG.RETRY_ATTEMPTS = 5  // Was 3
CONFIG.CONNECTION_TIMEOUT = 15000  // Was 10000
```

---

## 🔍 Debugging with Logs

### Enable Full Debugging

```bash
# Python logging
python3 << EOF
import logging
logging.basicConfig(level=logging.DEBUG)
# Then run bot
EOF

# Or in bot.py, add:
# logging.basicConfig(level=logging.DEBUG)
```

### Check Different Logs

```bash
# Bot logs
tail -f bot.log

# Docker logs
docker-compose logs -f bot
docker-compose logs -f code-server
docker-compose logs -f tunnel

# System logs
journalctl -u code-server -f

# Browser console
# Open in browser: F12 → Console tab
```

### Mini App Debug Panel

**Enable in mini_app.html:**
```html
<script>
CONFIG.DEBUG_MODE = true;  // Shows debug info at bottom
</script>
```

**Or via JavaScript console:**
```javascript
document.getElementById('debug').classList.add('visible');
```

---

## 🌐 Network Diagnostics

### Check Internet Connection

```bash
# Telegram API
curl -s https://api.telegram.org/bot123/getMe
curl -I https://api.telegram.org/bot123/getMe

# Your tunnel
curl -I https://your-tunnel.trycloudflare.com

# DNS
nslookup api.telegram.org
nslookup trycloudflare.com

# Latency
ping api.telegram.org
```

### Firewall Issues

```bash
# Check if port is accessible from outside
# From another device on different network:
curl https://your-tunnel.trycloudflare.com

# Check local firewall
sudo ufw status
sudo ufw allow 8443/tcp

# On macOS
sudo lsof -i :8443

# On Windows
netstat -ano | findstr :8443
```

---

## 🔐 Security Debugging

### Check Authentication

```bash
# Is code-server password set?
grep "^password:" ~/.config/code-server/config.yaml

# Is tunnel authenticated?
cloudflared tunnel --url http://localhost:8443 --loglevel debug

# Bot token format (should not show in logs)
# NEVER echo TELEGRAM_BOT_TOKEN in production
```

---

## 📊 Performance Issues

### Slow Connection

```bash
# Measure latency
ping -c 5 api.telegram.org
ping -c 5 your-tunnel.trycloudflare.com

# Check bandwidth
# Use network tools: speedtest-cli

# Reduce connection timeout
# In mini_app.html:
CONFIG.CONNECTION_TIMEOUT = 5000  // Shorter timeout
```

### High CPU/Memory

```bash
# Monitor processes
watch -n 1 'ps aux | grep -E "(code-server|bot.py|cloudflared)"'

# Check resource usage
docker stats  # If using Docker

# Optimize code-server
# Disable unnecessary extensions
# Reduce file watcher limits
```

---

## 🆘 Get Help

### Provide Information

When asking for help, provide:

1. **Error message** (full, not truncated)
2. **Diagnostic output:**
   ```bash
   # Bot token (first 10 chars only)
   echo ${TELEGRAM_BOT_TOKEN:0:10}...
   
   # Config summary
   cat config.yaml | grep -v "PASSWORD" | grep -v "TOKEN"
   
   # System info
   uname -a
   python3 --version
   
   # Active processes
   ps aux | grep -E "(bot|code|cloudflare)" | grep -v grep
   ```
3. **Steps to reproduce**
4. **What you've already tried**

### Resources

- [Telegram Bot API Docs](https://core.telegram.org/bots/api)
- [Code-Server Documentation](https://coder.com/docs/code-server)
- [Cloudflare Tunnel Docs](https://developers.cloudflare.com/cloudflare-one/)
- [Python-Telegram-Bot Docs](https://python-telegram-bot.readthedocs.io/)

---

## 🎯 Still Stuck?

1. Check CLAUDE.md for AI debugging help
2. Review architecture in CLAUDE.md
3. Test components in isolation
4. Check logs in multiple places
5. Try simplest setup first (localhost only)
6. Then add complexity (tunnel, Docker, etc)

---

**Remember: Most issues are configuration or connectivity related, not code bugs.**
