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

**Linux / macOS:**

```bash
curl -fsSL https://gitlab.com/pvgiang396/telecode/-/raw/main/scripts/install.sh | bash
```

**Windows:**

```powershell
powershell -ExecutionPolicy Bypass -Command "irm https://gitlab.com/pvgiang396/telecode/-/raw/main/scripts/install.ps1 | iex"
```
code-server chỉ hỗ trợ chính thức Linux/macOS — trên Windows lệnh trên tự cài WSL2 (Ubuntu) nếu chưa có, rồi chạy `install.sh` bên trong đó. Nếu WSL vừa được cài lần đầu, làm theo hướng dẫn khởi động lại máy rồi chạy lại đúng lệnh.

Lệnh trên tự clone repo về `~/telecode` (hoặc `$TELECODE_DIR` nếu bạn đặt biến môi trường này), rồi chạy `setup.sh`.

**Trên máy có giao diện (desktop Linux/macOS, hoặc Windows qua WSL)**: `setup.sh` tự mở 1 trang web (`http://127.0.0.1:8899`) cho bạn điền cấu hình bằng radio/input thay vì hỏi qua terminal — điền xong bấm "Bắt đầu cài đặt", việc cài đặt thật (code-server, cloudflared, tunnel, bot) chuyển sang chạy nền, terminal trả quyền điều khiển lại ngay, có thể đóng terminal an toàn. Chạy lại đúng lệnh Quick Start bất cứ lúc nào để cập nhật/khởi động lại — form tự hiện đúng bước cần hỏi dựa theo trạng thái máy hiện tại (đã cài gì, đang chạy gì), không hỏi lại token/mật khẩu nếu đã cấu hình (chỉ hiện sẵn giá trị cũ).

**Trên máy không có giao diện (server/VPS headless thật sự)**: tự động fallback về hỏi qua terminal như trước (radio ↑/↓ + Enter, nhập text) — không cần trình duyệt.

