# 📂 Project Structure

Chi tiết cấu trúc và mục đích của từng file/folder.

## File Organization

```
telecode/
│
├── 📄 Documentation Files
│   ├── README.md                 # Main documentation (read this first!)
│   ├── QUICK_START.md           # Fast setup guide (5 minutes)
│   ├── CLAUDE.md                # Guide for AI assistants ⭐
│   ├── TROUBLESHOOTING.md       # Debug guide & solutions
│   ├── PROJECT_STRUCTURE.md     # This file
│   └── LICENSE                   # MIT License
│
├── ⚙️ Setup Application
│   ├── wizard.py                 # Local web server (stdlib) serving the setup UI
│   ├── requirements.txt          # Python dependencies
│   ├── config.example.yaml      # Configuration template
│   ├── .env.example             # Environment variables template
│   └── .gitignore               # Git ignore rules
│
├── 🌐 Web Interface
│   └── assets/wizard.html       # Setup wizard UI ⭐ (inline CSS/JS)
│
├── 🖥️ Native Apps (Tauri)
│   ├── src-tauri/               # Desktop (tray + code-server window) + Android app
│   └── setup.sh                 # Automated setup script (installs code-server, Tailscale, etc.)
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

### ⚙️ Core Application

**wizard.py**
- Local HTTP server (stdlib only) serving the setup UI
- Reads/writes `config.yaml`
- Reports status (`scripts/lib_status.py`) to `assets/wizard.html`
- When run inside the Tauri app (`TELECODE_MANAGED=1`), also triggers `setup.sh` in the background

**requirements.txt** (15 lines)
- PyYAML - Config parsing
- python-dotenv - Environment variables

**config.example.yaml** (20 lines)
- VSCODE_PUBLIC_URL - Your tunnel URL
- VSCODE_PORT - Default: 8443
- VSCODE_PASSWORD, VSCODE_AUTH_REQUIRED, VSCODE_ALLOW_INSECURE
- OPENAI_API_KEY, GITHUB_COPILOT_PAT - AI CLI configuration
- LOG_LEVEL, ENABLE_DEBUG_MODE, ALLOW_MULTIPLE_CONNECTIONS

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

**assets/wizard.html** ⭐
- Setup UI served by `wizard.py`
- Radio/input form for initial configuration
- Status polling + iframe to code-server once running

### 🖥️ Native Apps

**src-tauri/**
- Desktop app (Linux/Windows): tray icon, spawns `wizard.py`/code-server as sidecars, opens a native window pointing at the local wizard/VS Code UI
- Android app: native app embedding code-server via an iframe pointing at a Tailscale Funnel URL entered manually by the user
- See `CLAUDE.md` for the full build/runtime architecture

**setup.sh** (idempotent)
- Automated setup script
- Installs code-server + Tailscale
- Patches code-server login page (eye-toggle, dark theme, F12/right-click block)
- Creates password, runs code-server in background
- Creates Desktop shortcut
- Opens Tailscale Funnel
- Generates `config.yaml` from `config.example.yaml`
- Installs Python dependencies (dedicated venv)

### ⚙️ Configuration Files

**config.yaml** (created after setup)
```yaml
VSCODE_PUBLIC_URL: "..."       # Tunnel URL
VSCODE_PORT: 8443
OPENAI_API_KEY: "..."
GITHUB_COPILOT_PAT: "..."
# ... other settings
```

**.env** (created after setup)
```
VSCODE_PUBLIC_URL=...
# ... environment variables
```

## Data Flow

### Setup Phase
```
1. User runs the install script or clones the repo
2. Runs setup.sh
   ├─ Creates venv/
   ├─ Installs dependencies
   ├─ Copies config template
   └─ Ready to configure
3. User edits config.yaml (or fills in the wizard UI)
4. User starts services
```

### Runtime Phase
```
1. User starts code-server
2. User starts the tunnel (Tailscale Funnel)
3. User opens the native Telecode app (desktop or Android)
4. App loads the code-server URL (local for desktop, pasted Funnel URL for Android)
```

## File Dependencies

```
assets/wizard.html
    ↓ (loads from)
wizard.py (HTTP server)
    ↓ (reads/writes)
config.yaml

src-tauri/ (desktop)
    ↓ (spawns as sidecar)
wizard.py, code-server

src-tauri/ (Android)
    ↓ (iframe to)
Tailscale Funnel URL (entered by user)
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
- ❌ config.yaml (contains password/API keys)
- ❌ .env (contains secrets)
- ❌ ~/.config/code-server/config.yaml (has password)

### Safe to Commit
- ✅ config.example.yaml (template only)
- ✅ .env.example (template only)
- ✅ wizard.py (no secrets)
- ✅ assets/wizard.html (no secrets)
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
   ├─ Clone repo / run install script
   ├─ bash setup.sh
   ├─ Edit config.yaml
   └─ Edit .env

2. Local Development
   ├─ code-server (terminal 1)
   ├─ tailscale funnel (terminal 2)
   └─ Test via the native Telecode app

3. Native App Build
   ├─ npm run build (Tauri desktop, cross-platform)
   ├─ npx tauri android build (Android APK)
   └─ Distribute/install

4. Maintenance
   ├─ Check logs: journalctl -u code-server -f
   ├─ Update code
   └─ Monitor status
```

## File Size Reference

```
wizard.py             ~7 KB
README.md            ~12 KB
CLAUDE.md            ~25 KB
TROUBLESHOOTING.md   ~15 KB
config.example.yaml  ~2 KB
requirements.txt     ~1 KB
```

## Extension Points

Files you can customize:

1. **assets/wizard.html**
   - Change colors/theme
   - Add buttons
   - Modify layout

2. **wizard.py**
   - Add new status checks
   - Change setup flow
   - Integrate with other APIs

3. **config.yaml**
   - Change URLs
   - Modify ports
   - Update credentials

4. **src-tauri/**
   - Customize tray menu
   - Change window behavior
   - Modify Android app UI

## Next Steps

1. **Understand the code**
   - Read CLAUDE.md (for AI help)
   - Understand wizard.py logic
   - Review src-tauri/ structure

2. **Setup locally**
   - Follow QUICK_START.md
   - Get code-server running
   - Test end-to-end

3. **Customize**
   - Modify config
   - Update UI
   - Add features

4. **Deploy**
   - Build native apps (Tauri)
   - Setup Tailscale Funnel
   - Enable security

---

**Questions?** Check TROUBLESHOOTING.md or CLAUDE.md!
