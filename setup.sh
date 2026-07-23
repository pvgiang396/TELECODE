#!/bin/bash
#
# Telegram VS Code Mini App - Setup tổng hợp (idempotent, chạy lại được nhiều lần)
#
# Thay cho việc gõ tay từng bước (cài code-server, cloudflared, tạo tunnel, sửa
# config...), script này tự kiểm tra từng bước đã làm chưa và hỏi bạn muốn GIỮ
# giá trị cũ hay NHẬP giá trị mới. Chạy: bash setup.sh
#
# Lưu ý: code-server cài qua script chính thức của tác giả (code-server.dev) —
# domain đó không thuộc quyền chỉnh sửa của chúng ta nên không thể gộp thẳng
# vào 1 lệnh `curl | sh`, script này gọi nó hộ bạn ở bước cần thiết.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$DIR/.run"
LOG_DIR="$DIR/logs"
mkdir -p "$RUN_DIR" "$LOG_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info()  { echo -e "${BLUE}➜${NC} $1"; }
ok()    { echo -e "${GREEN}✅${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠️  $1${NC}"; }
err()   { echo -e "${RED}❌ $1${NC}"; }

# --- Helpers hỏi giữ giá trị cũ / nhập mới ------------------------------

# ask_value <nhãn> <giá_trị_hiện_tại|""> <secret:0|1>
ask_value() {
    local label="$1" current="$2" secret="${3:-0}" display input
    # Đọc từ /dev/tty (không phải stdin): khi chạy qua `curl | bash`, stdin bị
    # chiếm bởi nội dung script tải về nên `read` mặc định không hỏi được gì.
    if [ -n "$current" ]; then
        if [ "$secret" = "1" ]; then display="********"; else display="$current"; fi
        read -rp "$label [hiện tại: $display] — Enter để giữ, hoặc nhập giá trị mới: " input < /dev/tty
        [ -z "$input" ] && { echo "$current"; return; }
        echo "$input"
    else
        read -rp "$label (chưa có giá trị, bắt buộc nhập): " input < /dev/tty
        while [ -z "$input" ]; do read -rp "  → không được để trống, nhập lại: " input < /dev/tty; done
        echo "$input"
    fi
}

# ask_choice <mô tả trạng thái hiện tại> -> in ra "keep" hoặc "redo"
ask_choice() {
    local desc="$1" choice
    echo "$desc"
    read -rp "  1) Giữ nguyên   2) Cài lại/khởi động lại  [mặc định 1]: " choice < /dev/tty
    choice=${choice:-1}
    [ "$choice" = "2" ] && echo "redo" || echo "keep"
}

is_alive() { # is_alive <pidfile>
    [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null
}

stop_pid() { # stop_pid <pidfile>
    if is_alive "$1"; then kill "$(cat "$1")" 2>/dev/null; sleep 1; fi
    rm -f "$1"
}

OS="linux"
[ "$(uname -s)" = "Darwin" ] && OS="mac"

echo "======================================"
echo "🚀 Telegram VS Code Mini App - Setup"
echo "======================================"
echo ""

# --- 1. code-server ------------------------------------------------------
if command -v code-server &>/dev/null; then
    CURRENT_VER="$(code-server --version 2>/dev/null | head -n1)"
    if [ "$(ask_choice "1) code-server: đã cài (${CURRENT_VER})")" = "redo" ]; then
        curl -fsSL https://code-server.dev/install.sh | sh
    fi
else
    info "1) code-server chưa cài, đang cài..."
    curl -fsSL https://code-server.dev/install.sh | sh
fi
ok "code-server sẵn sàng: $(command -v code-server)"
echo ""

# --- 2. Password code-server ---------------------------------------------
CS_CONFIG="$HOME/.config/code-server/config.yaml"
mkdir -p "$(dirname "$CS_CONFIG")"
CURRENT_PW=""
[ -f "$CS_CONFIG" ] && CURRENT_PW="$(grep '^password:' "$CS_CONFIG" | sed 's/^password: *//')"
CS_PASSWORD="$(ask_value "2) Mật khẩu code-server" "$CURRENT_PW" 1)"
cat > "$CS_CONFIG" <<EOF
bind-addr: 127.0.0.1:8443
auth: password
password: $CS_PASSWORD
cert: false
EOF
ok "Đã ghi $CS_CONFIG"
echo ""