Cần chuẩn bị trước: token bot Telegram từ [@BotFather](https://t.me/BotFather) (gửi `/newbot` trên điện thoại).

Tuỳ chọn: nhập thêm `OPENAI_API_KEY` (bước 6b) để `setup.sh` tự cài + cấu hình sẵn Codex CLI extension trong VS Code, dùng qua "9Router" (proxy OpenAI-compatible trỏ Gemini) — không cần tự cài extension/dán file cấu hình tay. **Phải dùng API key của 9Router/OpenAI (thường dạng `sk-...`), không dùng token Codex (`AQ...`)**. Để trống nếu chưa dùng, có thể chạy lại `setup.sh` sau để bổ sung.

Đây là repo **public** (ai cũng curl/clone được) nhưng chỉ chủ tài khoản GitLab mới push được — dùng để cài, không dùng để đóng góp code.

### Cách thủ công (nếu muốn kiểm soát từng bước)

```bash
git clone https://gitlab.com/pvgiang396/telecode.git
cd telecode
bash setup.sh
```

`setup.sh` làm toàn bộ các việc: mở wizard web thu thập cấu hình (hoặc hỏi qua terminal nếu headless), cài code-server + cloudflared, thêm icon hiện/ẩn mật khẩu + chặn F12/chuột phải vào trang login code-server, tạo password, chạy code-server nền, tạo shortcut Desktop, mở tunnel, tạo `config.yaml` từ `config.example.yaml`, cài dependency Python (venv riêng), và chạy `bot.py` nền. Chạy lại `bash setup.sh` bất cứ lúc nào — idempotent, không tạo tiến trình trùng lặp.

### Trên Telegram

- Mở bot (search username bot của bạn)
- Gửi `/start`
- Bấm nút "🔧 VS Code" cạnh khung nhập tin nhắn (menu button)
- VS Code (code-server) mở **trực tiếp** trong Mini App (không qua iframe trung gian) — đăng nhập bằng mật khẩu đã đặt ở bước cấu hình `config.yaml`.

### Trên máy tính (dùng như VS Code desktop)

`setup.sh` tự tạo 1 shortcut trên Desktop ("Telecode", dùng icon riêng `assets/icon.png`) mở thẳng `http://localhost:8443` — nhanh hơn nhiều so với qua Telegram/tunnel vì không qua Cloudflare. Đây là **cùng 1 phiên làm việc** với bản mở từ điện thoại (cùng file, cùng extension host) — mở song song ở cả 2 nơi vẫn an toàn.

`setup.sh` cũng tự thay favicon/PWA icon của code-server bằng icon riêng — icon hiện trên **taskbar** khi mở qua Chrome `--app=` lấy từ favicon của trang, không phải từ `Icon=` trong file shortcut. Nếu taskbar vẫn hiện icon cũ, thử mở lại cửa sổ app-mode hoặc xoá site data của Chrome cho `localhost:8443` (Chrome cache icon theo origin).

Nếu máy có Chrome/Edge/Chromium, shortcut mở bằng chế độ `--app=` — ẩn thanh địa chỉ/tab, trông như 1 app desktop thật thay vì tab trình duyệt. Không có trình duyệt nào trong nhóm đó thì tự fallback về mở tab thường.

## 🐳 Cách chạy với Docker (thay thế setup.sh)

```bash
docker-compose up -d

# Xem logs
docker-compose logs -f

# Stop
docker-compose down
```

## 🔐 Bảo Mật

### Giới hạn thư mục code-server mở

`setup.sh` chỉ mở `~/Code` (không mở cả `$HOME`) — tránh việc ai vào được VS Code từ điện thoại cũng duyệt/sửa được mọi file khác trong home directory. Muốn trỏ thư mục khác, đặt biến môi trường trước khi chạy:

```bash
CODE_SERVER_WORKSPACE=~/my-project bash setup.sh
```

Nếu thư mục không tồn tại, script tự cảnh báo và fallback về `$HOME`.

### Chặn F12/chuột phải ở trang login — chỉ mang tính hình thức

`setup.sh` tự thêm JS chặn F12 và menu chuột phải vào trang **login** code-server (không đụng workbench sau khi đăng nhập — F12 trong VS Code là phím tắt "Go to Definition", chặn toàn trang sẽ phá tính năng đó khi đang code). Lưu ý: JS không thể chặn DevTools trình duyệt thật — đây chỉ là ngăn cản sơ đẳng, không phải cơ chế bảo mật.

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
telecode/
├── bot.py                 # Telegram bot chính — nút mở thẳng VSCODE_PUBLIC_URL
├── mini_app.html          # KHÔNG dùng trong luồng mặc định nữa (xem "Vì sao không dùng iframe" bên dưới) — giữ lại để tham khảo
├── wizard.py              # Server nhỏ (stdlib) phục vụ giao diện cài đặt web thay cho hỏi qua terminal
├── assets/wizard.html     # Trang wizard cài đặt (1 file tĩnh, inline CSS/JS)
├── assets/icon.png        # Icon Desktop shortcut
├── assets/icon.ico        # Icon Desktop shortcut (Windows .lnk)
├── requirements.txt       # Python dependencies
├── config.example.yaml    # File cấu hình mẫu
├── docker-compose.yml     # Docker setup
├── Dockerfile             # Container config
├── setup.sh              # Setup script chính (idempotent)
├── scripts/install.sh    # Bootstrap cài qua curl (Linux/macOS)
├── scripts/install.ps1   # Bootstrap cài qua PowerShell (Windows, dùng WSL2)
├── README.md             # File này
├── CLAUDE.md             # Hướng dẫn cho Claude AI
└── .env.example          # Biến môi trường mẫu
```

### Vì sao không dùng iframe (mini_app.html)?

Bản đầu mở VS Code qua iframe (`mini_app.html` nhúng code-server từ 1 tunnel khác). code-server đặt cookie `SameSite=Lax` — khi load trong iframe khác domain, nhiều WebView di động (đặc biệt iOS WKWebView mà Telegram dùng) coi cookie này là bên thứ 3 và chặn lưu, khiến đăng nhập đúng mật khẩu vẫn quay lại y hệt màn login. Nút bot giờ mở **thẳng** URL code-server (top-level navigation trong Mini App) — cookie thành first-party, hoạt động bình thường.

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

### Đăng nhập đúng mật khẩu nhưng bị đá về lại màn login
- Đây là lỗi third-party cookie khi chạy qua iframe (xem mục "Vì sao không dùng iframe" ở trên) — bản hiện tại đã mở thẳng URL, không còn iframe nữa. Nếu vẫn gặp, kiểm tra `config.yaml`/`~/.config/code-server/config.yaml` có cùng 1 password và code-server đã được **restart** sau khi đổi password (code-server chỉ đọc config lúc khởi động).

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

### Customize giao diện đăng nhập
Trang login (`{cài đặt code-server}/src/browser/pages/login.html` + `login.css`) được `setup.sh` tự vá thêm icon hiện/ẩn mật khẩu — sửa trực tiếp hàm `patch_code_server_login()` trong `setup.sh` nếu muốn tuỳ biến thêm.

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
