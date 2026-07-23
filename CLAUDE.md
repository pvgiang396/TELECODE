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

- Linux/macOS: `curl -fsSL https://gitlab.com/pvgiang396/telecode/-/raw/main/scripts/install.sh | bash` → `scripts/install.sh` clone/pull về `~/telecode` (hoặc `$TELECODE_DIR`) rồi `exec bash setup.sh`.
- Windows: `scripts/install.ps1` (code-server không hỗ trợ Windows native) — tự cài WSL2/Ubuntu nếu chưa có rồi gọi lại `install.sh` bên trong WSL, không viết lại logic setup riêng cho Windows.
- `setup.sh` (root project) là script idempotent chính: cài code-server + cloudflared, patch trang login code-server thêm icon hiện/ẩn mật khẩu (xem dưới), tạo password, chạy code-server nền (mở đúng `$CODE_SERVER_WORKSPACE`, mặc định `~/Code` — KHÔNG mở cả `$HOME`, tránh lộ toàn bộ home directory qua Mini App), mở tunnel cho code-server, hỏi Telegram Bot Token, ghi `config.yaml`, cài Python deps (venv), chạy `bot.py` nền. Trạng thái tiến trình lưu PID ở `.run/` (gitignored) — chạy lại an toàn, không tạo tiến trình trùng lặp. Đổi mật khẩu code-server (bước 2) tự ép restart code-server (bước 3) — code-server chỉ đọc `config.yaml` lúc khởi động, không restart thì tiến trình cũ vẫn giữ mật khẩu cũ trong bộ nhớ dù file đã ghi giá trị mới.
- **Wizard cài đặt qua web** (thay hỏi terminal): `wizard.py` (stdlib `http.server`, không thêm dependency) serve `assets/wizard.html` (1 file tĩnh, inline CSS/JS, không framework — pattern giống `yan2ai/public/setup.html`) tại `127.0.0.1:8899`. `setup.sh` detect GUI (`$DISPLAY`/`$WAYLAND_DISPLAY`, macOS luôn true, hoặc WSL qua `grep microsoft /proc/version`) — có GUI thì mở `wizard.py` (foreground, chờ user submit), ghi câu trả lời vào `$RUN_DIR/wizard-answers.json`, rồi tự thoát; `setup.sh` đọc file đó, re-exec chính nó ở nền với `TELECODE_APPLYING=1` (biến này khiến `ask_value`/`ask_choice` đọc từ JSON qua hàm `answers_get()` thay vì hỏi qua `/dev/tty`, dùng chung 100% logic 9 bước cũ không cần viết lại), rồi `exit 0` ngay — trả quyền điều khiển terminal lại cho user, KHÔNG tự đóng cửa sổ terminal (không portable/an toàn để làm ngầm). Không có GUI (server/VPS headless) → giữ nguyên luồng hỏi qua terminal cũ, không đổi gì.
- `setup.sh` tự tạo shortcut Desktop mở `http://localhost:8443` (`~/Desktop/code-server.desktop` trên Linux, `~/Desktop/*.command` trên macOS — dùng icon bundle `assets/icon.png`) — dùng VS Code như app desktop ngay trên máy chạy code-server, không cần qua tunnel/Telegram. Mở bằng Chrome/Edge/Chromium ở chế độ `--app=` (hàm `resolve_app_mode_browser_bin()`, dò `google-chrome`/`chromium`/`microsoft-edge`) — ẩn thanh địa chỉ, giống app thật; không tìm thấy trình duyệt nào trong nhóm đó thì fallback `xdg-open`/`open` (tab thường). `install.ps1` (Windows) tạo `.lnk` thật (không phải `.url` — cần cho icon + flag `--app=`) trỏ `msedge.exe --app=http://localhost:8443`, icon đọc qua UNC `\\wsl$\Ubuntu\home\<user>\telecode\assets\icon.ico` (convert từ `icon.png` bằng ImageMagick `convert`, xem `assets/icon.ico`).
- **Không dùng iframe/mini_app.html trong luồng mặc định** — `bot.py` mở nút "Open VS Code" thẳng vào `VSCODE_PUBLIC_URL` (top-level navigation). Lý do: code-server đặt cookie `SameSite=Lax`; nếu load trong iframe khác domain (kiến trúc ban đầu: `mini_app.html` qua tunnel riêng nhúng code-server qua tunnel khác), nhiều WebView di động (đặc biệt iOS WKWebView của Telegram) coi cookie này là bên thứ 3 và chặn lưu — server xác thực đúng mật khẩu nhưng cookie không lưu được, đăng nhập luôn quay lại y hệt màn login. `mini_app.html` vẫn còn trong repo (không xoá) nhưng không được `setup.sh` sinh/dùng nữa — chỉ giữ tham khảo nếu sau này cần domain con cùng root domain (first-party thật) mới an toàn dùng lại iframe.
- Menu "giữ nguyên/cài lại" (`ask_choice` trong `setup.sh`) là radio 2 dòng chọn bằng phím ↑/↓ + Enter (mặc định "Giữ nguyên"), fallback về nhập số 1/2 nếu không có `/dev/tty` thật. **Quan trọng**: hàm được gọi qua `$(ask_choice ...)` để lấy kết quả — mọi echo/tput hiển thị menu bên trong hàm phải ghi thẳng `/dev/tty`, KHÔNG được ghi ra stdout thường (nếu không sẽ bị command substitution chụp mất, người dùng thấy màn hình trắng treo im chờ phím mà không có gì hiển thị — đã từng là bug thật).
- Trang login code-server (`{root}/src/browser/pages/login.html` + `login.css`, tìm qua `find_code_server_root()` trong `setup.sh`) không có API tuỳ biến chính thức — `patch_code_server_login()` vá thẳng file HTML/CSS đóng gói sẵn để thêm icon hiện/ẩn mật khẩu + chặn F12/chuột phải. HTML idempotent qua 2 marker riêng biệt (kiểm tra độc lập, không gate chung 1 marker): `telecode-eye-toggle` (icon con mắt) và `telecode-anti-inspect` (script chặn F12/contextmenu chèn trước `</body>`); CSS idempotent qua `telecode-eye-toggle-css-v2` — do input bọc thêm `<div class="password-wrap">` khiến selector CSS gốc dùng child combinator (`.field > .password`) không còn khớp, phải đổi sang descendant combinator (`.field .password`), và fix này cần áp dụng lại được kể cả trên máy đã patch HTML từ bản cũ hơn. **Chặn F12/chuột phải CHỈ áp dụng cho `login.html`, không đụng `workbench.html`** — F12 là phím tắt thật "Go to Definition" trong VS Code, chặn toàn trang sẽ phá tính năng đó khi đang code; đây cũng chỉ là ngăn cản hình thức (JS không chặn được DevTools trình duyệt thật), tham khảo cách làm/comment gốc trong `yan2ai/public/chat.html`. `login.js` đọc lại 2 file này ở mỗi request (không cache) nên patch có hiệu lực ngay, không cần restart — nhưng bị mất mỗi khi code-server cài lại/nâng cấp, nên `setup.sh` gọi lại hàm này mỗi lần chạy.
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
