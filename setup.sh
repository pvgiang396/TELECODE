#!/bin/bash
#
# Telecode - Setup tổng hợp (idempotent, chạy lại được nhiều lần)
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
# TELECODE_RUN_DIR — override khi setup.sh được spawn từ wizard.py chạy trong Tauri
# (RUN_DIR thật lúc đó là app_data_dir()/run, không nằm cạnh chính setup.sh như CLI gốc).
RUN_DIR="${TELECODE_RUN_DIR:-$DIR/.run}"
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

# find_code_server_root: dò thư mục cài code-server (chứa src/browser/pages/login.html)
# — định nghĩa SỚM (trước cả phần wizard/HAS_GUI ở dưới) vì bước "xin sudo 1 lần" cần
# gọi hàm này trước khi script chạy nền qua nohup. Dùng lại y hệt ở patch_code_server_assets().
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

is_alive() { # is_alive <pidfile>
    [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null
}

stop_pid() { # stop_pid <pidfile>
    if is_alive "$1"; then kill "$(cat "$1")" 2>/dev/null; sleep 1; fi
    rm -f "$1"
}

OS="linux"
[ "$(uname -s)" = "Darwin" ] && OS="mac"

# Dùng chung cho cả code-server (bước 3) và bot (bước 9) — Linux có systemd --user
# thật sự dùng được thì ưu tiên (Restart=always tự hồi sinh khi crash vì bất kỳ lý
# do gì); macOS/máy không có thì các bước liên quan tự fallback nohup.
USE_SYSTEMD=0
if [ "$OS" = "linux" ] && command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    USE_SYSTEMD=1
fi

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

    # --- Cấp quyền ghi 1 LẦN cho code-server bằng pkexec (KHÔNG dùng sudo) -------
    # Từ dòng "nohup bash "$0" ... &" bên dưới trở đi, script chạy NỀN (detached
    # khỏi terminal) — mọi lệnh `sudo` phía sau (kể cả patch favicon/login qua
    # patch_code_server_assets()) sẽ fail ÂM THẦM. Ban đầu tưởng chỉ cần xin `sudo -v`
    # NGAY TẠI ĐÂY (còn coi là "foreground") là đủ, nhưng xác minh thật (log
    # setup-apply.log của 1 lần chạy quickstart qua `curl | bash`) cho thấy NGAY CẢ Ở
    # ĐÂY cũng không đọc được mật khẩu qua TTY (`sudo: unable to read password:
    # Input/output error`) — luồng `curl | bash` không đảm bảo có TTY thật cho sudo
    # dùng, kể cả trước khi chạy nền. Vì nhánh này CHỈ chạy khi có GUI (HAS_GUI=1 —
    # yêu cầu bắt buộc để mở được wizard.py), DISPLAY chắc chắn có sẵn -> dùng
    # `pkexec` (hộp thoại polkit đồ hoạ, không cần TTY, đọc thẳng DISPLAY) thay cho
    # `sudo` cho ĐÚNG 1 việc: chown thư mục code-server sang user hiện tại 1 lần duy
    # nhất — sau đó patch_code_server_assets() tự phát hiện đã ghi được
    # ("[ -w "$html" ]") nên không cần sudo/pkexec nữa ở mọi lần chạy sau, kể cả chạy
    # nền. Không dùng pkexec cho `tailscale up/serve/funnel` (bước 4/5) vì đó là lệnh
    # CẦN CHẠY LẶP LẠI với quyền root ở mỗi lần, không phải việc 1 lần như chown —
    # vẫn còn hạn chế đã biết (có thể fail âm thầm khi qua wizard), chưa xử lý.
    CS_ROOT_PRECHOWN="$(find_code_server_root 2>/dev/null || true)"
    if [ -n "$CS_ROOT_PRECHOWN" ] && [ ! -w "$CS_ROOT_PRECHOWN/src/browser/pages/login.html" ]; then
        if command -v pkexec &>/dev/null; then
            info "Cấp quyền ghi 1 lần cho thư mục code-server (xác nhận qua hộp thoại)..."
            pkexec chown -R "$(id -u):$(id -g)" "$CS_ROOT_PRECHOWN/src/browser/pages" "$CS_ROOT_PRECHOWN/src/browser/media" \
                || warn "Không chown được thư mục code-server (pkexec) — icon/favicon riêng có thể không áp dụng được ở lần chạy nền này."
        else
            info "Cấp quyền ghi 1 lần cho thư mục code-server (cần mật khẩu sudo)..."
            sudo chown -R "$(id -u):$(id -g)" "$CS_ROOT_PRECHOWN/src/browser/pages" "$CS_ROOT_PRECHOWN/src/browser/media" \
                || warn "Không chown được thư mục code-server — icon/favicon riêng có thể không áp dụng được ở lần chạy nền này."
        fi
    fi
    # code-server CHƯA cài (lần đầu) -> CS_ROOT_PRECHOWN rỗng, không chown được gì ở
    # đây; patch_code_server_assets() ở lần chạy nền đầu tiên đó vẫn có thể fail sudo
    # âm thầm — chạy lại 'bash setup.sh' một lần nữa (khi code-server đã có) sẽ tự fix.

    TELECODE_APPLYING=1 nohup bash "$0" > "$LOG_DIR/setup-apply.log" 2>&1 &
    disown
    echo "📄 Theo dõi tiến trình (không bắt buộc): tail -f $LOG_DIR/setup-apply.log"
    exit 0
fi

echo "======================================"
echo "🚀 Telecode - Setup"
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

# --- 1b/1c. Patch code-server: icon hiện/ẩn mật khẩu + favicon/PWA riêng ----
# code-server không có tuỳ chọn chính thức để tuỳ biến trang login/favicon -> vá
# thẳng file đóng gói sẵn (login.js đọc lại HTML/CSS ở MỖI request, không cache,
# nên áp dụng ngay, không cần restart). Nhược điểm: bị ghi đè mỗi khi code-server
# cài lại/nâng cấp -> gọi hàm này lại mỗi lần chạy setup.sh (idempotent qua marker).
#
# GỘP CHUNG login.html/css + favicon vào 1 LỆNH SUDO DUY NHẤT: chạy nền qua nohup
# (không có TTY thật) khiến sudo không cache được xác thực giữa các lần gọi riêng
# lẻ — tách 2 hàm/2 lệnh sudo sẽ hỏi lại mật khẩu lần nữa (đã gặp thật: 2 lần hỏi
# dù mỗi hàm tự nó chỉ 1 lệnh). Gộp thành 1 lệnh = chỉ hỏi sudo đúng 1 lần.
# (find_code_server_root định nghĩa sớm hơn ở đầu file — xem "Xin sudo 1 lần" phía
# trên phần wizard, cần hàm này TRƯỚC khi chạy nền.)

patch_code_server_assets() {
    local root html css media
    root="$(find_code_server_root)" || { warn "Không tìm thấy thư mục cài code-server để patch icon/favicon, bỏ qua."; return; }
    html="$root/src/browser/pages/login.html"
    css="$root/src/browser/pages/login.css"
    media="$root/src/browser/media"

    # 3 điều kiện đều đã đạt (idempotent riêng từng phần) -> không cần sudo gì cả.
    local login_ok=0 css_ok=0 favicon_ok=0
    grep -q "telecode-eye-toggle" "$html" 2>/dev/null && grep -q "telecode-anti-inspect" "$html" 2>/dev/null && login_ok=1
    grep -q "telecode-eye-toggle-css-v2" "$css" 2>/dev/null && grep -q "telecode-dark-theme-css-v1" "$css" 2>/dev/null && css_ok=1
    cmp -s "$DIR/assets/icon.ico" "$media/favicon.ico" 2>/dev/null && favicon_ok=1
    if [ "$login_ok" = 1 ] && [ "$css_ok" = 1 ] && [ "$favicon_ok" = 1 ]; then
        return
    fi

    info "1b/1c) Cập nhật icon con mắt/chặn F12/favicon của code-server..."
    local SUDO=""
    [ -w "$html" ] || SUDO="sudo"
    $SUDO python3 - "$html" "$css" "$media" "$DIR/assets" <<'PYEOF'
import shutil
import sys

html_path, css_path, media_dir, assets_dir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

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

css_changed = False

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
    css = css + css_addition
    css_changed = True
    print("css: da vao/cap nhat")

# Trang login goc cua code-server mac dinh nen trang/sang - khac han theme toi cua
# wizard.html (#1e1e1e/#252526/#3c3c3c/#e5e5e5/#3f83f8). Khong biet chac toan bo
# selector noi bo code-server (de vo khi code-server update) nen chi ep bang !important
# o muc html/body + cac phan tu .login-form/.field/input da biet chac ton tai (dung
# chung selector voi khoi eye-toggle o tren).
if "telecode-dark-theme-css-v1" in css:
    print("css: dark theme da vao, bo qua")
else:
    dark_css = """

/* telecode-dark-theme-css-v1 */
:root { color-scheme: dark; }
html, body {
  background: #1e1e1e !important;
  color: #e5e5e5 !important;
}
.login-form, .card, .field {
  background: #252526 !important;
  color: #e5e5e5 !important;
  border-color: #3c3c3c !important;
}
.login-form > .field .password,
.login-form input[type="text"],
.login-form input[type="password"] {
  background: #1e1e1e !important;
  color: #e5e5e5 !important;
  border-color: #4b5563 !important;
}
.login-form .submit,
.login-form .-button {
  background: #3f83f8 !important;
  color: #fff !important;
}
.login-form a {
  color: #3f83f8 !important;
}
"""
    css = css + dark_css
    css_changed = True
    print("css: dark theme da vao/cap nhat")

if css_changed:
    with open(css_path, "w", encoding="utf-8") as f:
        f.write(css)

# --- Favicon/PWA icon riêng: Chrome (--app=) lấy icon taskbar từ đây, không
# phải Icon= trong .desktop (cái đó chỉ ảnh hưởng icon launcher trước khi chạy).
icon_ico = f"{assets_dir}/icon.ico"
if not shutil.os.path.exists(media_dir):
    print("WARN: khong tim thay thu muc media de doi favicon")
else:
    favicon_ico = f"{media_dir}/favicon.ico"
    needs_favicon = True
    try:
        with open(icon_ico, "rb") as a, open(favicon_ico, "rb") as b:
            needs_favicon = a.read() != b.read()
    except FileNotFoundError:
        needs_favicon = True
    if needs_favicon:
        shutil.copy(icon_ico, favicon_ico)
        shutil.copy(f"{assets_dir}/favicon.svg", f"{media_dir}/favicon-dark-support.svg")
        shutil.copy(f"{assets_dir}/pwa-icon-192.png", f"{media_dir}/pwa-icon-192.png")
        shutil.copy(f"{assets_dir}/pwa-icon-512.png", f"{media_dir}/pwa-icon-512.png")
        for name, src in (("pwa-icon-maskable-192.png", "pwa-icon-192.png"), ("pwa-icon-maskable-512.png", "pwa-icon-512.png")):
            dst = f"{media_dir}/{name}"
            if shutil.os.path.exists(dst):
                shutil.copy(f"{assets_dir}/{src}", dst)
        print("favicon: da doi")
    else:
        print("favicon: da khop, bo qua")
PYEOF
    if grep -q "telecode-eye-toggle" "$html" 2>/dev/null; then
        ok "Đã cập nhật icon con mắt/chặn F12/favicon của code-server"
    else
        warn "Không patch được trang login (có thể phiên bản code-server đã đổi cấu trúc HTML) — bỏ qua, không chặn setup"
    fi
}
patch_code_server_assets
echo ""

# --- 1cb. Tạo shortcut Desktop "Telecode" mở code-server trên máy tính -------
# Đặt NGAY SAU bước patch favicon/icon (không phải ở "3b" như trước) — bug thật đã
# gặp: 1 lỗi ở bước sau (vd 1e cài Copilot crash "unbound variable" dưới `set -u`,
# không có `set -e` nên các bước TRƯỚC ĐÓ đã chạy vẫn giữ nguyên nhưng các bước SAU
# ĐIỂM CRASH không bao giờ chạy tới) từng khiến shortcut/icon KHÔNG BAO GIỜ được tạo
# lại dù setup.sh chạy xong tới đây. Đặt các bước liên quan tới icon/shortcut CÀNG
# SỚM CÀNG TỐT để không phụ thuộc vào các bước ít liên quan (Copilot/Tailscale) chạy
# trót lọt. Dùng luôn trên máy tính (không qua tunnel) = mở localhost:8443 thẳng,
# nhanh hơn nhiều vì không qua Cloudflare/Funnel. Idempotent: ghi đè
# mỗi lần chạy để luôn trỏ đúng cấu hình hiện tại (không cần xoá tay trước khi tạo lại).
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

chmod +x "$DIR/scripts/launch.sh" 2>/dev/null || true
if [ -d "$HOME/Desktop" ]; then
    ICON_FILE="$DIR/assets/icon.png"
    APP_BROWSER="$(resolve_app_mode_browser_bin || true)"
    # Shortcut gọi scripts/launch.sh thay vì mở trình duyệt thẳng — script đó tự
    # kiểm tra + khởi động lại code-server/bot/Tailscale nếu đang tắt (bug thật đã
    # gặp: Tailscale tự đăng xuất sau khi máy sleep, mini app điện thoại không vào
    # được dù mở trên máy tính vẫn OK) trước khi mở app, không cần user tự debug.
    if [ "$OS" = "mac" ]; then
        SHORTCUT="$HOME/Desktop/Telecode.command"
        cat > "$SHORTCUT" <<EOF
#!/bin/bash
bash "$DIR/scripts/launch.sh"
EOF
        chmod +x "$SHORTCUT"
    else
        SHORTCUT="$HOME/Desktop/telecode.desktop"
        if [ -n "$APP_BROWSER" ]; then
            # --class=Telecode: Chrome --app= mac dinh dat WM_CLASS="Google-chrome"
            # (giong het cua so Chrome that) -> Cinnamon/GNOME nhan dien trung voi
            # google-chrome.desktop (StartupWMClass=Google-chrome) da cai san, taskbar
            # luon hien icon Chrome that, bo qua ca favicon lan Icon= o duoi (bug that
            # da xac minh qua xprop). Doi WM_CLASS rieng + StartupWMClass= khop ben duoi
            # de desktop environment dung dung Icon= cua file nay. launch.sh (buoc 3
            # trong chinh no) tu truyen --class=Telecode khi mo trinh duyet, giu dung
            # WM_CLASS voi StartupWMClass= khai bao o day.
            STARTUP_WM_CLASS_LINE="StartupWMClass=Telecode"
        else
            # Khong tim thay Chrome/Edge/Chromium -> launch.sh tu fallback xdg-open mo
            # THANG trinh duyet mac dinh (vd Firefox), khong phai app-mode. KHONG duoc
            # dat StartupWMClass=Telecode o day (bug that da gap): cua so that mo ra
            # mang WM_CLASS cua chinh trinh duyet do, khong khop "Telecode" -> DE
            # (Cinnamon/GNOME) khong nhan dien duoc cua so that nen giu nguyen icon cua
            # launcher tren taskbar thay vi tra ve icon that cua trinh duyet mac dinh.
            STARTUP_WM_CLASS_LINE=""
        fi
        cat > "$SHORTCUT" <<EOF
[Desktop Entry]
Type=Application
Name=Telecode
Comment=Telecode by Yan
Exec=bash "$DIR/scripts/launch.sh"
Icon=${ICON_FILE:-code}
${STARTUP_WM_CLASS_LINE}
Terminal=false
Categories=Development;
EOF
        chmod +x "$SHORTCUT"
        command -v gio >/dev/null 2>&1 && gio set "$SHORTCUT" metadata::trusted true 2>/dev/null || true
    fi
    ok "Đã tạo shortcut Desktop: $SHORTCUT (tự kiểm tra/khởi động lại code-server, bot, Tailscale trước khi mở)"
else
    warn "Không thấy thư mục $HOME/Desktop — bỏ qua tạo shortcut. Chạy tay: bash $DIR/scripts/launch.sh"
fi
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

# --- 1e. GitHub Copilot + Copilot Chat --------------------------------------
# code-server dùng Open VSX làm marketplace mặc định, nhưng GitHub chỉ publish
# Copilot/Copilot Chat lên Visual Studio Marketplace chính thức (không có trên
# Open VSX) -> không cài được qua UI Extensions bình thường. Tải thẳng .vsix từ
# API Marketplace rồi sideload bằng `code-server --install-extension`. Cài luôn
# mặc định (không hỏi) cho mọi máy, kể cả người dùng chưa có quota Copilot —
# đăng nhập là bước riêng của người dùng sau này (Command Palette > "GitHub
# Copilot: Sign In"), không đăng nhập được thì extension chỉ nằm im, không lỗi.
install_vsix_extension() { # install_vsix_extension <publisher> <name>
    # "${1:-}"/"${2:-}" (không phải "$1"/"$2" trần) — bug thật đã gặp: 1 lần chạy
    # nền qua wizard bị "line N: name: unbound variable" ngay khi vào hàm này (dưới
    # `set -uo pipefail`, không có `set -e`) làm CRASH TOÀN BỘ setup.sh giữa chừng —
    # mọi bước sau (2→9, kể cả tạo lại shortcut Desktop ở 3b) không bao giờ chạy tới,
    # dù các call site đều truyền đủ 2 tham số (chưa xác định được vì sao $2 rỗng lần
    # đó). Phòng vệ ở đây: nếu thiếu tham số thì cảnh báo + return, KHÔNG để cả script
    # dừng lại vì 1 hàm phụ (cài Copilot) không quan trọng bằng các bước còn lại.
    local publisher="${1:-}" name="${2:-}" vsix
    if [ -z "$publisher" ] || [ -z "$name" ]; then
        warn "install_vsix_extension gọi thiếu tham số (publisher='$publisher' name='$name') — bỏ qua."
        return 1
    fi
    vsix="$RUN_DIR/${name}.vsix"
    # --compressed: Marketplace CDN trả file .vsix đã gzip sẵn (content-encoding:
    # gzip) -> thiếu cờ này curl lưu thẳng byte gzip thô xuống đĩa (không phải
    # zip hợp lệ), `code-server --install-extension` cài lỗi âm thầm nếu không
    # kiểm tra exit code (bug thật đã gặp: "ok" vẫn hiện dù cài thất bại).
    if ! curl -fsSL --compressed -o "$vsix" \
        "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/${publisher}/vsextensions/${name}/latest/vspackage"; then
        warn "   Tải ${publisher}.${name} thất bại (kiểm tra mạng) — bỏ qua, chạy lại setup.sh sau để thử lại."
        return 1
    fi
    local install_out
    if install_out="$(code-server --install-extension "$vsix" --force 2>&1)"; then
        ok "   Đã cài ${publisher}.${name}"
    elif echo "$install_out" | grep -qi "is a built-in extension.*cannot be downgraded"; then
        # code-server bản mới (dựa VS Code >=1.99) bundle sẵn Copilot Chat làm
        # built-in extension -> bản Marketplace tải về thường CŨ hơn, bị từ chối
        # "downgrade". Đây KHÔNG phải lỗi: nghĩa là extension đã có sẵn, mới hơn
        # bản ta định cài -> coi là thành công, chỉ cần đăng nhập (Command
        # Palette > "GitHub Copilot: Sign In"), không cần cài gì thêm.
        ok "   ${publisher}.${name} đã có sẵn built-in trong code-server (bản mới hơn bản Marketplace) — bỏ qua cài, chỉ cần đăng nhập."
    else
        warn "   Cài ${publisher}.${name} thất bại:"
        echo "$install_out" | sed 's/^/     /'
        warn "   → chạy lại setup.sh sau để thử lại."
    fi
    rm -f "$vsix"
}

INSTALLED_EXT="$(code-server --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]')"
if echo "$INSTALLED_EXT" | grep -q '^github\.copilot$' && echo "$INSTALLED_EXT" | grep -q '^github\.copilot-chat$'; then
    if [ "$(ask_choice "1e) GitHub Copilot + Copilot Chat: đã cài" "copilotExtAction")" = "redo" ]; then
        install_vsix_extension "GitHub" "copilot"
        install_vsix_extension "GitHub" "copilot-chat"
    fi
