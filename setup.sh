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
#
# Khi chạy ở chế độ "áp dụng nền" sau wizard web (TELECODE_APPLYING=1), câu trả
# lời đã có sẵn trong $ANSWERS_FILE (JSON do wizard.py ghi) — ask_value/ask_choice
# đọc thẳng từ đó thay vì hỏi qua terminal, không cần sửa lại phần thân script
# ở dưới (các bước 1→9 gọi y hệt, chỉ thêm 1 tham số "key" để tra JSON).
answers_get() { # answers_get <key> -> in ra giá trị hoặc rỗng nếu không có/không áp dụng
    local key="$1"
    [ "${TELECODE_APPLYING:-0}" = "1" ] && [ -f "$ANSWERS_FILE" ] || return 1
    python3 -c "import json,sys
try:
    d = json.load(open('$ANSWERS_FILE'))
    print(d.get('$key',''))
except Exception:
    pass" 2>/dev/null
}

# ask_value <nhãn> <giá_trị_hiện_tại|""> <secret:0|1> [key_trong_wizard_json]
ask_value() {
    local label="$1" current="$2" secret="${3:-0}" key="${4:-}" display input
    if [ -n "$key" ]; then
        input="$(answers_get "$key")"
        [ -z "$input" ] && input="$current"
        echo "$input"
        return
    fi
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
#
# QUAN TRỌNG: hàm này luôn được gọi qua "$(ask_choice ...)" để lấy kết quả trả về
# ("keep"/"redo") -> command substitution chụp TOÀN BỘ stdout của hàm vào biến, kể
# cả những echo chỉ nhằm hiển thị menu. Vì vậy mọi thứ hiển thị cho người dùng thấy
# (mô tả, 2 dòng radio, con trỏ) phải ghi thẳng ra /dev/tty — CHỈ dòng "keep"/"redo"
# cuối cùng mới được echo ra stdout thật. Quên tách 2 kênh này là màn hình trắng,
# script treo im lặng chờ phím mà người dùng không biết phải bấm gì.
ask_choice() {
    local desc="$1" json_key="${2:-}" choice
    if [ -n "$json_key" ]; then
        choice="$(answers_get "$json_key")"
        [ "$choice" = "redo" ] && echo "redo" || echo "keep"
        return
    fi
    echo "$desc" > /dev/tty

    if [ ! -r /dev/tty ]; then
        read -rp "  1) Giữ nguyên   2) Cài lại/khởi động lại  [mặc định 1]: " choice
        choice=${choice:-1}
        [ "$choice" = "2" ] && echo "redo" || echo "keep"
        return
    fi

    local opts=("Giữ nguyên" "Cài lại / khởi động lại") sel=0 i key rest
    {
        tput civis 2>/dev/null
        for i in "${!opts[@]}"; do echo "  ○ ${opts[$i]}"; done
    } > /dev/tty
    while true; do
        # Vẽ lại 2 dòng: đưa con trỏ lên đầu danh sách rồi in lại có đánh dấu ●
        {
            tput cuu "${#opts[@]}" 2>/dev/null
            for i in "${!opts[@]}"; do
                tput el 2>/dev/null
                if [ "$i" -eq "$sel" ]; then echo -e "  ${GREEN}●${NC} ${opts[$i]}"; else echo "  ○ ${opts[$i]}"; fi
            done
        } > /dev/tty
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
    tput cnorm > /dev/tty 2>/dev/null
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

ANSWERS_FILE="$RUN_DIR/wizard-answers.json"

# --- GUI wizard: thay hỏi từng bước qua terminal bằng 1 trang web ------------
# Có GUI (desktop Linux/macOS, hoặc WSL — WSLg/Windows tự mở được trình duyệt) ->
# mở wizard.py (xem file đó), đợi user điền form rồi submit, sau đó chuyển toàn bộ
# phần cài đặt thật sang tiến trình nền (không giữ terminal), tự thoát ngay để trả
# lại quyền điều khiển terminal cho user. Không có GUI (server/VPS headless thật
# sự) -> giữ nguyên luồng hỏi qua terminal như cũ (ask_choice/ask_value ở dưới).
HAS_GUI=0
if [ "$OS" = "mac" ]; then
    HAS_GUI=1
elif [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    HAS_GUI=1
elif grep -qi microsoft /proc/version 2>/dev/null; then
    HAS_GUI=1  # WSL — mở trình duyệt Windows được qua cmd.exe
fi

if [ "$HAS_GUI" = "1" ] && [ "${TELECODE_APPLYING:-0}" != "1" ]; then
    echo "======================================"
    echo "🚀 Cài đặt telecode — mở giao diện web"
    echo "======================================"
    echo ""
    rm -f "$ANSWERS_FILE"
    info "Đang mở trình duyệt để cấu hình (http://127.0.0.1:8899)..."
    # $PPID = PID shell cha (terminal tương tác) — với `curl|bash` thì install.sh
    # dùng `exec bash setup.sh` nên PID không đổi xuyên suốt, $PPID ở đây chính là
    # shell người dùng gõ lệnh; với `bash setup.sh` gõ tay cũng đúng tương tự.
    # Truyền cho wizard.py để sau khi cài xong tự kill, đóng luôn terminal.
    python3 "$DIR/wizard.py" "$RUN_DIR" "$DIR" "$PPID"
    if [ ! -f "$ANSWERS_FILE" ]; then
        err "Chưa nhận được câu trả lời (có thể bạn đóng tab trước khi bấm 'Bắt đầu cài đặt') — chạy lại 'bash setup.sh' để thử lại."
        exit 1
    fi
    ok "Đã nhận cấu hình — chuyển cài đặt sang chạy nền, terminal sẽ tự đóng khi xong."
    TELECODE_APPLYING=1 nohup bash "$0" > "$LOG_DIR/setup-apply.log" 2>&1 &
    disown
    echo "📄 Theo dõi tiến trình (không bắt buộc): tail -f $LOG_DIR/setup-apply.log"
    exit 0
fi

echo "======================================"
echo "🚀 Telegram VS Code Mini App - Setup"
echo "======================================"
echo ""

# --- 1. code-server ------------------------------------------------------
if command -v code-server &>/dev/null; then
    CURRENT_VER="$(code-server --version 2>/dev/null | head -n1)"
    if [ "$(ask_choice "1) code-server: đã cài (${CURRENT_VER})" "codeServerAction")" = "redo" ]; then
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
    # HTML và CSS được idempotent-check ĐỘC LẬP nhau bên trong Python (không gate
    # chung 1 marker ở bash) — máy đã patch HTML từ bản cũ (thiếu fix specificity
    # CSS) vẫn phải được vá lại phần CSS khi chạy setup.sh bản mới, dù HTML không
    # cần đổi gì thêm.
    grep -q "telecode-eye-toggle" "$html" 2>/dev/null && grep -q "telecode-anti-inspect" "$html" 2>/dev/null && grep -q "telecode-eye-toggle-css-v2" "$css" 2>/dev/null && return

    info "1b) Thêm/cập nhật icon hiện/ẩn mật khẩu vào trang đăng nhập code-server..."
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
    html = html.replace(old, new)
    print("html: da vao icon con mat lan dau")
elif "telecode-eye-toggle" in html:
    print("html: icon con mat da vao tu truoc, bo qua")
else:
    print("WARN: khong tim thay khoi HTML mat khau de patch icon con mat (co the code-server da doi cau truc)")

# Chan F12/chuot phai CHI o trang login (khong dung workbench.html) - F12 trong VS
# Code la phim tat that "Go to Definition", chan toan trang se pha tinh nang do khi
# dang code. Day chi la ngan can hinh thuc (JS khong chan duoc DevTools trinh duyet
# that) - tham khao cach lam trong yan2ai/public/chat.html.
if "telecode-anti-inspect" not in html:
    anti_inspect = '''    <script>
      // telecode-anti-inspect
      document.addEventListener('keydown', function (e) { if (e.key === 'F12') e.preventDefault(); });
      document.addEventListener('contextmenu', function (e) { e.preventDefault(); });
    </script>
  </body>'''
    if "  </body>" in html:
        html = html.replace("  </body>", anti_inspect, 1)
        print("html: da them chan F12/chuot phai")
    else:
        print("WARN: khong tim thay </body> de them chan F12/chuot phai")

with open(html_path, "w", encoding="utf-8") as f:
    f.write(html)

with open(css_path, "r", encoding="utf-8") as f:
    css = f.read()

if "telecode-eye-toggle-css-v2" in css:
    print("css: da vao (v2), bo qua")
else:
    # Input khong con la con truc tiep cua .field sau khi boc them .password-wrap
    # -> selector goc dung child combinator (>) khong khop nua, input mat toan bo
    # style (padding 16px, border, background...) va tro thanh textbox mac dinh.
    # Doi sang descendant combinator (space) de van khop bat ke do sau nesting.
    css = css.replace(
        ".login-form > .field > .password {",
        ".login-form > .field .password {",
    ).replace(
        ".login-form > .field > .password::placeholder {",
        ".login-form > .field .password::placeholder {",
    ).replace(
        ".login-form > .field > .password:focus {",
        ".login-form > .field .password:focus {",
    )

    css_addition = """

/* telecode-eye-toggle-css-v2 */
.password-wrap {
  position: relative;
  flex: 1;
  display: flex;
}
/* selector dai hon (4 class) de chac chan thang specificity so voi rule goc
   ".login-form > .field .password" (3 class) o tren, khong phu thuoc thu tu file */
.login-form > .field .password-wrap > .password {
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
    with open(css_path, "w", encoding="utf-8") as f:
        f.write(css + css_addition)
    print("css: da vao/cap nhat")
PYEOF
    if grep -q "telecode-eye-toggle" "$html" 2>/dev/null; then
        ok "Đã thêm icon hiện/ẩn mật khẩu vào trang login code-server"
    else
        warn "Không patch được trang login (có thể phiên bản code-server đã đổi cấu trúc HTML) — bỏ qua, không chặn setup"
    fi
}
patch_code_server_login
echo ""

# --- 1c. Đổi icon favicon/PWA của code-server sang icon riêng ---------------
# Chrome (mở qua --app=) lấy icon hiển thị trên taskbar từ favicon/pwa-icon của
# trang, không phải từ Icon= trong .desktop (cái đó chỉ ảnh hưởng icon launcher).
# Ghi đè thẳng file ảnh (không patch HTML) — không đụng đến workbench.html/login.html.
patch_code_server_favicon() {
    local root media
    root="$(find_code_server_root)" || return
    media="$root/src/browser/media"
    [ -d "$media" ] || return

    local SUDO=""
    [ -w "$media/favicon.ico" ] || SUDO="sudo"

    # So sánh nội dung trước, khớp rồi thì bỏ qua (không cần sudo mỗi lần chạy lại)
    if cmp -s "$DIR/assets/icon.ico" "$media/favicon.ico" 2>/dev/null; then
        return
    fi

    info "1c) Đổi icon favicon/PWA của code-server sang icon riêng..."
    $SUDO cp "$DIR/assets/icon.ico" "$media/favicon.ico"
    $SUDO cp "$DIR/assets/favicon.svg" "$media/favicon-dark-support.svg"
    $SUDO cp "$DIR/assets/pwa-icon-192.png" "$media/pwa-icon-192.png"
    $SUDO cp "$DIR/assets/pwa-icon-512.png" "$media/pwa-icon-512.png"
    [ -f "$media/pwa-icon-maskable-192.png" ] && $SUDO cp "$DIR/assets/pwa-icon-192.png" "$media/pwa-icon-maskable-192.png"
    [ -f "$media/pwa-icon-maskable-512.png" ] && $SUDO cp "$DIR/assets/pwa-icon-512.png" "$media/pwa-icon-maskable-512.png"
    ok "Đã đổi icon favicon/PWA — nếu Chrome vẫn hiện icon cũ trên taskbar, đó là do cache icon của Chrome cho origin này, thử mở lại cửa sổ app-mode hoặc xoá site data."
}
patch_code_server_favicon
echo ""

# --- 1d. Đảm bảo settings.json có baseline hợp lý ----------------------------
# security.workspace.trust.enabled=false: tắt hẳn Workspace Trust. Không phải
# workspace lạ cần "tin cậy" — đây là máy/project của chính người dùng. Trạng thái
# trust (và cả enable/disable extension theo workspace) trong code-server web
# workbench được lưu ở phía trình duyệt (IndexedDB theo origin), không phải file
# trên server — nếu không ổn định (đổi origin, xoá site data...) thì Workspace
# Trust bật lên sẽ khiến các extension như Claude Code bị vô hiệu hoá lại mỗi lần
# mở, phải bấm "Enable (Workspace)" thủ công liên tục. Chỉ THÊM key còn thiếu,
# không ghi đè giá trị người dùng đã tự chỉnh trong settings.json.
ensure_code_server_user_settings() {
    local settings="$HOME/.local/share/code-server/User/settings.json"
    mkdir -p "$(dirname "$settings")"
    [ -f "$settings" ] || echo '{}' > "$settings"
    python3 -c "
import json

path = '$settings'
with open(path) as f:
    settings = json.load(f)

defaults = {
    'security.workspace.trust.enabled': False,
    'workbench.startupEditor': 'none',
}
changed = False
for k, v in defaults.items():
    if k not in settings:
        settings[k] = v
        changed = True

if changed:
    with open(path, 'w') as f:
        json.dump(settings, f, indent='\t')
    print('settings.json: da them key con thieu')
else:
    print('settings.json: da du, bo qua')
"
}
ensure_code_server_user_settings
echo ""

# --- 2. Password code-server ---------------------------------------------
CS_CONFIG="$HOME/.config/code-server/config.yaml"
mkdir -p "$(dirname "$CS_CONFIG")"
CURRENT_PW=""
[ -f "$CS_CONFIG" ] && CURRENT_PW="$(grep '^password:' "$CS_CONFIG" | sed 's/^password: *//')"
CS_PASSWORD="$(ask_value "2) Mật khẩu code-server" "$CURRENT_PW" 1 "password")"
cat > "$CS_CONFIG" <<EOF
bind-addr: 127.0.0.1:8443
auth: password
password: $CS_PASSWORD
cert: false
EOF
ok "Đã ghi $CS_CONFIG"
echo ""

# --- 3. Chạy code-server nền ----------------------------------------------
# Chỉ mở đúng thư mục project (mặc định ~/Code), KHÔNG mở cả $HOME — mở cả $HOME
# nghĩa là ai vào được VS Code từ điện thoại cũng duyệt/sửa được mọi file khác
# trong home directory, không chỉ project đang cần làm việc.
CODE_SERVER_WORKSPACE="${CODE_SERVER_WORKSPACE:-$HOME/Code}"
if [ ! -d "$CODE_SERVER_WORKSPACE" ]; then
    warn "Không thấy thư mục $CODE_SERVER_WORKSPACE — dùng \$HOME thay thế. Đặt biến CODE_SERVER_WORKSPACE nếu muốn trỏ nơi khác."
    CODE_SERVER_WORKSPACE="$HOME"
fi

CS_PID="$RUN_DIR/code-server.pid"
if [ "$CS_PASSWORD" != "$CURRENT_PW" ] && is_alive "$CS_PID"; then
    # code-server chỉ đọc config.yaml lúc khởi động — đổi mật khẩu mà không restart
    # thì tiến trình cũ vẫn dùng mật khẩu cũ trong bộ nhớ, gõ mật khẩu mới sẽ luôn sai.
    warn "Mật khẩu vừa đổi — bắt buộc khởi động lại code-server để áp dụng."
    stop_pid "$CS_PID"
elif is_alive "$CS_PID"; then
    if [ "$(ask_choice "3) code-server: đang chạy (PID $(cat "$CS_PID"))" "codeServerRunAction")" = "redo" ]; then
        stop_pid "$CS_PID"
    fi
fi
if ! is_alive "$CS_PID"; then
    nohup code-server --bind-addr 127.0.0.1:8443 "$CODE_SERVER_WORKSPACE" > "$LOG_DIR/code-server.log" 2>&1 &
    echo $! > "$CS_PID"
    sleep 2
    ok "code-server đang chạy tại http://localhost:8443, thư mục: $CODE_SERVER_WORKSPACE (PID $(cat "$CS_PID"))"
fi
echo ""

# --- 3b. Tạo shortcut Desktop "Telecode" mở code-server trên máy tính --------
# Dùng luôn trên máy tính (không qua Telegram/tunnel) = mở localhost:8443 thẳng,
# nhanh hơn nhiều vì không qua Cloudflare. Idempotent: ghi đè mỗi lần chạy để
# luôn trỏ đúng cấu hình hiện tại (không cần xoá tay trước khi tạo lại).
# Xoá luôn shortcut tên cũ (từ bản trước khi đổi tên thành "Telecode") nếu còn sót.
rm -f "$HOME/Desktop/code-server.desktop" "$HOME/Desktop/VS Code (code-server).command"
#
# Mở bằng trình duyệt Chrome/Edge/Chromium ở chế độ --app= (ẩn thanh địa chỉ,
# giống app desktop thật) — tham khảo openAppModeBrowser() trong yan2ai/tray.js.
# Không tìm thấy trình duyệt nào trong nhóm Chromium -> fallback mở tab thường.
resolve_app_mode_browser_bin() {
    local candidates=()
    if [ "$OS" = "mac" ]; then
        candidates=(
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
            "/Applications/Chromium.app/Contents/MacOS/Chromium"
        )
    else
        candidates=(google-chrome google-chrome-stable chromium chromium-browser microsoft-edge microsoft-edge-stable)
    fi
    for c in "${candidates[@]}"; do
        if [ "${c:0:1}" = "/" ]; then
            [ -x "$c" ] && { echo "$c"; return 0; }
        else
            command -v "$c" &>/dev/null && { command -v "$c"; return 0; }
        fi
    done
    return 1
}

if [ -d "$HOME/Desktop" ]; then
    ICON_FILE="$DIR/assets/icon.png"
    APP_BROWSER="$(resolve_app_mode_browser_bin || true)"
    if [ "$OS" = "mac" ]; then
        SHORTCUT="$HOME/Desktop/Telecode.command"
        if [ -n "$APP_BROWSER" ]; then
            cat > "$SHORTCUT" <<EOF
#!/bin/bash
"$APP_BROWSER" --app=http://localhost:8443
EOF
        else
            cat > "$SHORTCUT" <<EOF
#!/bin/bash
open http://localhost:8443
EOF
        fi
        chmod +x "$SHORTCUT"
    else
        SHORTCUT="$HOME/Desktop/telecode.desktop"
        if [ -n "$APP_BROWSER" ]; then
            EXEC_LINE="$APP_BROWSER --app=http://localhost:8443"
        else
            EXEC_LINE="xdg-open http://localhost:8443"
        fi
        cat > "$SHORTCUT" <<EOF
[Desktop Entry]
Type=Application
Name=Telecode
Comment=Telecode by Yan
Exec=$EXEC_LINE
Icon=${ICON_FILE:-code}
Terminal=false
Categories=Development;
EOF
        chmod +x "$SHORTCUT"
        command -v gio >/dev/null 2>&1 && gio set "$SHORTCUT" metadata::trusted true 2>/dev/null || true
    fi
    ok "Đã tạo shortcut Desktop: $SHORTCUT"
else
    warn "Không thấy thư mục $HOME/Desktop — bỏ qua tạo shortcut (bạn vẫn mở tay http://localhost:8443)."
fi
echo ""

# --- 4. cloudflared --------------------------------------------------------
if command -v cloudflared &>/dev/null; then
    CURRENT_VER="$(cloudflared --version 2>/dev/null | head -n1)"
    if [ "$(ask_choice "4) cloudflared: đã cài (${CURRENT_VER})" "cloudflaredAction")" = "redo" ]; then
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
    if [ "$(ask_choice "5) Tunnel code-server: đang chạy ($(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$T1_LOG" | head -n1))" "tunnelAction")" = "redo" ]; then
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

# --- 6. Telegram Bot Token ---------------------------------------------------
# Nút bot mở THẲNG VSCODE_PUBLIC_URL (không qua iframe mini_app.html): code-server
# đặt cookie SameSite=Lax, load trong iframe khác domain sẽ bị nhiều WebView (đặc
# biệt iOS WKWebView của Telegram) chặn làm cookie bên thứ 3 -> đăng nhập đúng mật
# khẩu vẫn quay lại y hệt màn login. mini_app.html vẫn còn trong repo nhưng không
# dùng trong luồng mặc định nữa.
CONFIG_FILE="$DIR/config.yaml"
[ -f "$CONFIG_FILE" ] || cp "$DIR/config.example.yaml" "$CONFIG_FILE"
CURRENT_TOKEN="$(grep '^TELEGRAM_BOT_TOKEN:' "$CONFIG_FILE" | sed -E 's/^TELEGRAM_BOT_TOKEN: *"?([^"]*)"?/\1/')"
[ "$CURRENT_TOKEN" = "YOUR_BOT_TOKEN_HERE" ] && CURRENT_TOKEN=""
echo "6) Token bot Telegram — lấy từ @BotFather (gửi /newbot trên điện thoại nếu chưa có)."
BOT_TOKEN="$(ask_value "   Token" "$CURRENT_TOKEN" 1 "token")"
echo ""

# --- 7. Ghi config.yaml -------------------------------------------------------
cat > "$CONFIG_FILE" <<EOF
TELEGRAM_BOT_TOKEN: "$BOT_TOKEN"
VSCODE_PORT: 8443
VSCODE_PASSWORD: "$CS_PASSWORD"
VSCODE_PUBLIC_URL: "$VSCODE_PUBLIC_URL"
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

# --- 8. Python venv + dependencies -------------------------------------------
if [ ! -d "$DIR/venv" ]; then
    info "8) Tạo virtualenv..."
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

# --- 9. Chạy bot ----------------------------------------------------------------
BOT_PID="$RUN_DIR/bot.pid"
if is_alive "$BOT_PID"; then
    if [ "$(ask_choice "9) Bot: đang chạy (PID $(cat "$BOT_PID"))" "botAction")" = "redo" ]; then
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

# --- 10. Tự đóng terminal (chỉ khi cài qua wizard web) -----------------------
# $PPID lúc mở wizard đã được lưu vào wizard-answers.json — cài xong hết thì kill
# PID đó để đóng shell/terminal, không cần user tự đóng. Đặt SAU CÙNG (mọi bước
# cài đặt/khởi động đã xong) để không có gì phụ thuộc chạy tiếp sau khi terminal mất.
if [ "${TELECODE_APPLYING:-0}" = "1" ] && [ -f "$ANSWERS_FILE" ]; then
    CALLER_PID="$(answers_get "_callerPid")"
    if [ -n "$CALLER_PID" ] && kill -0 "$CALLER_PID" 2>/dev/null; then
        kill "$CALLER_PID" 2>/dev/null
    fi
fi

echo "======================================"
ok "Setup xong!"
echo "======================================"
echo ""
echo "📱 Trên điện thoại: mở Telegram → tìm bot của bạn → bấm nút '🔧 VS Code' cạnh khung nhập tin nhắn"
echo "🔗 VS Code URL: $VSCODE_PUBLIC_URL"
echo "📄 Log: $LOG_DIR/"
echo ""
echo "Chạy lại 'bash setup.sh' bất cứ lúc nào — script sẽ hỏi giữ nguyên hay khởi động lại từng phần."
