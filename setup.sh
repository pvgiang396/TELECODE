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
# Menu radio 2 dòng chọn bằng phím mũi tên (↑/↓ + Enter), mặc định "Giữ nguyên".
# Fallback về nhập số 1/2 nếu không có TTY thật (vd chạy trong CI/pipe không gắn terminal).
ask_choice() {
    local desc="$1" choice
    echo "$desc"

    if [ ! -r /dev/tty ]; then
        read -rp "  1) Giữ nguyên   2) Cài lại/khởi động lại  [mặc định 1]: " choice
        choice=${choice:-1}
        [ "$choice" = "2" ] && echo "redo" || echo "keep"
        return
    fi

    local opts=("Giữ nguyên" "Cài lại / khởi động lại") sel=0 i key rest
    tput civis 2>/dev/null
    for i in "${!opts[@]}"; do echo "  ○ ${opts[$i]}"; done
    while true; do
        # Vẽ lại 2 dòng: đưa con trỏ lên đầu danh sách rồi in lại có đánh dấu ●
        tput cuu "${#opts[@]}" 2>/dev/null
        for i in "${!opts[@]}"; do
            tput el 2>/dev/null
            if [ "$i" -eq "$sel" ]; then echo "  ${GREEN}●${NC} ${opts[$i]}"; else echo "  ○ ${opts[$i]}"; fi
        done
        IFS= read -rsn1 key < /dev/tty
        if [ "$key" = $'\x1b' ]; then
            read -rsn2 -t 0.01 rest < /dev/tty
            key+="$rest"
            case "$key" in
                $'\x1b[A') sel=0 ;; # mũi tên lên
                $'\x1b[B') sel=1 ;; # mũi tên xuống
            esac
        elif [ -z "$key" ]; then
            break # Enter
        fi
    done
    tput cnorm 2>/dev/null
    [ "$sel" -eq 1 ] && echo "redo" || echo "keep"
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

# --- 1b. Patch trang login code-server: thêm icon hiện/ẩn mật khẩu ---------
# code-server không có tuỳ chọn chính thức để tuỳ biến trang login -> vá thẳng
# file HTML/CSS đóng gói sẵn (login.js đọc lại các file này ở MỖI request, không
# cache, nên áp dụng ngay, không cần restart). Nhược điểm: bị ghi đè mỗi khi
# code-server cài lại/nâng cấp -> gọi hàm này lại mỗi lần chạy setup.sh (idempotent
# qua marker "telecode-eye-toggle").
find_code_server_root() {
    local bin resolved dir
    bin="$(command -v code-server)" || return 1
    resolved="$(readlink -f "$bin" 2>/dev/null || echo "$bin")"
    dir="$(dirname "$resolved")"
    while [ "$dir" != "/" ]; do
        [ -f "$dir/src/browser/pages/login.html" ] && { echo "$dir"; return 0; }
        dir="$(dirname "$dir")"
    done
    for p in /usr/lib/code-server /usr/local/lib/code-server "$HOME/.local/lib/code-server"; do
        [ -f "$p/src/browser/pages/login.html" ] && { echo "$p"; return 0; }
    done
    return 1
}