# --- 3. Chạy code-server nền ----------------------------------------------
CS_PID="$RUN_DIR/code-server.pid"
if is_alive "$CS_PID"; then
    if [ "$(ask_choice "3) code-server: đang chạy (PID $(cat "$CS_PID"))")" = "redo" ]; then
        stop_pid "$CS_PID"
    fi
fi
if ! is_alive "$CS_PID"; then
    nohup code-server --bind-addr 127.0.0.1:8443 "$HOME" > "$LOG_DIR/code-server.log" 2>&1 &
    echo $! > "$CS_PID"
    sleep 2
    ok "code-server đang chạy tại http://localhost:8443 (PID $(cat "$CS_PID"))"
fi
echo ""

# --- 4. cloudflared --------------------------------------------------------
if command -v cloudflared &>/dev/null; then
    CURRENT_VER="$(cloudflared --version 2>/dev/null | head -n1)"
    if [ "$(ask_choice "4) cloudflared: đã cài (${CURRENT_VER})")" = "redo" ]; then
        if [ "$OS" = "mac" ]; then brew install cloudflared
        else
            TMP_DEB="$(mktemp --suffix=.deb)"
            curl -fsSL -o "$TMP_DEB" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
            sudo dpkg -i "$TMP_DEB"
        fi
    fi
else
    info "4) cloudflared chưa cài, đang cài..."
    if [ "$OS" = "mac" ]; then brew install cloudflared
    else
        TMP_DEB="$(mktemp --suffix=.deb)"
        curl -fsSL -o "$TMP_DEB" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
        sudo dpkg -i "$TMP_DEB"
    fi
fi
ok "cloudflared sẵn sàng: $(command -v cloudflared)"
echo ""

# --- 5. Tunnel cho code-server ---------------------------------------------
wait_for_url() { # wait_for_url <logfile> -> in ra URL khi tìm thấy, timeout 30s
    local log="$1" i=0 url=""
    while [ $i -lt 30 ]; do
        url="$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$log" 2>/dev/null | head -n1)"
        [ -n "$url" ] && { echo "$url"; return 0; }
        sleep 1; i=$((i+1))
    done
    return 1
}

