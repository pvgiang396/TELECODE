# 🚀 Telegram VS Code Mini App

Điều khiển VS Code trên máy tính của bạn qua Telegram từ điện thoại. Tích hợp Claude for VS Code để giao việc coding từ xa.

## ✨ Tính năng

- 📱 Mở VS Code từ Telegram Mini App
- 🤖 Tích hợp Claude for VS Code Extension
- 🌐 Truy cập từ bất kỳ đâu qua Internet tunnel
- 🔒 Bảo mật với password & encryption
- ⚡ Trải nghiệm responsive trên mobile

## 📋 Yêu cầu

- **OS**: Linux, macOS, hoặc Windows (WSL)
- **Node.js**: v16+ (tùy chọn)
- **Python**: v3.8+
- **Docker** (tùy chọn, khuyến khích)
- **Telegram Bot Token** (tạo từ @BotFather)

## 🎯 Quick Start

### 1. Chuẩn bị

```bash
# Clone hoặc download project
cd telegram-vscode-mini-app

# Cài dependencies
pip install -r requirements.txt
```

### 2. Cấu hình

```bash
# Copy file cấu hình
cp config.example.yaml config.yaml

# Chỉnh sửa config.yaml
# - Thêm BOT_TOKEN từ @BotFather
# - Cấu hình port và password
nano config.yaml
```

### 3. Setup VS Code Server

**Option A: Code-server (Khuyến nghị)**

```bash
# Linux
sudo apt install -y code-server

# macOS
brew install code-server

# Windows
choco install code-server
```

**Option B: VS Code Server chính thức**

```bash
code --install-extension GitHub.copilot
```

### 4. Tạo Internet Tunnel

**Cloudflare Tunnel (Miễn phí & An toàn)**

```bash
# Cài cloudflared
# Linux:
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.tgz
tar -xzf cloudflared-linux-amd64.tgz

# macOS:
brew install cloudflare/cloudflare/cloudflared

# Chạy tunnel
./cloudflared tunnel --url http://localhost:8443

# Ghi nhớ URL: https://your-tunnel.trycloudflare.com
```

Cập nhật URL này vào `config.yaml` trong field `VSCODE_PUBLIC_URL`

### 5. Chạy Bot

```bash
python bot.py
```

Bạn sẽ thấy:
```
✅ Bot started successfully!
🔗 VS Code URL: https://your-tunnel.trycloudflare.com
📱 Send /start to your bot on Telegram
```

### 6. Trên Telegram

- Mở bot (search username bot của bạn)
- Gửi `/start`
- Click nút "🔧 Open VS Code"
- VS Code sẽ mở trong Telegram Mini App!

## 🐳 Cách chạy với Docker (Dễ hơn)

```bash
docker-compose up -d

# Xem logs
docker-compose logs -f

# Stop
docker-compose down
```

## 🔐 Bảo Mật

### Bật Password cho Code-Server

```yaml
# ~/.config/code-server/config.yaml
password: your-strong-password-here
cert: false
```

### Firewall Configuration

```bash
# Chỉ allow port từ Cloudflare
sudo ufw allow 8443/tcp comment "code-server"
sudo ufw enable
```

### Recommendations

- ✅ Dùng Cloudflare Tunnel (không cần expose port)
- ✅ Bật password protection
- ✅ Thay đổi default port
- ✅ Dùng VPN nếu cần thêm layer bảo mật
- ❌ Không công khai URL trên Internet

## 📁 Cấu trúc Project

```
telegram-vscode-mini-app/
├── bot.py                 # Telegram bot chính
├── mini_app.html          # Giao diện web
├── requirements.txt       # Python dependencies
├── config.example.yaml    # File cấu hình mẫu
├── docker-compose.yml     # Docker setup
├── Dockerfile             # Container config
├── setup.sh              # Setup script
├── README.md             # File này
├── CLAUDE.md             # Hướng dẫn cho Claude AI
└── .env.example          # Biến môi trường mẫu
```

## 🛠️ Troubleshooting

### Bot không phản hồi
```bash
# Kiểm tra token
python -c "from bot import TELEGRAM_BOT_TOKEN; print('Token OK' if TELEGRAM_BOT_TOKEN else 'Missing token')"

# Kiểm tra internet
ping api.telegram.org
```

### Không thể kết nối VS Code
```bash
# Kiểm tra code-server đang chạy
curl http://localhost:8443

# Kiểm tra tunnel
./cloudflared tunnel --url http://localhost:8443
```

### Frame bị block trên Telegram
- Telegram Mini App có limitation với CORS
- Dùng Cloudflare Tunnel để bypass

## 📚 Tài liệu thêm

- [Code-Server Docs](https://coder.com/docs/code-server/latest)
- [Telegram Bot API](https://core.telegram.org/bots/api)
- [Telegram Mini Apps](https://core.telegram.org/bots/webapps)
- [Claude for VS Code](https://marketplace.visualstudio.com/items?itemName=GitHub.copilot)
- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/)

## 💡 Tips

### Tối ưu hiệu suất
- Đóng các extension không cần thiết
- Dùng VS Code Insiders cho performance tốt hơn
- Giới hạn số file watcher

### Customize giao diện
Edit `mini_app.html` để thay đổi theme, layout, hoặc thêm shortcut

### Dùng với Claude
Xem `CLAUDE.md` để hướng dẫn AI làm việc với project này

## 🤝 Support

Nếu gặp issue:
1. Kiểm tra `CLAUDE.md` cho debugging tips
2. Xem logs: `docker-compose logs -f`
3. Kiểm tra config file
4. Test từng component riêng lẻ

## 📝 License

MIT License - Dùng tự do cho mục đích cá nhân và thương mại

---

**Made with ❤️ for remote developers**