patch_code_server_login() {
    local root html css
    root="$(find_code_server_root)" || { warn "Không tìm thấy thư mục cài code-server để thêm icon hiện mật khẩu, bỏ qua."; return; }
    html="$root/src/browser/pages/login.html"
    css="$root/src/browser/pages/login.css"
    grep -q "telecode-eye-toggle" "$html" 2>/dev/null && return

    info "1b) Thêm icon hiện/ẩn mật khẩu vào trang đăng nhập code-server..."
    local SUDO=""
    [ -w "$html" ] || SUDO="sudo"
    $SUDO python3 - "$html" "$css" <<'PYEOF'
import sys

html_path, css_path = sys.argv[1], sys.argv[2]

with open(html_path, "r", encoding="utf-8") as f:
    html = f.read()

old = '''            <div class="field">
              <input
                required
                autofocus
                class="password"
                type="password"
                placeholder="{{I18N_PASSWORD_PLACEHOLDER}}"
                name="password"
                autocomplete="current-password"
              />
              <input class="submit -button" value="{{I18N_SUBMIT}}" type="submit" />
            </div>'''

new = '''            <!-- telecode-eye-toggle -->
            <div class="field">
              <div class="password-wrap">
                <input
                  required
                  autofocus
                  class="password"
                  type="password"
                  placeholder="{{I18N_PASSWORD_PLACEHOLDER}}"
                  name="password"
                  autocomplete="current-password"
                />
                <button type="button" class="toggle-password" aria-label="Hien/an mat khau" onclick="var p=this.previousElementSibling; var showing=p.type==='text'; p.type = showing ? 'password' : 'text'; this.textContent = showing ? String.fromCodePoint(0x1F441) : String.fromCodePoint(0x1F648);">&#128065;</button>
              </div>
              <input class="submit -button" value="{{I18N_SUBMIT}}" type="submit" />
            </div>'''

if old in html:
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(html.replace(old, new))
else:
    print("WARN: khong tim thay khoi HTML mat khau de patch (co the code-server da doi cau truc)")
    sys.exit(0)

css_addition = """

/* telecode-eye-toggle */
.password-wrap {
  position: relative;
  flex: 1;
  display: flex;
}
.password-wrap > .password {
  flex: 1;
  padding-right: 40px;
}
.password-wrap > .toggle-password {
  position: absolute;
  right: 8px;
  top: 50%;
  transform: translateY(-50%);
  background: none;
  border: none;
  cursor: pointer;
  font-size: 18px;
  line-height: 1;
  padding: 4px;
}
"""
with open(css_path, "a", encoding="utf-8") as f:
    f.write(css_addition)
PYEOF
    if grep -q "telecode-eye-toggle" "$html" 2>/dev/null; then
        ok "Đã thêm icon hiện/ẩn mật khẩu vào trang login code-server"
    else
        warn "Không patch được trang login (có thể phiên bản code-server đã đổi cấu trúc HTML) — bỏ qua, không chặn setup"
    fi
}
patch_code_server_login
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
if [ "$CS_PASSWORD" != "$CURRENT_PW" ] && is_alive "$CS_PID"; then
    # code-server chỉ đọc config.yaml lúc khởi động — đổi mật khẩu mà không restart
    # thì tiến trình cũ vẫn dùng mật khẩu cũ trong bộ nhớ, gõ mật khẩu mới sẽ luôn sai.
    warn "Mật khẩu vừa đổi — bắt buộc khởi động lại code-server để áp dụng."
    stop_pid "$CS_PID"
elif is_alive "$CS_PID"; then
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
    (cd "$DIR" && nohup python3 -m http.server 8000 > "$LOG_DIR/static-server.log" 2>&1 & echo $! > "$STATIC_PID")
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
VENV_PY="$DIR/venv/bin/python3"
if ! "$VENV_PY" -m pip --version &>/dev/null; then
    # Một số bản Linux (Debian/Ubuntu) tách ensurepip ra khỏi python3 mặc định
    # -> venv tạo ra không có pip, cài dependency thất bại âm thầm. Bootstrap
    # bằng get-pip.py thay vì dựa vào ensurepip/apt (không cần sudo).
    warn "venv thiếu pip, đang bootstrap qua get-pip.py..."
    curl -fsSL https://bootstrap.pypa.io/get-pip.py -o "$RUN_DIR/get-pip.py"
    "$VENV_PY" "$RUN_DIR/get-pip.py" -q
fi
"$VENV_PY" -m pip install --upgrade pip -q
"$VENV_PY" -m pip install -r "$DIR/requirements.txt" -q
if ! "$VENV_PY" -c "import yaml, telegram, dotenv" &>/dev/null; then
    err "Cài dependency Python thất bại — kiểm tra $LOG_DIR hoặc chạy tay: $VENV_PY -m pip install -r requirements.txt"
    exit 1
fi
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
    (cd "$DIR" && nohup "$VENV_PY" bot.py > "$LOG_DIR/bot.log" 2>&1 & echo $! > "$BOT_PID")
    sleep 1
    if ! is_alive "$BOT_PID"; then
        err "Bot khởi động rồi thoát ngay — xem log: $LOG_DIR/bot.log"
        exit 1
    fi
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
