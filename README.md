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

### Cách nhanh nhất — 1 lệnh (khuyến nghị)

```bash
curl -fsSL https://gitlab.com/pvgiang396/telecode/-/raw/main/scripts/install.sh | bash
```

Lệnh này tự clone repo về `~/telecode` (hoặc `$TELECODE_DIR` nếu bạn đặt biến môi trường này), rồi chạy `setup.sh` — script tự kiểm tra/cài `code-server` + `cloudflared`, mở 2 tunnel (VS Code + mini_app.html), hỏi Telegram Bot Token, ghi `config.yaml`, rồi khởi động bot nền. Chạy lại đúng lệnh này bất cứ lúc nào để cập nhật code + khởi động lại — script hỏi giữ nguyên hay cài/chạy lại từng phần, không hỏi lại token nếu đã cấu hình.

Cần chuẩn bị trước: token bot Telegram từ [@BotFather](https://t.me/BotFather) (gửi `/newbot` trên điện thoại).

Đây là repo **public** (ai cũng curl/clone được) nhưng chỉ chủ tài khoản GitLab mới push được — dùng để cài, không dùng để đóng góp code.

### Cách thủ công (nếu muốn kiểm soát từng bước)

```bash
git clone https://gitlab.com/pvgiang396/telecode.git
cd telecode
bash setup.sh
```

`setup.sh` làm toàn bộ các việc: cài code-server + cloudflared, tạo password, chạy code-server nền, mở tunnel, tự sửa `mini_app.html`, tạo `config.yaml` từ `config.example.yaml`, cài dependency Python (venv riêng), và chạy `bot.py` nền. Chạy lại `bash setup.sh` bất cứ lúc nào — idempotent, không tạo tiến trình trùng lặp.

### Trên Telegram

- Mở bot (search username bot của bạn)
- Gửi `/start`
- Click nút "🔧 Open VS Code"
- VS Code sẽ mở trong Telegram Mini App!

## 🐳 Cách chạy với Docker (thay thế setup.sh)

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
