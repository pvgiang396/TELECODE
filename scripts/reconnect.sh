#!/bin/bash
#
# Tách từ launch.sh (bước 1+2 cũ) để dùng chung cho cả shortcut Desktop
# (launch.sh gọi lại rồi mới mở browser) lẫn tray.py (menu "Kết nối lại", chạy
# headless không mở browser). CHỈ start lại service đã có sẵn (unit systemd +
# config.yaml do setup.sh sinh từ lần cài đặt trước) — không hỏi lại mật
# khẩu/token, không cài đặt gì mới. Muốn cài đặt lần đầu hoặc đổi cấu hình,
# chạy bash setup.sh.
#
# Gốc vấn đề cần xử lý: Tailscale có thể tự đăng xuất ("Stopped; run 'tailscale
# up' to log in") sau khi máy sleep/restart mạng/xung đột VPN khác (vd Cloudflare
# WARP), dù tailscaled daemon + code-server vẫn chạy bình thường — lúc đó app di
# động không vào được (funnel không còn public ra internet) dù mở trên máy tính
# vẫn OK. Script này tự phát hiện + tự đăng nhập lại, không cần user tự gõ lệnh
# debug.
#
# Bug thật khác đã gặp (không phải "Stopped"): BackendState vẫn "Running"
# nhưng control-plane của tailscaled bị treo (`tailscale status --json`'s
# `Self.Online` = false) do xung đột Cloudflare WARP chạy song song (`warp-svc`
# làm gián đoạn kết nối tới controlplane.tailscale.com, log thật thấy `control:
# map response long-poll timed out!`) — Funnel relay coi node offline, không
# proxy được về máy dù local vẫn "Running" bình thường. Bước 2b bên dưới xử lý
# đúng trường hợp này (khác bước 2 chỉ bắt được lúc thật sự "Stopped").
#
# Exit code: 0 = mọi thứ OK/đã sửa xong; 1 = Tailscale reconnect thất bại (cần
# user tự chạy tay `sudo tailscale up`).

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

EXIT_CODE=0

# --- 1) code-server: chỉ START lại, KHÔNG tạo/ghi đè unit hay config ----------
if [ "$USE_SYSTEMD" = "1" ]; then
    systemctl --user is-active --quiet code-server || systemctl --user start code-server
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
fi

# pkexec: hộp thoại polkit đồ hoạ, không cần TTY (không có TTY khi mở từ
# desktop icon/tray) — chỉ dùng được khi có DISPLAY/WAYLAND_DISPLAY (luôn có ở
# đây vì user vừa bấm icon/desktop). Fallback sudo cho trường hợp máy không có
# pkexec (hiếm khi chạy tới nhánh này). Dùng chung cho cả bước 2 và 2b.
if command -v pkexec &>/dev/null && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    RUN_ROOT="pkexec"
else
    RUN_ROOT="sudo"
fi

ts_self_online() {
    tailscale status --json 2>/dev/null | python3 -c "import json,sys
try:
    print(json.load(sys.stdin).get('Self',{}).get('Online', False))
except Exception:
    print(False)" 2>/dev/null
}

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

        if $RUN_ROOT bash -c "$TS_CMD"; then
            notify "✅ Đã kết nối lại Tailscale — app di động dùng được ngay."
        else
            notify "⚠️ Không đăng nhập lại được Tailscale — mở terminal chạy tay: sudo tailscale up"
            EXIT_CODE=1
        fi
    # --- 2b) BackendState "Running" nhưng control-plane treo (Self.Online=false) --
    # Xem giải thích ở đầu file (xung đột Cloudflare WARP). Fix: ngắt WARP nếu
    # đang chạy (best-effort, warp-cli không cần root) rồi restart tailscaled
    # để ép daemon tái kết nối control-plane — đã verify thật trên máy dev, chỉ
    # đăng nhập lại (`tailscale up`) không đủ vì phiên vẫn "Running" nên
    # tailscaled không tự thử reconnect.
    elif [ "$(ts_self_online)" != "True" ]; then
        # warp-cli status chỉ phản ánh trạng thái "kết nối VPN" phía người dùng —
        # KHÔNG phản ánh daemon warp-svc (root, systemd) có đang chạy hay không.
        # Bug thật đã gặp: warp-cli báo "Disconnected" nhưng warp-svc service vẫn
        # active, daemon vẫn giữ hook/route mạng đủ để làm đứt TLS handshake tới
        # relay Funnel (unexpected eof while reading) — nhánh cũ chỉ check
        # warp-cli nên bỏ sót case này, restart tailscaled một mình không đủ.
        # Kiểm tra thẳng systemd service, dừng hẳn (không chỉ disconnect) nếu
        # đang active; gộp chung 1 lệnh root với restart tailscaled để chỉ hiện
        # 1 hộp thoại pkexec.
        STOP_WARP_CMD=""
        systemctl is-active --quiet warp-svc 2>/dev/null && STOP_WARP_CMD="systemctl stop warp-svc && "

        RESTART_CMD="${STOP_WARP_CMD}systemctl restart tailscaled"
        if $RUN_ROOT bash -c "$RESTART_CMD"; then
            sleep 5
            if [ "$(ts_self_online)" = "True" ]; then
                notify "✅ Đã khôi phục kết nối Tailscale (control-plane bị treo, có thể do xung đột WARP) — app di động dùng được ngay."
            else
                notify "⚠️ Đã restart tailscaled nhưng vẫn chưa online — kiểm tra tay: tailscale status"
                EXIT_CODE=1
            fi
        else
            notify "⚠️ Không restart được tailscaled — mở terminal chạy tay: sudo systemctl restart tailscaled"
            EXIT_CODE=1
        fi
    fi
fi

exit $EXIT_CODE