else
    info "1e) Đang cài GitHub Copilot + Copilot Chat..."
    echo "$INSTALLED_EXT" | grep -q '^github\.copilot$' || install_vsix_extension "GitHub" "copilot"
    echo "$INSTALLED_EXT" | grep -q '^github\.copilot-chat$' || install_vsix_extension "GitHub" "copilot-chat"
    info "   Đăng nhập sau tại: Command Palette > \"GitHub Copilot: Sign In\" (dùng account có quota công ty cấp)."
fi
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

# --- 2b. Điền sẵn password vào ô đăng nhập code-server ------------------------
# Chạy SAU khi biết CS_PASSWORD (mục 2) — trang login đã patch icon con mắt/dark
# theme ở bước 1b/1c (patch_code_server_assets, chạy TRƯỚC mục 2 nên chưa biết
# password) — patch thêm bước này để bản Tauri (main.rs) có thể bỏ qua modal cài
# đặt khi đã cấu hình xong (ý 1, srs/LoiTelecode/v3.md): trang chính hiện thẳng
# màn login code-server, ô password đã điền sẵn, user chỉ cần bấm nút đăng nhập.
# Idempotent THEO GIÁ TRỊ (không chỉ theo marker tồn tại như patch_code_server_assets)
# vì password có thể đổi mỗi lần chạy setup.sh — marker nhúng kèm giá trị để tự phát
# hiện cần ghi đè lại khi user đổi password.
patch_code_server_login_password() {
    local root html
    root="$(find_code_server_root)" || return
    html="$root/src/browser/pages/login.html"
    [ -f "$html" ] || return

    grep -qF "telecode-prefill-password:$CS_PASSWORD\"" "$html" 2>/dev/null && return

    local SUDO=""
    [ -w "$html" ] || SUDO="sudo"
    $SUDO python3 - "$html" "$CS_PASSWORD" <<'PYEOF'
import re
import sys

html_path, password = sys.argv[1], sys.argv[2]
with open(html_path, "r", encoding="utf-8") as f:
    html = f.read()

# Xoá khối cũ (nếu có, giá trị password trước đó) trước khi ghi khối mới.
marker_re = re.compile(
    r"\n?    <script>\n      // telecode-prefill-password:.*?\n    </script>\n",
    re.S,
)
html = marker_re.sub("", html)

escaped = password.replace("\\", "\\\\").replace('"', '\\"')
script = (
    "\n    <script>\n"
    "      // telecode-prefill-password:" + password + "\n"
    "      document.addEventListener('DOMContentLoaded', function () {\n"
    "        var p = document.querySelector('input[name=\"password\"]');\n"
    "        if (p) p.value = \"" + escaped + "\";\n"
    "      });\n"
    "    </script>\n"
)
if "  </body>" in html:
    html = html.replace("  </body>", script + "  </body>", 1)
    print("html: da dien san password")
else:
    print("WARN: khong tim thay </body> de dien san password")

with open(html_path, "w", encoding="utf-8") as f:
    f.write(html)
PYEOF
}
patch_code_server_login_password
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

