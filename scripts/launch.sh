#!/bin/bash
#
# Launcher gọi bởi shortcut Desktop "Telecode" (tạo bởi setup.sh, bước 1cb) — tự
# kiểm tra + khởi động lại code-server/bot/Tailscale nếu đang tắt, rồi mới mở
# trình duyệt. CHỈ start lại service đã có sẵn (unit systemd + config.yaml do
# setup.sh sinh từ lần cài đặt trước) — không hỏi lại mật khẩu/token, không cài
# đặt gì mới. Muốn cài đặt lần đầu hoặc đổi cấu hình, chạy bash setup.sh.
#
# Gốc vấn đề cần xử lý: Tailscale có thể tự đăng xuất ("Stopped; run 'tailscale
# up' to log in") sau khi máy sleep/restart mạng, dù tailscaled daemon + code-
# server + bot vẫn chạy bình thường — lúc đó mini app trên điện thoại không vào
# được (funnel không còn public ra internet) dù mở trên máy tính vẫn OK. Script
# này tự phát hiện + tự đăng nhập lại, không cần user tự gõ lệnh debug.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="$DIR/.run"
LOG_DIR="$DIR/logs"
mkdir -p "$RUN_DIR" "$LOG_DIR"

OS="linux"
[ "$(uname -s)" = "Darwin" ] && OS="mac"

USE_SYSTEMD=0
if [ "$OS" = "linux" ] && command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    USE_SYSTEMD=1
fi

# Best-effort desktop notification — im lặng nếu không có notify-send (không
# chặn luồng chạy, chỉ là thông báo phụ).
notify() { command -v notify-send &>/dev/null && notify-send "Telecode" "$1" 2>/dev/null || true; }

is_alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

# --- 1) code-server + bot: chỉ START lại, KHÔNG tạo/ghi đè unit hay config ----
if [ "$USE_SYSTEMD" = "1" ]; then
    systemctl --user is-active --quiet code-server || systemctl --user start code-server
    systemctl --user is-active --quiet telecode-bot || systemctl --user start telecode-bot
else
    # macOS/máy không có systemd --user thật -> fallback nohup, dùng lại đúng
    # cấu hình đã ghi ở lần chạy setup.sh trước (CS_ENV_FILE, workspace mặc định).
    CS_PID="$RUN_DIR/code-server.pid"
    if ! is_alive "$CS_PID"; then
        CODE_SERVER_WORKSPACE="${CODE_SERVER_WORKSPACE:-$HOME/Code}"
        [ -d "$CODE_SERVER_WORKSPACE" ] || CODE_SERVER_WORKSPACE="$HOME"
        CS_ENV_FILE="$RUN_DIR/code-server.env"
        ( set -a; [ -f "$CS_ENV_FILE" ] && . "$CS_ENV_FILE"; set +a
          nohup code-server --bind-addr 127.0.0.1:8443 "$CODE_SERVER_WORKSPACE" > "$LOG_DIR/code-server.log" 2>&1 & echo $! > "$CS_PID" )
    fi
    BOT_PID="$RUN_DIR/bot.pid"
    if ! is_alive "$BOT_PID" && [ -x "$DIR/venv/bin/python3" ]; then
        (cd "$DIR" && setsid nohup "$DIR/venv/bin/python3" bot.py > "$LOG_DIR/bot.log" 2>&1 < /dev/null & echo $! > "$BOT_PID")
    fi
fi

# --- 2) Tailscale: đăng nhập lại nếu bị "Stopped" (đăng xuất) hoặc daemon tắt --
# tailscale status --json không kết nối được socket (daemon tắt) lẫn trạng thái
# "Stopped" (đăng xuất) đều cho BackendState khác "Running" -> chỉ cần đúng 1
# điều kiện này để quyết định có cần sửa hay không.
if command -v tailscale &>/dev/null; then
    TS_BACKEND_STATE="$(tailscale status --json 2>/dev/null | python3 -c "import json,sys
try:
    print(json.load(sys.stdin).get('BackendState',''))
except Exception:
    print('')" 2>/dev/null)"

    if [ "$TS_BACKEND_STATE" != "Running" ]; then
        TS_CMD="tailscale up --hostname=$(hostname) --operator=$(whoami)"
        # Daemon hệ thống (tailscaled) tắt hẳn -> cần start trước, gộp chung 1
        # lệnh root duy nhất để chỉ hiện 1 hộp thoại xác nhận (cùng pattern gộp
        # sudo trong setup.sh's patch_code_server_assets()).
        systemctl is-active --quiet tailscaled 2>/dev/null || TS_CMD="systemctl start tailscaled && sleep 2 && $TS_CMD"

        # pkexec: hộp thoại polkit đồ hoạ, không cần TTY (không có TTY khi mở từ
        # desktop icon) — chỉ dùng được khi có DISPLAY/WAYLAND_DISPLAY (luôn có ở
        # đây vì user vừa double-click icon trên desktop). Fallback sudo cho
        # trường hợp máy không có pkexec (hiếm khi chạy tới nhánh này).
        if command -v pkexec &>/dev/null && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
            RUN_ROOT="pkexec"
        else
            RUN_ROOT="sudo"
        fi
        if $RUN_ROOT bash -c "$TS_CMD"; then
            notify "✅ Đã kết nối lại Tailscale — mini app trên điện thoại dùng được ngay."
        else
            notify "⚠️ Không đăng nhập lại được Tailscale — mở terminal chạy tay: sudo tailscale up"
        fi
    fi
fi

# --- 3) Mở app (giống hệt logic tạo shortcut trong setup.sh) ------------------
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

APP_BROWSER="$(resolve_app_mode_browser_bin || true)"
if [ -n "$APP_BROWSER" ]; then
    # --class=Telecode: xem giải thích ở setup.sh bước 1cb (icon taskbar riêng).
    nohup "$APP_BROWSER" --app=http://localhost:8443 --class=Telecode >/dev/null 2>&1 &
elif [ "$OS" = "mac" ]; then
    open http://localhost:8443
else
    nohup xdg-open http://localhost:8443 >/dev/null 2>&1 &
fi
