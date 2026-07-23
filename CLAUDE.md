# 🤖 Project Guide for Claude AI

Hướng dẫn toàn diện giúp Claude (hoặc bất kỳ AI nào) hiểu cấu trúc project và có thể phát triển tiếp.

## 📌 Mục Đích Project

Project này là một Telegram Mini App cho phép người dùng:
1. Mở VS Code từ điện thoại qua Telegram
2. Điều khiển VS Code Server trên máy tính từ xa
3. Sử dụng Claude for VS Code Extension để coding từ xa
4. Giao việc cho AI mà không cần mở terminal trên điện thoại

## 🏗️ Kiến Trúc Hệ Thống

```
┌─────────────────────────────────────────────────────────────┐
│                      Telegram Client                        │
│                   (User's Smartphone)                       │
└────────────────────────┬────────────────────────────────────┘
                         │ (HTTPS)
                         ↓
┌─────────────────────────────────────────────────────────────┐
│                 Telegram Mini App                           │
│                 (mini_app.html)                             │
│         ● WebApp UI ● Iframe loader ● Status               │
└────────────────────────┬────────────────────────────────────┘
                         │ (HTTPS)
                         ↓
┌─────────────────────────────────────────────────────────────┐
│              Internet Tunnel Layer                          │
│         ● Cloudflare Tunnel (Recommended)                  │
│         ● Ngrok (Alternative)                              │
└────────────────────────┬────────────────────────────────────┘
                         │ (Local network)
                         ↓
┌─────────────────────────────────────────────────────────────┐
│              VS Code Server (code-server)                   │
│         ● Runs on localhost:8443                           │
│         ● Serves VS Code in browser                        │
└────────────────────────┬────────────────────────────────────┘
                         │ (VS Code API)
                         ↓
┌─────────────────────────────────────────────────────────────┐
│          Claude for VS Code Extension                       │
│    ● Processes user requests                               │
│    ● Generates code suggestions                            │
│    ● Integrates with VS Code editor                        │
└─────────────────────────────────────────────────────────────┘
```

## 📦 Cài đặt

Repo public tại `gitlab.com/pvgiang396/telecode` (SSH cho push, HTTPS cho clone/curl công khai — chỉ chủ tài khoản mới push được).

- 1 lệnh: `curl -fsSL https://gitlab.com/pvgiang396/telecode/-/raw/master/scripts/install.sh | bash` → `scripts/install.sh` clone/pull về `~/telecode` (hoặc `$TELECODE_DIR`) rồi `exec bash setup.sh`.
- `setup.sh` (root project) là script idempotent chính: cài code-server + cloudflared, tạo password, chạy code-server nền, mở 2 tunnel (code-server + mini_app.html qua `python3 -m http.server`), tự sửa `VSCODE_PUBLIC_URL` trong `mini_app.html`, hỏi Telegram Bot Token, ghi `config.yaml`, cài Python deps (venv), chạy `bot.py` nền. Trạng thái tiến trình lưu PID ở `.run/` (gitignored) — chạy lại an toàn, không tạo tiến trình trùng lặp.
- Khi chạy qua `curl | bash`, mọi prompt trong `setup.sh`/`scripts/install.sh` phải đọc từ `/dev/tty` (không dùng `read` mặc định) vì stdin đã bị nội dung script từ `curl` chiếm — xem comment trong `setup.sh`.

## 📂 Cấu Trúc File Chi Tiết

### Core Files

**`bot.py`** - Main Telegram Bot
```python
Responsibilities:
  ✓ Initialize Telegram bot with token
  ✓ Handle /start command
  ✓ Create inline keyboard with Web App button
  ✓ Manage polling for messages
  ✓ Load config from config.yaml

Key Functions:
  • start(update, context) - Gửi button "Open VS Code"
  • main() - Initialize và chạy bot
  
Dependencies:
  - python-telegram-bot==20.0
  - PyYAML
  - python-dotenv
```

**`mini_app.html`** - Web Interface
```html
Structure:
  ├── <head>
  │   ├── Telegram Web App SDK
  │   ├── Responsive meta tags
  │   └── Styling (dark theme for VS Code)
  │
  └── <body>
      ├── Header (status, connection info)
      ├── Iframe (for embedding VS Code)
      └── JavaScript
          ├── Load Telegram WebApp
          ├── Inject VS Code URL dynamically
          ├── Handle iframe lifecycle
          └── Display connection status

CORS Handling:
  - Cloudflare Tunnel handles CORS automatically
  - Telegram Mini App has its own sandbox

Configuration:
  - VSCODE_URL: Loaded from window data or hardcoded
  - Fallback: Try localhost first, then production URL
```

**`requirements.txt`** - Python Dependencies
```
Core:
  python-telegram-bot==20.0   # Telegram Bot API wrapper
  PyYAML                        # Config file parsing
  python-dotenv                 # Environment variables

Optional (for production):
  gunicorn                      # WSGI server
  aiohttp                       # Async HTTP client
```