# Ưu tiên systemd --user (giống bot ở bước 9) thay vì nohup trần — bug thật đã gặp:
# gói .deb code-server cài kèm sẵn 1 unit systemd --user riêng (/usr/lib/systemd/
# user/code-server.service, Restart=always, WantedBy=default.target) tự bật sẵn ở
# nhiều máy, TRANH NHAU quản lý cùng 1 code-server với tiến trình nohup cũ của
# setup.sh (cả 2 đọc chung config.yaml nên khó nhận ra là 2 cơ chế khác nhau) — mỗi
# lần máy reboot/logout/crash, systemd tự spin lên 1 process HOÀN TOÀN MỚI, làm mất
# sạch session GitHub Copilot/Gemini đã đăng nhập (đã xác nhận package.json code-
# server KHÔNG có dependency "keytar" — SecretStorage chỉ giữ trong bộ nhớ tiến
# trình, không có backend keyring/libsecret nào cứu được dù gnome-keyring-daemon có
# đang chạy sẵn trên máy hay không — xem thêm telecode/CLAUDE.md). Ghi unit của ta
# vào $HOME/.config/systemd/user/code-server.service — theo thứ tự tìm unit của
# systemd, file này ĐÈ hẳn lên bản /usr/lib/systemd/user cùng tên, không cần mask/
# disable riêng bản vendor.
CS_PID="$RUN_DIR/code-server.pid"
CS_SERVICE="code-server"
CS_UNIT_FILE="$HOME/.config/systemd/user/${CS_SERVICE}.service"
# GH_TOKEN cho "Copilot CLI" (agent Gemini spawn ra tiến trình copilot con — xem
# Bước 6c) — tách riêng khỏi unit qua EnvironmentFile= để đổi PAT không cần viết
# lại unit, chỉ cần restart. Không tồn tại thì code-server vẫn chạy bình thường
# (dấu "-" trước đường dẫn trong EnvironmentFile=).
CS_ENV_FILE="$RUN_DIR/code-server.env"

