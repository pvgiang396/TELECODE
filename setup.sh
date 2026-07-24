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

    # --- Xin sudo 1 LẦN ở đây, KHI CÒN TTY THẬT --------------------------------
    # Từ dòng "nohup bash "$0" ... &" bên dưới trở đi, script chạy NỀN (detached
    # khỏi terminal) — không còn TTY nên MỌI lệnh `sudo` phía sau (kể cả patch
    # favicon/login qua patch_code_server_assets()) sẽ fail ÂM THẦM (sudo không có
    # gì để hỏi mật khẩu, không hang, chỉ lỗi rồi script vẫn "ok" nhầm vì không kiểm
    # tra exit code) — bug thật đã xác minh: favicon/PWA icon riêng KHÔNG BAO GIỜ áp
    # dụng được khi cài qua wizard (chỉ login.html/css từng patch được ở lần chạy
    # thủ công qua terminal thật, trước khi phần copy favicon được thêm vào code).
    # Né hẳn vấn đề: chown 1 LẦN thư mục code-server cần ghi sang user hiện tại ngay
    # bây giờ (còn sudo hỏi được) — patch_code_server_assets() ở các lần chạy nền
    # sau (kể cả lần này) sẽ không cần sudo nữa (đã tự phát hiện qua "[ -w "$html" ]").
    # Cũng validate/cache sudo ở đây (best-effort) — nếu sudoers không bật
    # tty_tickets (mặc định thường BẬT, cache theo từng TTY) thì các lệnh sudo khác
    # ở tiến trình nền phía sau (vd `sudo tailscale up/serve/funnel`) có thể tận dụng
    # được cache này; nếu tty_tickets bật (phổ biến) thì các lệnh đó vẫn có thể fail
    # âm thầm khi chạy nền — hạn chế đã biết, chưa xử lý triệt để.
    sudo -v || warn "Không xác thực được sudo — các bước cần quyền root phía sau có thể bị bỏ qua."
    CS_ROOT_PRECHOWN="$(find_code_server_root 2>/dev/null || true)"
    if [ -n "$CS_ROOT_PRECHOWN" ] && [ ! -w "$CS_ROOT_PRECHOWN/src/browser/pages/login.html" ]; then
        info "Cấp quyền ghi 1 lần cho thư mục code-server (cần mật khẩu sudo)..."
        sudo chown -R "$(id -u):$(id -g)" "$CS_ROOT_PRECHOWN/src/browser/pages" "$CS_ROOT_PRECHOWN/src/browser/media" \
            || warn "Không chown được thư mục code-server — icon/favicon riêng có thể không áp dụng được ở lần chạy nền này."
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
    grep -q "telecode-eye-toggle-css-v2" "$css" 2>/dev/null && css_ok=1
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
    local publisher="$1" name="$2" vsix="$RUN_DIR/${name}.vsix"
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
            # --class=Telecode: Chrome --app= mac dinh dat WM_CLASS="Google-chrome"
            # (giong het cua so Chrome that) -> Cinnamon/GNOME nhan dien trung voi
            # google-chrome.desktop (StartupWMClass=Google-chrome) da cai san, taskbar
            # luon hien icon Chrome that, bo qua ca favicon lan Icon= o duoi (bug that
            # da xac minh qua xprop). Doi WM_CLASS rieng + StartupWMClass= khop ben duoi
            # de desktop environment dung dung Icon= cua file nay.
            EXEC_LINE="$APP_BROWSER --app=http://localhost:8443 --class=Telecode"
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
StartupWMClass=Telecode
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

# --- 4. Tailscale -----------------------------------------------------------
# Thay cloudflared quick tunnel (URL *.trycloudflare.com ngẫu nhiên, đổi MỖI LẦN
# restart) bằng Tailscale Funnel: URL public HTTPS cố định vĩnh viễn theo tên máy
# trong tailnet (https://<hostname>.<tailnet>.ts.net) — cần thiết để bot.py (xem
# discover_tailnet_peers()) biết được "server nào đang sống, ở URL nào" mà không
# cần dựng thêm registry/backend riêng. Không giữ song song 2 cơ chế tunnel.
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
    sudo tailscale serve --bg --set-path=/ http://127.0.0.1:8443
    sudo tailscale funnel --bg 443
fi
VSCODE_PUBLIC_URL="https://$TS_DNS_NAME"
ok "VS Code funnel: $VSCODE_PUBLIC_URL"
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