**`config.example.yaml`** - Configuration Template
```yaml
Purpose: Centralized config file
Fields:
  TELEGRAM_BOT_TOKEN: str       # From @BotFather
  VSCODE_PORT: int              # code-server port (default: 8443)
  VSCODE_PUBLIC_URL: str        # Cloudflare Tunnel URL
  VSCODE_PASSWORD: str          # code-server password
  BOT_POLLING_INTERVAL: int     # Seconds between polls
  MINI_APP_URL: str             # Where mini_app.html is hosted
```

**`.env.example`** - Environment Variables
```
TELEGRAM_BOT_TOKEN=your_token_here
VSCODE_TUNNEL_URL=https://your-tunnel.trycloudflare.com
```

## 🔄 Data Flow

### 1. Bot Initialization
```
app = Application.builder()
  .token(TELEGRAM_BOT_TOKEN)
  .build()
  
↓ (Register handlers)

app.add_handler(CommandHandler("start", start))

↓ (Start polling)

app.run_polling()
```

### 2. User Sends /start

```
User (Telegram)
  ↓
/start command
  ↓
bot.py: start() function
  ↓
Create inline keyboard:
  [Button: "🔧 Open VS Code"]
     ↓ (WebAppInfo)
     └→ mini_app.html
  ↓
Send message with button
  ↓
User's phone displays button
```

### 3. User Clicks Button

```
Telegram Client
  ↓
Open WebAppInfo URL (mini_app.html)
  ↓
Telegram Mini App Container
  ├─ Sandboxed environment
  ├─ Limited by Telegram security
  └─ Can access Telegram.WebApp API
  ↓
mini_app.html loads
  ├─ Initialize Telegram.WebApp
  ├─ Set iframe src to VSCODE_PUBLIC_URL
  └─ Display connection status
  ↓
Iframe loads VS Code Server
  ├─ HTTPS connection via tunnel
  ├─ Authenticate with password
  └─ Render full VS Code interface
  ↓
User sees VS Code in iframe on phone
  ↓
Can use Claude for VS Code extension
```

## 🔌 Component Responsibilities

### Telegram Bot (bot.py)
- **Input**: /start command from users
- **Output**: Inline keyboard with Web App button
- **State**: Stateless (polling-based)
- **Config**: Reads from config.yaml

### Mini App (mini_app.html)
- **Input**: Loaded in Telegram Mini App container
- **Output**: Iframe displaying VS Code
- **Responsibilities**:
  - Initialize Telegram WebApp
  - Manage iframe lifecycle
  - Display status indicators
  - Handle connection errors
- **Limitations**:
  - Runs in sandbox
  - No file system access
  - Limited to what iframe allows

### VS Code Server (code-server)
- **Input**: HTTP/HTTPS requests from mini_app.html
- **Output**: Web-based VS Code interface
- **Runs**: On localhost:8443 (configurable)
- **Features**:
  - Full VS Code features in browser
  - Extension support
  - File editing
  - Terminal access
  - Debugging