is_code_server_alive() {
    if [ "$USE_SYSTEMD" = "1" ]; then
        systemctl --user is-active --quiet "$CS_SERVICE"
    else
        is_alive "$CS_PID"
    fi
}

start_code_server() {
    if [ "$USE_SYSTEMD" = "1" ]; then
        mkdir -p "$(dirname "$CS_UNIT_FILE")"
        cat > "$CS_UNIT_FILE" <<EOF
[Unit]
Description=code-server (telecode)
After=network.target

[Service]
Type=simple
EnvironmentFile=-$CS_ENV_FILE
ExecStart=$(command -v code-server) --bind-addr 127.0.0.1:8443 $CODE_SERVER_WORKSPACE
Restart=always
RestartSec=3
StandardOutput=append:$LOG_DIR/code-server.log
StandardError=append:$LOG_DIR/code-server.log

[Install]
WantedBy=default.target
EOF
        systemctl --user daemon-reload
        systemctl --user enable --now "$CS_SERVICE" >/dev/null 2>&1
        sleep 2
        if ! is_code_server_alive; then
            err "code-server (systemd) khởi động thất bại — xem: journalctl --user -u $CS_SERVICE -n 50 --no-pager"
            exit 1
        fi
        # Ghi PID thật để tương thích ngược với wizard.py cũ/hiển thị — lỗi thời
        # ngay sau lần Restart=always kế tiếp, không dùng để quyết định alive.
        systemctl --user show "$CS_SERVICE" -p MainPID --value > "$CS_PID"
    else
        ( set -a; [ -f "$CS_ENV_FILE" ] && . "$CS_ENV_FILE"; set +a
          nohup code-server --bind-addr 127.0.0.1:8443 "$CODE_SERVER_WORKSPACE" > "$LOG_DIR/code-server.log" 2>&1 & echo $! > "$CS_PID" )
        sleep 2
    fi
}

