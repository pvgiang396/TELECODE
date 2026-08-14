# ⚡ Quick Start Guide

Khởi chạy project này trong 5 phút.

## Yêu cầu tối thiểu

- Python 3.8+
- Telegram account
- Máy tính có thể truy cập internet

## 1️⃣ Clone/Download Project

```bash
cd telegram-vscode-mini-app
```

## 2️⃣ Tạo Bot Telegram

1. Mở Telegram, tìm **@BotFather**
2. Gửi `/newbot`
3. Đặt tên và username cho bot
4. Sao chép token (ví dụ: `123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11`)

## 3️⃣ Setup Project

```bash
# Tạo virtual environment
python3 -m venv venv
source venv/bin/activate  # Linux/Mac
# hoặc: venv\Scripts\activate  # Windows

# Cài dependencies
pip install -r requirements.txt

# Copy config
cp config.example.yaml config.yaml
nano config.yaml  # Chỉnh sửa với token
```

**Chỉnh sửa config.yaml:**
```yaml
TELEGRAM_BOT_TOKEN: "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"  # Token từ BotFather
OPENAI_API_KEY: ""  # Tuỳ chọn — API key 9Router/OpenAI (thường sk-..., KHÔNG dùng token AQ...), để trống nếu chưa dùng
VSCODE_PUBLIC_URL: "http://localhost:8443"  # Tạm thời (sẽ update sau)
MINI_APP_URL: "http://localhost:8000/mini_app.html"  # Development
```

> Lưu ý: cách setup thủ công từng bước ở file này (cloudflared, chạy `bot.py` tay...) đã cũ — cách khuyến nghị hiện tại là chạy thẳng `bash setup.sh` (xem README.md), script sẽ tự hỏi/cài mọi thứ kể cả bước Codex CLI này.

## 4️⃣ Cài đặt Code-Server

**Linux:**
```bash
sudo apt update
sudo apt install code-server
code-server
```

**macOS:**
```bash
brew install code-server
code-server
```

**Windows:**
```bash
choco install code-server
# Hoặc download từ: https://github.com/coder/code-server/releases
```

Code-server sẽ chạy trên `http://localhost:8443`

## 5️⃣ Tạo Tunnel

**Cloudflare Tunnel (Recommended):**

```bash
# Cài cloudflared
# Linux:
wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x cloudflared-linux-amd64
./cloudflared-linux-amd64 tunnel --url http://localhost:8443

# macOS:
brew install cloudflare/cloudflare/cloudflared
cloudflared tunnel --url http://localhost:8443

# Windows:
# Download from: https://github.com/cloudflare/cloudflared/releases
# Or: scoop install cloudflared
cloudflared tunnel --url http://localhost:8443
```

Bạn sẽ thấy:
```
https://random-name-123.trycloudflare.com
```

**Cập nhật config.yaml:**
```yaml
VSCODE_PUBLIC_URL: "https://random-name-123.trycloudflare.com"
```

## 6️⃣ Host Mini App

Mở terminal mới:

```bash
# Ở folder project
python -m http.server 8000
```

## 7️⃣ Chạy Bot

```bash
# Terminal khác
python bot.py
```

Bạn sẽ thấy:
```
✅ Bot started successfully!
🔗 VS Code URL: https://random-name-123.trycloudflare.com
📱 Send /start to your bot on Telegram
```

## 8️⃣ Test trên Telegram

1. Mở Telegram
2. Tìm bot của bạn (theo username)
3. Gửi `/start`
4. Click nút "🔧 Open VS Code"
5. 🎉 VS Code sẽ mở trong Telegram!

---

## 🐳 Cách Dễ Hơn: Docker

Nếu bạn có Docker:

```bash
# Copy .env
cp .env.example .env
nano .env  # Chỉnh sửa token

# Chạy
docker-compose up -d

# Xem logs
docker-compose logs -f

# Lấy tunnel URL
docker-compose logs tunnel | grep trycloudflare
```

---

## 🐛 Troubleshooting

### Bot không phản hồi
```bash
# Kiểm tra token
grep TELEGRAM_BOT_TOKEN config.yaml

# Bot chạy?
ps aux | grep bot.py
```

### Không thể kết nối VS Code
```bash
# Code-server chạy?
curl http://localhost:8443

# Tunnel chạy?
# (Terminal cloudflared phải còn chạy)
```

### Telegram Mini App bị block
- Đảm bảo MINI_APP_URL có thể truy cập
- Kiểm tra CORS headers
- Thử dùng Cloudflare Tunnel cho cả mini_app.html

---

## 📚 Bước Tiếp Theo

- ✅ Đọc **README.md** để tìm hiểu kỹ hơn
- ✅ Xem **CLAUDE.md** để AI có thể giúp
- ✅ Tùy chỉnh **mini_app.html** (theme, buttons, etc)
- ✅ Deploy production (Docker)

---

## 💡 Tips

- **Port conflicts**: Thay đổi port trong `config.yaml` và `mini_app.html`
- **Security**: Bật password cho code-server
- **Mobile optimization**: Mini app tự động responsive
- **Offline mode**: Tunnel giúp bạn truy cập từ bất kỳ đâu

---

**Happy coding! 🚀**