### Internet Tunnel (Cloudflare)
- **Purpose**: Expose localhost to internet securely
- **Input**: Local VS Code Server on localhost:8443
- **Output**: Public HTTPS URL (https://xxx.trycloudflare.com)
- **Benefits**:
  - No port forwarding needed
  - HTTPS by default
  - DDoS protection
  - Zero-knowledge architecture

### Claude for VS Code
- **Input**: User prompts in VS Code
- **Output**: Code suggestions, completions, refactoring
- **Integration**: Works through VS Code extension protocol
- **Accessed via**: VS Code UI in mini_app.html

## 🚀 Deployment Scenarios

### Scenario 1: Local Development
```
Developer's PC:
  ├─ bot.py runs (local polling)
  ├─ code-server runs on :8443
  └─ ngrok/cloudflare exposes it

Developer's Phone:
  └─ Connects to Telegram bot
     └─ Opens VS Code via Mini App
```

### Scenario 2: Docker Production
```
Docker Host:
  ├─ Bot container (running bot.py)
  ├─ code-server container
  ├─ Cloudflare tunnel container
  └─ Network: bridge mode (containers communicate)

User's Phone:
  └─ Connects to bot
     └─ Opens VS Code hosted on Docker
```

### Scenario 3: Multiple Users
```
Shared Server:
  ├─ Single bot instance
  ├─ Single code-server instance (shared workspace)
  └─ Multiple users connect simultaneously
  
Note: Each user sees same project directory
```

## 🔐 Security Architecture

### Authentication Layers

1. **Telegram Authentication**
   - User must be Telegram user
   - Bot token validates requests
   - Only registered users can access

2. **Code-Server Authentication**
   - Password protection
   - HTTPS only
   - No public access (unless deliberately configured)

3. **Tunnel Authentication**
   - Cloudflare Tunnel uses zero-trust
   - IP-based access control possible
   - Automatic HTTPS

4. **Mini App Sandbox**
   - Telegram isolates Mini App
   - Cannot access phone file system
   - Cannot bypass Telegram authentication

### Data Protection
```
User Input → Telegram Encryption → Tunnel Encryption → 
code-server (local) → VS Code (local) → File System
```

## 📊 State Management

### Stateless Bot
The bot doesn't store user state. Each /start request:
- Creates new button
- Loads latest config
- Generates fresh UI

### Stateless Mini App
HTML file is loaded fresh each time. State kept in:
- Iframe (VS Code server session)
- Browser localStorage (if needed)

### Stateful Code-Server
Maintains:
- Open files
- Editor position
- Extensions state
- Workspace configuration

## 🛠️ Extension Points for Development

### Easy Modifications

1. **Change UI Theme**
   ```html
   <!-- Edit mini_app.html -->
   <style>
     /* Modify colors, fonts, layout */
   </style>
   ```

2. **Add Custom Buttons**
   ```python
   # Edit bot.py - add_handler() section
   keyboard = [[
       InlineKeyboardButton("🔧 VS Code", ...),
       InlineKeyboardButton("📁 File Manager", ...),
   ]]
   ```

3. **Add New Commands**
   ```python
   async def help_command(update, context):
       # New handler
   
   app.add_handler(CommandHandler("help", help_command))
   ```

4. **Change Configuration**
   ```yaml
   # Edit config.yaml
   # Restart bot.py
   ```

### Advanced Modifications

1. **Database Integration**
   - Store user preferences
   - Track usage logs
   - Persist settings

2. **Multiple Workspaces**
   - Allow users to switch projects
   - Different VS Code instances
   - Per-user configuration

3. **Analytics**
   - Track connections
   - Monitor usage patterns
   - Performance metrics

4. **Webhook Mode (vs Polling)**
   - Replace polling with webhooks
   - More efficient for high traffic
   - Requires public server

## 🐛 Debugging Guide

### For Claude AI Tasks

When debugging, check these in order:

**1. Configuration**
```bash
# Check config is loaded correctly
python -c "import yaml; print(yaml.safe_load(open('config.yaml')))"
```

**2. Bot Token**
```bash
# Validate token format (should be numbers:letters)
python -c "from bot import TELEGRAM_BOT_TOKEN; print(len(TELEGRAM_BOT_TOKEN))"
```

**3. Bot Connectivity**
```bash
# Test Telegram API access
curl -s https://api.telegram.org/bot<TOKEN>/getMe | jq
```

**4. VS Code Server**
```bash
# Check if code-server is running
curl -v http://localhost:8443

# Check port
netstat -an | grep 8443
```

**5. Tunnel**
```bash
# Verify tunnel is active
curl -v https://your-tunnel-name.trycloudflare.com

# Check tunnel logs
cloudflared tunnel --logfile=tunnel.log
```

**6. Bot Logs**
```bash
# Run with debug output
python bot.py --debug

# Or enable logging in code:
import logging
logging.basicConfig(level=logging.DEBUG)
```

### Common Issues & Solutions

| Issue | Cause | Solution |
|-------|-------|----------|
| Bot no response | Token invalid | Check config.yaml |
| Mini App frame blank | URL wrong | Verify VSCODE_PUBLIC_URL |
| Code-server 404 | Not running | Start code-server |
| CORS error | Tunnel config | Check Cloudflare settings |
| Password wrong | Mismatch | Verify in code-server config |
| Slow connection | Tunnel distance | Use nearest Cloudflare server |

## 📝 Common Tasks

### Task: Add a New Command
```python
# In bot.py, add this function:
async def project_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text("Which project?")

# Register it:
app.add_handler(CommandHandler("project", project_command))
```

### Task: Change Mini App URL
```yaml
# config.yaml
MINI_APP_URL: https://your-server.com/mini_app.html
```

### Task: Add More Buttons
```python
keyboard = [[
    InlineKeyboardButton("🔧 VS Code", web_app=WebAppInfo(url="...")),
    InlineKeyboardButton("📁 Files", callback_data="files"),
    InlineKeyboardButton("⚙️ Settings", callback_data="settings"),
]]
```

### Task: Customize Appearance
Edit `mini_app.html` - modify CSS and HTML structure.

## 📚 Code Location Reference

When working with the code:

- **Bot logic** → `bot.py`
- **Web UI** → `mini_app.html`
- **Configuration** → `config.yaml`
- **Dependencies** → `requirements.txt`
- **Docker setup** → `docker-compose.yml`, `Dockerfile`
- **Setup** → `setup.sh`

## 🎯 Next Steps for Development

1. **Basic**: Get project running locally
2. **Intermediate**: Customize UI and commands
3. **Advanced**: Add database, multiple workspaces
4. **Production**: Deploy with Docker, setup monitoring

## 💡 Important Notes for AI Work

### When Claude Reads This File
- Understand the full architecture before modifying
- Check data flow before changing component behavior
- Consider security implications of changes
- Test locally before deploying
- Update this CLAUDE.md when architecture changes

### When Asked to Debug
1. Always check configuration first
2. Test components in isolation
3. Verify connectivity at each layer
4. Check logs for error messages
5. Provide reproduction steps

### When Asked to Add Features
1. Document the new feature in this file
2. Update code comments
3. Test end-to-end flow
4. Consider security implications
5. Update README.md if user-facing

---

**This guide helps AI assistants understand the project deeply and make informed decisions.**