T1_PID="$RUN_DIR/tunnel-code.pid"
T1_LOG="$LOG_DIR/tunnel-code.log"
if is_alive "$T1_PID" && [ -n "$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$T1_LOG" 2>/dev/null | head -n1)" ]; then
    if [ "$(ask_choice "5) Tunnel code-server: đang chạy ($(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$T1_LOG" | head -n1))")" = "redo" ]; then
        stop_pid "$T1_PID"; > "$T1_LOG"
    fi
fi
if ! is_alive "$T1_PID"; then
    info "Đang mở tunnel cho code-server..."
    nohup cloudflared tunnel --url http://localhost:8443 > "$T1_LOG" 2>&1 &
    echo $! > "$T1_PID"
fi
VSCODE_PUBLIC_URL="$(wait_for_url "$T1_LOG")" || { err "Không lấy được URL tunnel code-server, xem $T1_LOG"; exit 1; }
ok "VS Code tunnel: $VSCODE_PUBLIC_URL"
echo ""

# --- 6. Tunnel cho mini_app.html -------------------------------------------
STATIC_PID="$RUN_DIR/static-server.pid"
if ! is_alive "$STATIC_PID"; then
    (cd "$DIR" && nohup python3 -m http.server 8000 > "$LOG_DIR/static-server.log" 2>&1 &)
    echo $(pgrep -f "http.server 8000" | tail -n1) > "$STATIC_PID"
    sleep 1
fi

T2_PID="$RUN_DIR/tunnel-miniapp.pid"
T2_LOG="$LOG_DIR/tunnel-miniapp.log"
if is_alive "$T2_PID" && [ -n "$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$T2_LOG" 2>/dev/null | head -n1)" ]; then
    if [ "$(ask_choice "6) Tunnel mini_app.html: đang chạy ($(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$T2_LOG" | head -n1))")" = "redo" ]; then
        stop_pid "$T2_PID"; > "$T2_LOG"
    fi
fi
if ! is_alive "$T2_PID"; then
    info "Đang mở tunnel cho mini_app.html..."
    nohup cloudflared tunnel --url http://localhost:8000 > "$T2_LOG" 2>&1 &
    echo $! > "$T2_PID"
fi
MINIAPP_HOST_URL="$(wait_for_url "$T2_LOG")" || { err "Không lấy được URL tunnel mini_app.html, xem $T2_LOG"; exit 1; }
MINI_APP_URL="$MINIAPP_HOST_URL/mini_app.html"
ok "Mini App tunnel: $MINI_APP_URL"
echo ""

# --- 7. Ghi VSCODE_PUBLIC_URL vào mini_app.html -----------------------------
sed -i.bak -E "s#VSCODE_PUBLIC_URL: '[^']*'#VSCODE_PUBLIC_URL: '$VSCODE_PUBLIC_URL'#" "$DIR/mini_app.html"
rm -f "$DIR/mini_app.html.bak"
ok "Đã cập nhật VSCODE_PUBLIC_URL trong mini_app.html"
echo ""

# --- 8. Telegram Bot Token ---------------------------------------------------
CONFIG_FILE="$DIR/config.yaml"
[ -f "$CONFIG_FILE" ] || cp "$DIR/config.example.yaml" "$CONFIG_FILE"
CURRENT_TOKEN="$(grep '^TELEGRAM_BOT_TOKEN:' "$CONFIG_FILE" | sed -E 's/^TELEGRAM_BOT_TOKEN: *"?([^"]*)"?/\1/')"
[ "$CURRENT_TOKEN" = "YOUR_BOT_TOKEN_HERE" ] && CURRENT_TOKEN=""
echo "8) Token bot Telegram — lấy từ @BotFather (gửi /newbot trên điện thoại nếu chưa có)."
BOT_TOKEN="$(ask_value "   Token" "$CURRENT_TOKEN" 1)"
echo ""

# --- 9. Ghi config.yaml -------------------------------------------------------
cat > "$CONFIG_FILE" <<EOF
TELEGRAM_BOT_TOKEN: "$BOT_TOKEN"
VSCODE_PORT: 8443
VSCODE_PASSWORD: "$CS_PASSWORD"
VSCODE_PUBLIC_URL: "$VSCODE_PUBLIC_URL"
MINI_APP_URL: "$MINI_APP_URL"
BOT_POLLING_INTERVAL: 30
BOT_TIMEOUT: 30
VSCODE_AUTH_REQUIRED: true
VSCODE_ALLOW_INSECURE: false
LOG_LEVEL: "INFO"
ENABLE_DEBUG_MODE: false
ALLOW_MULTIPLE_CONNECTIONS: false
EOF
ok "Đã ghi $CONFIG_FILE"
echo ""

# --- 10. Python venv + dependencies -------------------------------------------
if [ ! -d "$DIR/venv" ]; then
    info "10) Tạo virtualenv..."
    python3 -m venv "$DIR/venv"
fi
# shellcheck disable=SC1091
source "$DIR/venv/bin/activate"
pip install --upgrade pip -q
pip install -r "$DIR/requirements.txt" -q
ok "Dependencies Python sẵn sàng"
echo ""

# --- 11. Chạy bot ----------------------------------------------------------------
BOT_PID="$RUN_DIR/bot.pid"
if is_alive "$BOT_PID"; then
    if [ "$(ask_choice "11) Bot: đang chạy (PID $(cat "$BOT_PID"))")" = "redo" ]; then
        stop_pid "$BOT_PID"
    fi
fi
if ! is_alive "$BOT_PID"; then
    (cd "$DIR" && nohup "$DIR/venv/bin/python3" bot.py > "$LOG_DIR/bot.log" 2>&1 &)
    sleep 1
    echo "$(pgrep -f "$DIR/venv/bin/python3 bot.py" | tail -n1)" > "$BOT_PID"
fi
ok "Bot đang chạy (PID $(cat "$BOT_PID"))"
echo ""

echo "======================================"
ok "Setup xong!"
echo "======================================"
echo ""
echo "📱 Trên điện thoại: mở Telegram → tìm bot của bạn → /start → bấm '🔧 Open VS Code'"
echo "🔗 VS Code URL : $VSCODE_PUBLIC_URL"
echo "🔗 Mini App URL: $MINI_APP_URL"
echo "📄 Log: $LOG_DIR/"
echo ""
echo "Chạy lại 'bash setup.sh' bất cứ lúc nào — script sẽ hỏi giữ nguyên hay khởi động lại từng phần."
