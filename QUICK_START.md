# ⚡ Quick Start Guide

Khởi chạy project này trong 5 phút.

## Yêu cầu tối thiểu

- Python 3.8+
- Máy tính có thể truy cập internet

## 1️⃣ Clone/Download Project

```bash
cd telecode
```

## 2️⃣ Setup Project

```bash
# Tạo virtual environment
python3 -m venv venv
source venv/bin/activate  # Linux/Mac
# hoặc: venv\Scripts\activate  # Windows

# Cài dependencies
pip install -r requirements.txt

# Copy config
cp config.example.yaml config.yaml
nano config.yaml  # Chỉnh sửa nếu cần
```

**Chỉnh sửa config.yaml:**
```yaml
OPENAI_API_KEY: ""  # Tuỳ chọn — API key 9Router/OpenAI (thường sk-..., KHÔNG dùng token AQ...), để trống nếu chưa dùng
VSCODE_PUBLIC_URL: "http://localhost:8443"  # Tạm thời (sẽ update sau)
```

> Lưu ý: cách setup thủ công từng bước ở file này đã cũ — cách khuyến nghị hiện tại là chạy thẳng `bash setup.sh` (xem README.md), script sẽ tự hỏi/cài mọi thứ kể cả bước Codex CLI này.

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

## 6️⃣ Truy cập từ điện thoại (app Telecode)

1. Cài app Telecode trên điện thoại (Android `.apk`) hoặc mở app desktop Tauri trên máy tính khác.
2. Bấm icon ⚙️ (bánh răng) ở góc trên.
3. Dán URL tunnel (vd Tailscale Funnel) hiển thị ở bước cấu hình.
4. 🎉 VS Code sẽ mở ngay trong app!

---

## 🐛 Troubleshooting

### Không thể kết nối VS Code
```bash
# Code-server chạy?
curl http://localhost:8443

# Tunnel chạy?
# (Terminal tunnel phải còn chạy)
```

---

## 📚 Bước Tiếp Theo

- ✅ Đọc **README.md** để tìm hiểu kỹ hơn
- ✅ Xem **CLAUDE.md** để AI có thể giúp
- ✅ Build app Telecode desktop/Android (xem CLAUDE.md)

---

## 💡 Tips

- **Port conflicts**: Thay đổi port trong `config.yaml`
- **Security**: Bật password cho code-server
- **Offline mode**: Tunnel giúp bạn truy cập từ bất kỳ đâu

---

**Happy coding! 🚀**
