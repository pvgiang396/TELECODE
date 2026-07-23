# 📂 Project Structure

Chi tiết cấu trúc và mục đích của từng file/folder.

## File Organization

```
telegram-vscode-mini-app/
│
├── 📄 Documentation Files
│   ├── README.md                 # Main documentation (read this first!)
│   ├── QUICK_START.md           # Fast setup guide (5 minutes)
│   ├── CLAUDE.md                # Guide for AI assistants ⭐
│   ├── TROUBLESHOOTING.md       # Debug guide & solutions
│   ├── PROJECT_STRUCTURE.md     # This file
│   └── LICENSE                   # MIT License
│
├── 🤖 Bot Application
│   ├── bot.py                   # Main Telegram bot logic
│   ├── requirements.txt          # Python dependencies
│   ├── config.example.yaml      # Configuration template
│   ├── .env.example             # Environment variables template
│   └── .gitignore               # Git ignore rules
│
├── 🌐 Web Interface
│   ├── mini_app.html            # Telegram Mini App UI ⭐
│   └── nginx.conf               # Web server config (Docker)
│
├── 🐳 Docker Setup
│   ├── docker-compose.yml       # Multi-container orchestration
│   ├── Dockerfile.bot           # Bot container config
│   └── setup.sh                 # Automated setup script
│
└── 📁 Runtime Folders (created after setup)
    ├── venv/                    # Python virtual environment
    ├── workspace/               # Project folder (shared with code-server)
    ├── config.yaml              # Your actual config (DO NOT COMMIT)
    └── .env                     # Your env vars (DO NOT COMMIT)
```

## File Details

### 📄 Documentation

| File | Purpose | Read When |
|------|---------|-----------|
| **README.md** | Complete documentation | First thing - overview of everything |
| **QUICK_START.md** | Setup in 5 minutes | Want to get running fast |
| **CLAUDE.md** | AI-specific guide ⭐ | Have Claude help with project |
| **TROUBLESHOOTING.md** | Debug & fix issues | Something isn't working |
| **PROJECT_STRUCTURE.md** | This file | Understanding file organization |

### 🤖 Core Application

**bot.py** (200 lines)
- Telegram bot entry point
- Handles /start, /help, /status commands
- Creates inline keyboard with Web App button
- Configuration loading from YAML
- Error handling and logging

**requirements.txt** (15 lines)
- python-telegram-bot==20.0 - Bot framework
- PyYAML - Config parsing
- python-dotenv - Environment variables
- aiohttp - Async HTTP client (optional)

**config.example.yaml** (20 lines)
- TELEGRAM_BOT_TOKEN - From @BotFather
- VSCODE_PUBLIC_URL - Your tunnel URL
- VSCODE_PORT - Default: 8443
- MINI_APP_URL - Where mini_app.html is hosted
- Logging and other settings

**.env.example** (6 lines)
- Alternative config method
- Used as fallback if config.yaml not found
- Environment variables format

**.gitignore** (60 lines)
- Excludes sensitive files
- Ignores virtual environments
- Ignores IDE files
- Ignores logs and temporary files

### 🌐 Web Interface

**mini_app.html** (400 lines) ⭐
- Responsive Telegram Mini App interface
- Loads VS Code Server in iframe
- Status indicators and error handling
- Retry logic for failed connections
- Telegram WebApp SDK integration
- Dark theme support
- Debug mode for troubleshooting

**nginx.conf** (25 lines)
- Web server configuration
- CORS headers setup
- Security headers
- Static file serving
- Used in Docker setup

### 🐳 Docker & Deployment

**docker-compose.yml** (80 lines)
- Multi-container orchestration
- Services:
  - Bot (telegram bot)
  - Code-server (VS Code in browser)
  - Tunnel (Cloudflare)
  - Web-server (nginx, optional)
- Volume management
- Network setup
- Environment variables

**Dockerfile.bot** (20 lines)
- Python 3.11 slim base
- Dependencies installation
- Bot application setup

**setup.sh** (90 lines)
- Automated setup script
- Creates virtual environment
- Installs dependencies
- Generates config files
- Platform detection

### ⚙️ Configuration Files

**config.yaml** (created after setup)
```yaml
TELEGRAM_BOT_TOKEN: "..."      # Your secret bot token
VSCODE_PUBLIC_URL: "..."       # Tunnel URL
MINI_APP_URL: "..."            # Where mini app is hosted
# ... other settings
```