stop_code_server() {
    if [ "$USE_SYSTEMD" = "1" ]; then systemctl --user stop "$CS_SERVICE"; else stop_pid "$CS_PID"; fi
}

if [ "$CS_PASSWORD" != "$CURRENT_PW" ] && is_code_server_alive; then
    # code-server chỉ đọc config.yaml lúc khởi động — đổi mật khẩu mà không restart
    # thì tiến trình cũ vẫn dùng mật khẩu cũ trong bộ nhớ, gõ mật khẩu mới sẽ luôn sai.
    warn "Mật khẩu vừa đổi — bắt buộc khởi động lại code-server để áp dụng."
    stop_code_server
elif is_code_server_alive; then
    if [ "$(ask_choice "3) code-server: đang chạy" "codeServerRunAction")" = "redo" ]; then
        stop_code_server
    fi
fi
if ! is_code_server_alive; then
    start_code_server
    ok "code-server đang chạy tại http://localhost:8443, thư mục: $CODE_SERVER_WORKSPACE"
fi
if [ "$USE_SYSTEMD" = "1" ]; then
    ok "code-server chạy qua systemd --user (tự restart nếu crash) — service: $CS_SERVICE"
    # Tự bật linger để code-server chạy được ngay từ lúc máy khởi động, không cần
    # đăng nhập trước — nhiều distro cho tự bật cho chính mình qua polkit
    # (auth_self_keep) không cần root (đã xác nhận trên máy dev); nếu không,
    # fallback pkexec/sudo (cùng pattern "tailscale up" ở bước 4b). (Trước đây đặt
    # ở bước "Chạy bot" — chuyển về đây sau khi bỏ bot Telegram, vì linger áp dụng
    # cho TOÀN BỘ service systemd --user của user, không riêng 1 service nào.)
    if ! loginctl show-user "$(id -un)" 2>/dev/null | grep -q "Linger=yes"; then
        if loginctl enable-linger "$(id -un)" 2>/dev/null; then
            ok "Đã bật linger — code-server tự chạy ngay từ lúc khởi động máy, không cần đăng nhập."
        elif command -v pkexec &>/dev/null && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && pkexec loginctl enable-linger "$(id -un)" 2>/dev/null; then
            ok "Đã bật linger (qua pkexec) — code-server tự chạy ngay từ lúc khởi động máy, không cần đăng nhập."
        elif sudo loginctl enable-linger "$(id -un)" 2>/dev/null; then
            ok "Đã bật linger (qua sudo) — code-server tự chạy ngay từ lúc khởi động máy, không cần đăng nhập."
        else
            warn "Không tự bật được linger — chạy tay 1 lần: loginctl enable-linger $(id -un) (giữ code-server chạy nền kể cả khi chưa đăng nhập)."
        fi
    fi
else
    warn "code-server chạy qua nohup — không tự restart nếu crash (cần systemd --user, hiện không khả dụng trên máy này)."
fi
echo ""

# --- 4. Tailscale -----------------------------------------------------------
# Thay cloudflared quick tunnel (URL *.trycloudflare.com ngẫu nhiên, đổi MỖI LẦN
# restart) bằng Tailscale Funnel: URL public HTTPS cố định vĩnh viễn theo tên máy
# trong tailnet (https://<hostname>.<tailnet>.ts.net) — cần thiết để app di động
# (frontend-placeholder/index.html) nhúng thẳng code-server qua 1 URL public ổn
# định, không cần dựng thêm registry/backend riêng. Không giữ song song 2 cơ chế
# tunnel.
if command -v tailscale &>/dev/null; then
    CURRENT_VER="$(tailscale version 2>/dev/null | head -n1)"
    if [ "$(ask_choice "4) Tailscale: đã cài (${CURRENT_VER})" "tailscaleAction")" = "redo" ]; then
        curl -fsSL https://tailscale.com/install.sh | sh
    fi
else
    info "4) Tailscale chưa cài, đang cài..."
    curl -fsSL https://tailscale.com/install.sh | sh
fi
ok "Tailscale sẵn sàng: $(command -v tailscale)"

# tailscaled (daemon hệ thống) cần tự khởi động cùng OS để funnel sống lại sau
# reboot mà không cần ai đăng nhập — gói .deb/.rpm cài sẵn thường đã enable, chỉ
# tự bật nếu vì lý do gì đó chưa (idempotent, không lỗi nếu đã enabled).
if command -v systemctl &>/dev/null && ! systemctl is-enabled --quiet tailscaled 2>/dev/null; then
    if command -v pkexec &>/dev/null && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        pkexec systemctl enable tailscaled && ok "Đã bật tailscaled tự khởi động cùng OS" \
            || warn "Không tự bật được tailscaled tự khởi động — chạy tay: sudo systemctl enable tailscaled"
    else
        sudo systemctl enable tailscaled && ok "Đã bật tailscaled tự khởi động cùng OS" \
            || warn "Không tự bật được tailscaled tự khởi động — chạy tay: sudo systemctl enable tailscaled"
    fi
fi
echo ""

# --- 4b. Đăng nhập tailnet ----------------------------------------------------
# Máy có GUI (PC cá nhân): `tailscale up` tự mở trình duyệt login 1 lần. Máy
# headless (server chỉ SSH, vd Oracle Cloud): cần TAILSCALE_AUTHKEY (tạo tại
# https://login.tailscale.com/admin/settings/keys) — không cần trình duyệt.
if ! tailscale status &>/dev/null; then
    info "4b) Đăng nhập Tailscale..."
    if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
        sudo tailscale up --authkey="$TAILSCALE_AUTHKEY" --hostname="$(hostname)" --ssh
    elif [ "$HAS_GUI" = "1" ]; then
        sudo tailscale up --hostname="$(hostname)"
    else
        err "Máy headless (không GUI) cần biến TAILSCALE_AUTHKEY để đăng nhập không qua trình duyệt."
        err "Tạo key tại https://login.tailscale.com/admin/settings/keys rồi chạy lại: TAILSCALE_AUTHKEY=tskey-... bash setup.sh"
        exit 1
    fi
fi
ok "Tailscale đã đăng nhập tailnet"
echo ""

# --- 5. Tailscale Funnel cho code-server -------------------------------------
# tailscale serve/funnel: bind local port 8443 vào path "/" của URL public, funnel
# bật để expose ra internet (không chỉ trong tailnet). LƯU Ý: cú pháp CLI
# tailscale serve/funnel có thay đổi giữa các phiên bản — nếu lệnh dưới đây lỗi,
# kiểm tra `tailscale serve --help`/`tailscale funnel --help` trên máy thật và
# chỉnh lại cho khớp bản đã cài (đã note trong docs/oracle-cloud-setup.md).
TS_DNS_NAME="$(tailscale status --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null)"
[ -n "$TS_DNS_NAME" ] || { err "Không lấy được tên máy trong tailnet — kiểm tra 'tailscale status'"; exit 1; }