# --- 7b. Khôi phục cấu hình AI tool (claude/copilot/gemini/deepseek) qua Telegram --
# Chỉ hỏi khi chưa có sẵn các config đó trên máy này (máy đầu tiên setup xong thì bỏ
# qua bước này) — không có API nào để bot tự "kéo" file 1 instance khác đã gửi vào
# chat (Telegram không cho bot đọc lịch sử chat), nên vẫn cần 1 bước tay: người dùng
# tải file .gpg Telegram gửi về rồi chạy 1 lệnh curl in sẵn để đẩy sang máy này.
if [ ! -f "$HOME/.claude/.credentials.json" ] && [ ! -f "$HOME/.config/github-copilot/oauth.json" ] && [ ! -f "$HOME/.gemini/oauth_creds.json" ]; then
    echo "7b) Chưa thấy cấu hình AI tool (claude/copilot/gemini) nào trên máy này."
    read -rp "    Khôi phục từ bản sao lưu qua Telegram? (y/N): " RESTORE_ANSWER < /dev/tty
    if [ "$RESTORE_ANSWER" = "y" ] || [ "$RESTORE_ANSWER" = "Y" ]; then
        RECV_PORT=10099
        RECV_OUT="$RUN_DIR/ai-configs-incoming.gpg"
        RECV_LOG="$LOG_DIR/receive-ai-configs.log"
        RECV_PID="$RUN_DIR/receive-ai-configs.pid"
        rm -f "$RECV_OUT" "$RECV_LOG"

        # Dùng chung Tailscale Funnel port 443 đã bật ở bước 5, thêm 1 path riêng
        # trỏ về receiver cục bộ (không cần mở thêm port funnel mới).
        sudo tailscale serve --bg --set-path=/telecode-ai-config-upload "http://127.0.0.1:$RECV_PORT" \
            || warn "Không cấu hình được tailscale serve cho receiver — kiểm tra 'tailscale serve --help' và tự chạy lại lệnh cho khớp bản đã cài."

        nohup python3 "$DIR/scripts/receive-ai-configs.py" "$RECV_OUT" "$RECV_PORT" > "$RECV_LOG" 2>&1 &
        echo $! > "$RECV_PID"

        UPLOAD_CODE=""
        for _ in $(seq 1 10); do
            UPLOAD_CODE="$(python3 -c "import json; print(json.load(open('$RECV_LOG')).get('code',''))" 2>/dev/null)"
            [ -n "$UPLOAD_CODE" ] && break
            sleep 0.5
        done

        if [ -z "$UPLOAD_CODE" ]; then
            warn "Receiver không khởi động được — xem $RECV_LOG, bỏ qua bước khôi phục (đăng nhập tay các AI tool sau)."
        else
            echo ""
            info "    1. Mở Telegram, gửi: /backup_configs <passphrase> cho bot (máy nguồn phải đang chạy bot.py)."
            info "    2. Tải file .gpg bot gửi về máy đang có Telegram, rồi chạy (thay <đường-dẫn-file-vừa-tải>):"
            echo "       curl -F \"file=@<đường-dẫn-file-vừa-tải>\" \"https://$TS_DNS_NAME/telecode-ai-config-upload?code=$UPLOAD_CODE\""
            echo ""
            info "    Đang chờ tối đa 5 phút... (Ctrl+C để bỏ qua, đăng nhập tay các AI tool sau)"
            WAITED=0
            while [ ! -s "$RECV_OUT" ] && [ $WAITED -lt 300 ] && is_alive "$RECV_PID"; do
                sleep 3; WAITED=$((WAITED+3))
            done
            stop_pid "$RECV_PID"

            if [ -s "$RECV_OUT" ]; then
                read -rsp "    Nhập lại passphrase để giải mã: " RESTORE_PASSPHRASE < /dev/tty; echo ""
                RESTORE_TMP_TAR="$(mktemp --suffix=.tar.gz)"
                if echo "$RESTORE_PASSPHRASE" | gpg --batch --yes --decrypt --passphrase-fd 0 -o "$RESTORE_TMP_TAR" "$RECV_OUT" 2>/dev/null; then
                    tar -xzf "$RESTORE_TMP_TAR" -C "$HOME"
                    # Siết lại permission cho file credentials (tar giữ nguyên mode gốc,
                    # nhưng đề phòng umask máy đích khác máy nguồn).
                    chmod 600 "$HOME/.claude/.credentials.json" "$HOME/.claude.json" \
                        "$HOME/.config/gh/hosts.yml" "$HOME/.config/github-copilot/oauth.json" \
                        "$HOME/.gemini/oauth_creds.json" 2>/dev/null || true
                    ok "Đã khôi phục cấu hình AI tool."
                else
                    err "Giải mã thất bại — sai passphrase? File mã hoá còn ở $RECV_OUT, thử lại tay: gpg --decrypt -o out.tar.gz $RECV_OUT"
                fi
                shred -u "$RESTORE_TMP_TAR" 2>/dev/null || rm -f "$RESTORE_TMP_TAR"
            else
                warn "Không nhận được file trong thời gian chờ — bỏ qua, đăng nhập tay các AI tool sau."
            fi
        fi
    fi
fi
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

# --- 10. Mở app Telecode + tự đóng terminal (chỉ khi cài qua wizard web) ----
# Cài xong thì tự mở luôn app Telecode (giống bấm shortcut Desktop) rồi mới kill
# $PPID (đã lưu lúc mở wizard) để đóng shell/terminal — thứ tự: mở app TRƯỚC,
# đóng terminal SAU CÙNG (mọi bước cài đặt/khởi động đã xong, không gì phụ thuộc
# chạy tiếp sau khi terminal mất).
if [ "${TELECODE_APPLYING:-0}" = "1" ] && [ -f "$ANSWERS_FILE" ]; then
    APP_BROWSER="$(resolve_app_mode_browser_bin || true)"
    if [ -n "$APP_BROWSER" ]; then
        # --class=Telecode: xem giai thich o buoc 3b (tao shortcut Desktop) - khong
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
echo "📱 Trên điện thoại: mở Telegram → tìm bot của bạn → bấm nút '🔧 VS Code' cạnh khung nhập tin nhắn"
echo "🔗 VS Code URL: $VSCODE_PUBLIC_URL"
echo "📄 Log: $LOG_DIR/"
echo ""
echo "Chạy lại 'bash setup.sh' bất cứ lúc nào — script sẽ hỏi giữ nguyên hay khởi động lại từng phần."