**.env** (created after setup)
```
TELEGRAM_BOT_TOKEN=...
VSCODE_PUBLIC_URL=...
# ... environment variables
```

## Data Flow

### Setup Phase
```
1. User downloads ZIP
2. Runs setup.sh
   ├─ Creates venv/
   ├─ Installs dependencies
   ├─ Copies config template
   └─ Ready to configure
3. User edits config.yaml
4. User starts services
```

### Runtime Phase
```
1. User starts bot: python bot.py
2. User starts code-server
3. User starts tunnel: cloudflared tunnel ...
4. User opens mini_app.html on web server
5. User sends /start on Telegram
6. User clicks "Open VS Code" button
7. Mini App loads and connects to VS Code
```

## File Dependencies

```
mini_app.html
    ↓ (loads from)
config.yaml → MINI_APP_URL
    ↓ (requires)
Web server serving mini_app.html

bot.py
    ↓ (reads)
config.yaml (TELEGRAM_BOT_TOKEN, MINI_APP_URL, VSCODE_PUBLIC_URL)
    ↓ (requires)
python-telegram-bot library

docker-compose.yml
    ↓ (runs)
- bot.py (in docker container)
- code-server (official image)
- cloudflared (official image)
    ↓ (uses)
config.yaml, requirements.txt, Dockerfile.bot
```

## Configuration Hierarchy

```
1. Environment Variables (.env file)
   └─ Highest priority if file exists

2. config.yaml file
   └─ Standard YAML configuration

3. Hardcoded defaults (in Python code)
   └─ Fallback values

Note: .env > config.yaml > defaults
```

## Security Considerations

### Sensitive Files (Never Commit)
- ❌ config.yaml (contains bot token)
- ❌ .env (contains secrets)
- ❌ ~/.config/code-server/config.yaml (has password)

### Safe to Commit
- ✅ config.example.yaml (template only)
- ✅ .env.example (template only)
- ✅ bot.py (no secrets)
- ✅ mini_app.html (no secrets)
- ✅ All documentation

### .gitignore Protections
```
# Prevents accidentally committing
config.yaml
.env
venv/
workspace/
__pycache__/
*.log
```

## Typical Development Workflow

```
1. Initial Setup
   ├─ Download ZIP
   ├─ bash setup.sh
   ├─ Edit config.yaml
   └─ Edit .env

2. Local Development
   ├─ python bot.py (terminal 1)
   ├─ code-server (terminal 2)
   ├─ cloudflared tunnel (terminal 3)
   ├─ python -m http.server (terminal 4)
   └─ Test on Telegram

3. Docker Deployment
   ├─ docker-compose up -d
   ├─ Get tunnel URL
   ├─ Update config
   └─ Access via Telegram

4. Maintenance
   ├─ Check logs: docker-compose logs -f
   ├─ Update code
   ├─ docker-compose down && up
   └─ Monitor status
```

## File Size Reference

```
bot.py                ~7 KB
mini_app.html        ~15 KB
README.md            ~12 KB
CLAUDE.md            ~25 KB
TROUBLESHOOTING.md   ~15 KB
config.example.yaml  ~2 KB
requirements.txt     ~1 KB
docker-compose.yml   ~4 KB
TOTAL (uncompressed) ~85 KB
TOTAL (compressed)   ~27 KB (ZIP)
```

## Extension Points

Files you can customize:

1. **mini_app.html**
   - Change colors/theme
   - Add buttons
   - Modify layout
   - Add keyboard shortcuts

2. **bot.py**
   - Add new commands
   - Change welcome message
   - Add handlers
   - Integrate with other APIs

3. **config.yaml**
   - Change URLs
   - Modify ports
   - Update credentials

4. **docker-compose.yml**
   - Add services
   - Change image versions
   - Modify volumes
   - Update networking

## Next Steps

1. **Understand the code**
   - Read CLAUDE.md (for AI help)
   - Understand bot.py logic
   - Review mini_app.html structure

2. **Setup locally**
   - Follow QUICK_START.md
   - Get bot running
   - Test end-to-end

3. **Customize**
   - Modify config
   - Update UI
   - Add features

4. **Deploy**
   - Use Docker
   - Setup monitoring
   - Enable security

---

**Questions?** Check TROUBLESHOOTING.md or CLAUDE.md!