if [ "$(ask_choice "5) Tailscale Funnel: cấu hình cho code-server (https://$TS_DNS_NAME)" "funnelAction")" = "redo" ] || ! tailscale funnel status 2>/dev/null | grep -q "127.0.0.1:8443"; then
    # Từ Tailscale ~1.9x, `funnel <target>` tự làm luôn cả serve+funnel, target là
    # LOCAL PORT (không phải cổng public 443 như cú pháp cũ) — bug thật đã gặp:
    # chạy thêm `tailscale funnel --bg 443` sau bước serve sẽ bị hiểu là "serve
    # cổng nội bộ 443" (không có gì lắng nghe ở đó), ĐÈ mất cấu hình serve 8443
    # vừa set, gây 502 khi mở URL public. Không cần bước `tailscale serve` riêng
    # nữa — `tailscale funnel reset` trước khi set lại để tránh mắc cấu hình cũ.
    sudo tailscale funnel reset
    sudo tailscale funnel --bg 8443
fi
VSCODE_PUBLIC_URL="https://$TS_DNS_NAME"

# Verify Funnel THỰC SỰ hoạt động (không chỉ tin lệnh trên chạy xong không báo
# lỗi) — bug thật đã gặp: cú pháp tailscale sai vẫn "chạy xong" bình thường
# nhưng route sai cổng backend nội bộ, gây HTTP 502 mà chỉ phát hiện được khi
# tự tay mở URL từ điện thoại. Retry vài lần vì Funnel/cert có thể mất 1-2s để
# áp dụng ngay sau khi cấu hình.
#
# Bug thật khác đã gặp + đã fix: verify chạy NGAY TRÊN máy có cài Tailscale ->
# resolver hệ thống (MagicDNS) trả IP NỘI BỘ tailnet cho hostname *.ts.net,
# khác hẳn IP relay Funnel công khai mà 1 client ngoài tailnet (điện thoại)
# thực sự dùng -> verify PASS giả dù đường public thật đang lỗi (đúng bug user
# report: tray báo xanh nhưng điện thoại "Không thể truy cập trang web này").
# Ép resolve qua DNS công khai (dig @1.1.1.1, fallback @8.8.8.8) rồi curl
# --resolve vào đúng IP đó — cùng cơ chế với scripts/lib_status.py's
# check_funnel_public_reachable() (dùng cho tray.py), giữ đồng bộ 1 chỗ.
FUNNEL_PUBLIC_IP=""
if command -v dig &>/dev/null; then
    FUNNEL_PUBLIC_IP="$(dig @1.1.1.1 "$TS_DNS_NAME" +short +time=3 +tries=1 2>/dev/null | head -n1)"
    [ -n "$FUNNEL_PUBLIC_IP" ] || FUNNEL_PUBLIC_IP="$(dig @8.8.8.8 "$TS_DNS_NAME" +short +time=3 +tries=1 2>/dev/null | head -n1)"
fi
FUNNEL_HTTP_CODE="000"
for _ in $(seq 1 10); do
    if [ -n "$FUNNEL_PUBLIC_IP" ]; then
        FUNNEL_HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 --resolve "$TS_DNS_NAME:443:$FUNNEL_PUBLIC_IP" "$VSCODE_PUBLIC_URL" 2>/dev/null || echo 000)"
    else
        # Không có `dig`/không dò được IP public -> fallback verify theo resolver
        # hệ thống (có thể vẫn dính MagicDNS false-positive, nhưng còn hơn không
        # verify gì cả — cài `dig` (gói dnsutils/bind-utils) để verify chính xác).
        FUNNEL_HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$VSCODE_PUBLIC_URL" 2>/dev/null || echo 000)"
    fi
    case "$FUNNEL_HTTP_CODE" in
        000|502|503|504) sleep 1 ;;
        *) break ;;
    esac
done
case "$FUNNEL_HTTP_CODE" in
    000|502|503|504)
        err "Funnel cấu hình xong nhưng KHÔNG phản hồi đúng (HTTP $FUNNEL_HTTP_CODE) tại $VSCODE_PUBLIC_URL"
        warn "Debug: chạy 'tailscale serve status --json' — trường Web.*.Handlers./.Proxy phải là http://127.0.0.1:8443."
        warn "Nếu sai cổng: 'sudo tailscale funnel reset' rồi 'sudo tailscale funnel --bg 8443', sau đó chạy lại setup.sh."
        exit 1
        ;;
    *)
        ok "VS Code funnel: $VSCODE_PUBLIC_URL (đã xác nhận phản hồi HTTP $FUNNEL_HTTP_CODE)"
        ;;
esac
echo ""

CONFIG_FILE="$DIR/config.yaml"
[ -f "$CONFIG_FILE" ] || cp "$DIR/config.example.yaml" "$CONFIG_FILE"

