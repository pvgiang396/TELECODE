#!/bin/bash
#
# Launcher gọi bởi shortcut Desktop "Telecode" (tạo bởi setup.sh, bước 1cb) — tự
# kiểm tra + khởi động lại code-server/bot/Tailscale nếu đang tắt (qua
# scripts/reconnect.sh, dùng chung với tray.py's menu "Kết nối lại"), rồi mới mở
# trình duyệt. Không hỏi lại mật khẩu/token, không cài đặt gì mới. Muốn cài đặt
# lần đầu hoặc đổi cấu hình, chạy bash setup.sh.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

OS="linux"
[ "$(uname -s)" = "Darwin" ] && OS="mac"

# --- 1+2) restart code-server/bot nếu tắt + reconnect Tailscale nếu cần -------
bash "$DIR/scripts/reconnect.sh" || true

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
