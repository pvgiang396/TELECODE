# 🔧 Troubleshooting Guide

Chi tiết cách debug các vấn đề thường gặp.

## 🧪 Diagnostic Checklist

### 1. Config Loading
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

### 2. VS Code Server
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

### 3. Tunnel Status
```bash
# If using Tailscale Funnel
tailscale funnel status

# Test tunnel URL
curl -v https://your-machine.your-tailnet.ts.net
```

### 4. Network Connectivity
```bash
# Check internet
ping google.com

# DNS resolution
nslookup <your-tunnel-domain>
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

### Issue: "Connection timeout - VS Code Server offline"

**Symptoms:**
- App báo "Connection timeout"
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
tailscale funnel status
# Should see tunnel running with URL

# 4. Test tunnel URL
curl -v https://your-tunnel-url

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
- App loads but can't connect to VS Code

**Causes & Solutions:**

```bash
# Check tunnel is actually routing to code-server
curl -H "Origin: https://your-app-origin" \
     -H "Access-Control-Request-Method: GET" \
     https://your-tunnel-url -v

# You should see:
# Access-Control-Allow-Origin: *
# Access-Control-Allow-Methods: *

# If needed, add CORS headers in VS Code
# Or use a different approach (webhooks instead of direct access)
```

---

## 🔍 Debugging with Logs

### Check Different Logs

```bash
# System logs
journalctl -u code-server -f

# Browser console
# Open in browser: F12 → Console tab
```

---

## 🌐 Network Diagnostics

### Check Internet Connection

```bash
# Your tunnel
curl -I https://your-tunnel-url

# DNS
nslookup <your-tunnel-domain>

# Latency
ping <your-tunnel-domain>
```

### Firewall Issues

```bash
# Check if port is accessible from outside
# From another device on different network:
curl https://your-tunnel-url

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
tailscale funnel status
```

---

## 📊 Performance Issues

### Slow Connection

```bash
# Measure latency
ping -c 5 <your-tunnel-domain>

# Check bandwidth
# Use network tools: speedtest-cli
```

### High CPU/Memory

```bash
# Monitor processes
watch -n 1 'ps aux | grep -E "(code-server|tailscale)"'

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
   # Config summary
   cat config.yaml | grep -v "PASSWORD" | grep -v "TOKEN"
   
   # System info
   uname -a
   python3 --version
   
   # Active processes
   ps aux | grep -E "(code|tailscale)" | grep -v grep
   ```
3. **Steps to reproduce**
4. **What you've already tried**

### Resources

- [Code-Server Documentation](https://coder.com/docs/code-server)
- [Tailscale Funnel Docs](https://tailscale.com/kb/1223/funnel)

---

## 🎯 Still Stuck?

1. Check CLAUDE.md for AI debugging help
2. Review architecture in CLAUDE.md
3. Test components in isolation
4. Check logs in multiple places
5. Try simplest setup first (localhost only)
6. Then add complexity (tunnel, etc)

---

**Remember: Most issues are configuration or connectivity related, not code bugs.**