# --- 6b. Codex CLI (Gemini qua 9Router) --------------------------------------
# openai.chatgpt (Codex) có sẵn trên Open VSX (marketplace mặc định code-server)
# -> cài thẳng bằng --install-extension, không cần install_vsix_extension() (hàm
# đó chỉ dành cho extension chỉ có trên VS Marketplace như Copilot). base_url/
# model/wire_api cố định (9Router dùng chung của team) -> chỉ hỏi OPENAI_API_KEY.
# LƯU Ý: đây phải là API key của router/proxy (thường dạng `sk-...`), KHÔNG phải
# token đăng nhập Codex (`AQ...`), nếu nhầm sẽ nhận 401 "API key required...".
CURRENT_OPENAI_KEY="$(grep '^OPENAI_API_KEY:' "$CONFIG_FILE" 2>/dev/null | sed -E 's/^OPENAI_API_KEY: *"?([^"]*)"?/\1/')"
[ "$CURRENT_OPENAI_KEY" = "YOUR_OPENAI_API_KEY_HERE" ] && CURRENT_OPENAI_KEY=""
echo "6b) Codex CLI qua 9Router (Gemini) — để trống nếu chưa dùng, có thể bổ sung ở lần chạy setup.sh sau."
OPENAI_API_KEY="$(ask_value "   OPENAI_API_KEY" "$CURRENT_OPENAI_KEY" 1 "openaiApiKey")"
if [ -n "$OPENAI_API_KEY" ] && [[ "$OPENAI_API_KEY" == AQ.* ]]; then
    error "   ❌ OPENAI_API_KEY không được là token Codex login (dạng 'AQ...')."
    error "      Phải là API key thật từ 9Router/OpenAI (dạng 'sk-...')."
    error "      Liên hệ team để lấy key 9Router, hoặc bỏ qua (để trống) lần này."
    exit 1
fi
if [ -n "$OPENAI_API_KEY" ]; then
    echo "$INSTALLED_EXT" | grep -q '^openai\.chatgpt$' || {
        info "   Đang cài extension Codex (openai.chatgpt)..."
        if code-server --install-extension openai.chatgpt --force; then
            ok "   Đã cài openai.chatgpt"
        else
            warn "   Cài openai.chatgpt thất bại — chạy lại setup.sh sau để thử lại."
        fi
    }
    mkdir -p "$HOME/.codex"
    cat > "$HOME/.codex/config.toml" <<EOF
model = "9router"
model_provider = "9router"

[model_providers.9router]
name = "9Router"
base_url = "https://r8mbsct.abc-tunnel.us/v1"
wire_api = "responses"
env_key = "OPENAI_API_KEY"

[agents.subagent]
model = "9router"
EOF
    cat > "$HOME/.codex/auth.json" <<EOF
{
  "auth_mode": "apikey",
  "OPENAI_API_KEY": "$OPENAI_API_KEY"
}
EOF
    chmod 600 "$HOME/.codex/auth.json"
    ok "   Đã ghi ~/.codex/config.toml + auth.json."
else
    info "   Bỏ qua Codex CLI (chưa có OPENAI_API_KEY)."
fi
echo ""

# --- 6c. GitHub Copilot CLI (PAT) --------------------------------------------
# Agent "Copilot CLI" trong picker của Gemini Code Assist spawn ra tiến trình con
# chạy binary `copilot` (npm @github/copilot) — tách biệt hoàn toàn khỏi extension
# github.copilot/github.copilot-chat (dùng OAuth session chỉ sống trong bộ nhớ
# tiến trình code-server, mất mỗi lần restart — xem giới hạn đã ghi ở Bước 3).
# README @github/copilot xác nhận CLI này nhận PAT không tương tác qua biến môi
# trường GH_TOKEN/GITHUB_TOKEN — vì `copilot` chạy như tiến trình con của chính
# code-server, chỉ cần PAT có mặt trong environment của code-server (ghi vào
# $CS_ENV_FILE, nạp qua EnvironmentFile= ở Bước 3) là đủ, không cần đụng gì tới
# Gemini/Copilot extension. Khác Bước 6b: OPENAI_API_KEY/GH_TOKEN cần có trong
# environment của code-server (Codex custom provider dùng env_key), nên đồng bộ cả
# hai vào cùng $CS_ENV_FILE.
CURRENT_GH_COPILOT_PAT="$(grep '^GITHUB_COPILOT_PAT:' "$CONFIG_FILE" 2>/dev/null | sed -E 's/^GITHUB_COPILOT_PAT: *"?([^"]*)"?/\1/')"
[ "$CURRENT_GH_COPILOT_PAT" = "YOUR_GITHUB_COPILOT_PAT_HERE" ] && CURRENT_GH_COPILOT_PAT=""
echo "6c) GitHub Copilot CLI (agent 'Copilot CLI' trong Gemini) — tạo PAT tại"
echo "    https://github.com/settings/personal-access-tokens/new, bật quyền \"Copilot Requests\"."
echo "    Để trống nếu chưa dùng, có thể bổ sung ở lần chạy setup.sh sau."
GITHUB_COPILOT_PAT="$(ask_value "   GITHUB_COPILOT_PAT" "$CURRENT_GH_COPILOT_PAT" 1 "githubCopilotPat")"
if [ -z "$GITHUB_COPILOT_PAT" ]; then
    info "   Bỏ qua Copilot CLI (chưa có GITHUB_COPILOT_PAT)."
fi

CS_ENV_TMP="$RUN_DIR/code-server.env.tmp"
: > "$CS_ENV_TMP"
[ -n "$OPENAI_API_KEY" ] && echo "OPENAI_API_KEY=$OPENAI_API_KEY" >> "$CS_ENV_TMP"
[ -n "$GITHUB_COPILOT_PAT" ] && echo "GH_TOKEN=$GITHUB_COPILOT_PAT" >> "$CS_ENV_TMP"

CS_ENV_CHANGED=0
if [ -s "$CS_ENV_TMP" ]; then
    if [ ! -f "$CS_ENV_FILE" ] || ! cmp -s "$CS_ENV_TMP" "$CS_ENV_FILE"; then
        mv "$CS_ENV_TMP" "$CS_ENV_FILE"
        chmod 600 "$CS_ENV_FILE"
        CS_ENV_CHANGED=1
        ok "   Đã đồng bộ OPENAI_API_KEY/GH_TOKEN vào $CS_ENV_FILE."
    else
        rm -f "$CS_ENV_TMP"
    fi
else
    rm -f "$CS_ENV_TMP"
    if [ -f "$CS_ENV_FILE" ]; then
        rm -f "$CS_ENV_FILE"
        CS_ENV_CHANGED=1
        ok "   Đã xóa $CS_ENV_FILE (không còn key nào cần export cho code-server)."
    fi
fi

if [ "$CS_ENV_CHANGED" = "1" ] && is_code_server_alive; then
    info "   OPENAI_API_KEY/GH_TOKEN vừa đổi — khởi động lại code-server để áp dụng."
    stop_code_server
    start_code_server
fi
echo ""

# --- 7. Ghi config.yaml -------------------------------------------------------
cat > "$CONFIG_FILE" <<EOF
OPENAI_API_KEY: "$OPENAI_API_KEY"
GITHUB_COPILOT_PAT: "$GITHUB_COPILOT_PAT"
VSCODE_PORT: 8443
VSCODE_PASSWORD: "$CS_PASSWORD"
VSCODE_PUBLIC_URL: "$VSCODE_PUBLIC_URL"
VSCODE_AUTH_REQUIRED: true
VSCODE_ALLOW_INSECURE: false
LOG_LEVEL: "INFO"
ENABLE_DEBUG_MODE: false
ALLOW_MULTIPLE_CONNECTIONS: false
EOF
ok "Đã ghi $CONFIG_FILE"
echo ""

# --- 8. Python venv + dependencies -------------------------------------------
# --system-site-packages (chỉ Linux): tray.py cần pystray dùng backend
# AppIndicator3 (StatusNotifierItem, có popup menu thật) thay vì fallback Xorg
# legacy (chỉ click trái gọi được item "default", KHÔNG hiện popup menu — bug
# thật đã gặp khi test: bấm icon không ra menu gì). AppIndicator3/Ayatana là
# GObject Introspection binding (`python3-gi`, gói hệ thống qua apt, không pip
# install được dễ dàng) — venv mặc định cô lập khỏi site-packages hệ thống nên
# không thấy `gi`, pystray tự fallback về Xorg. macOS/Windows dùng backend
# darwin/win32 riêng, không cần `gi`, nên chỉ set flag này trên Linux.
if [ ! -d "$DIR/venv" ]; then
    info "8) Tạo virtualenv..."
    if [ "$OS" = "linux" ]; then
        python3 -m venv --system-site-packages "$DIR/venv"
    else
        python3 -m venv "$DIR/venv"
    fi
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
if ! "$VENV_PY" -c "import yaml, dotenv" &>/dev/null; then
    err "Cài dependency Python thất bại — kiểm tra $LOG_DIR hoặc chạy tay: $VENV_PY -m pip install -r requirements.txt"
    exit 1
fi
ok "Dependencies Python sẵn sàng"
echo ""

# --- 9. Dọn dẹp bot Telegram của bản cũ (không dùng nữa) ---------------------
# telecode giờ chỉ dùng qua desktop app (Tauri) + Android app, không còn Telegram
# Mini App/bot Telegram — máy nào từng chạy bản cũ sẽ còn service systemd --user
# "telecode-bot" (xem git history nếu cần đối chiếu cấu hình unit cũ) cố restart
# mãi dù bot.py đã bị xoá khỏi source (ExecStart trỏ vào file không còn tồn tại).
# Tắt + gỡ hẳn 1 lần, idempotent (không lỗi nếu không có gì để dọn).
BOT_SERVICE="telecode-bot"
BOT_UNIT_FILE="$HOME/.config/systemd/user/${BOT_SERVICE}.service"
if [ -f "$BOT_UNIT_FILE" ]; then
    info "9) Phát hiện service bot Telegram cũ ($BOT_SERVICE) — đang tắt và gỡ bỏ..."
    systemctl --user disable --now "$BOT_SERVICE" 2>/dev/null || true
    rm -f "$BOT_UNIT_FILE"
    systemctl --user daemon-reload 2>/dev/null || true
    ok "   Đã gỡ $BOT_SERVICE."
fi
rm -f "$RUN_DIR/bot.pid"
echo ""

# --- 9b. Tray icon trạng thái (tray.py) --------------------------------------
# Bug thật đã gặp + đã fix: bản đầu dùng XDG autostart (~/.config/autostart) +
# khởi động tay 1 lần qua nohup lúc cài — nohup đó chỉ sống chung vòng đời với
# tiến trình cài đặt (vd session AI agent chạy setup.sh), KHÔNG phải service độc
# lập — hễ tiến trình cha đó kết thúc (không cần logout/khoá màn hình, chỉ cần
# session cha biến mất) là tray chết theo, icon biến mất khỏi panel dù máy vẫn
# đăng nhập bình thường; XDG autostart cũng KHÔNG tự restart nếu tray crash giữa
# chừng. Fix: dùng `systemd --user` với `PartOf=graphical-session.target` +
# `Restart=always` (đúng pattern code-server/telecode-bot đã dùng) — độc lập với
# bất kỳ tiến trình cha nào, tự sống lại nếu crash. `graphical-session.target` đã
# active ngay khi đăng nhập Cinnamon (biến DISPLAY/XAUTHORITY được systemd user
# manager import sẵn — xác nhận qua `systemctl --user show-environment` trên máy
# dev) nên `WantedBy=graphical-session.target` là đủ, không cần chờ thêm.
if [ "$USE_SYSTEMD" = "1" ]; then
    TRAY_SERVICE="telecode-tray"
    # Dọn autostart .desktop kiểu cũ nếu còn sót từ bản trước (tránh chạy 2 lần).
    rm -f "$HOME/.config/autostart/telecode-tray.desktop"

    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/$TRAY_SERVICE.service" <<EOF
[Unit]
Description=Telecode tray icon status
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=$VENV_PY $DIR/tray.py
Restart=always
RestartSec=3
StandardOutput=append:$LOG_DIR/tray.log
StandardError=append:$LOG_DIR/tray.log

[Install]
WantedBy=graphical-session.target
EOF
    systemctl --user daemon-reload
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        systemctl --user enable --now "$TRAY_SERVICE" \
            && ok "Tray icon chạy qua systemd --user (tự restart nếu crash, độc lập với tiến trình cài đặt) — service: $TRAY_SERVICE" \
            || warn "Không khởi động được tray icon ngay — thử tay: systemctl --user start $TRAY_SERVICE"
    else
        systemctl --user enable "$TRAY_SERVICE"
        ok "Đã bật tray icon (service: $TRAY_SERVICE) — tự chạy ở lần đăng nhập đồ hoạ kế tiếp (máy hiện không có phiên đồ hoạ để chạy ngay)."
    fi
elif [ "$OS" = "linux" ]; then
    warn "Không có systemd --user khả dụng — tray icon cần chạy tay: $VENV_PY $DIR/tray.py"
else
    warn "Tray icon autostart hiện chỉ hỗ trợ Linux (Cinnamon/GNOME) — trên macOS/Windows tự chạy tay: python3 tray.py"
fi
echo ""

# --- 10. Mở app Telecode + tự đóng terminal (chỉ khi cài qua wizard web) ----
# Cài xong thì tự mở luôn app Telecode (giống bấm shortcut Desktop) rồi mới kill
# $PPID (đã lưu lúc mở wizard) để đóng shell/terminal — thứ tự: mở app TRƯỚC,
# đóng terminal SAU CÙNG (mọi bước cài đặt/khởi động đã xong, không gì phụ thuộc
# chạy tiếp sau khi terminal mất).
if [ "${TELECODE_APPLYING:-0}" = "1" ] && [ -f "$ANSWERS_FILE" ]; then
    APP_BROWSER="$(resolve_app_mode_browser_bin || true)"
    if [ -n "$APP_BROWSER" ]; then
        # --class=Telecode: xem giai thich o buoc 1cb (tao shortcut Desktop) - khong
        # dat se bi Cinnamon/GNOME nhan icon Chrome that thay vi icon rieng.
        nohup "$APP_BROWSER" --app=http://localhost:8443 --class=Telecode >/dev/null 2>&1 &
    else
        nohup xdg-open http://localhost:8443 >/dev/null 2>&1 &
    fi
    disown

    CALLER_PID="$(answers_get "_callerPid")"
    if [ -n "$CALLER_PID" ] && kill -0 "$CALLER_PID" 2>/dev/null; then
        kill "$CALLER_PID" 2>/dev/null
    fi
fi

echo "======================================"
ok "Setup xong!"
echo "======================================"
echo ""
echo "📱 Trên điện thoại: mở app Telecode → bấm ⚙️ → nhập URL bên dưới để kết nối"
echo "🔗 VS Code URL: $VSCODE_PUBLIC_URL"
echo "📄 Log: $LOG_DIR/"
echo ""
echo "Chạy lại 'bash setup.sh' bất cứ lúc nào — script sẽ hỏi giữ nguyên hay khởi động lại từng phần."
