#!/usr/bin/env python3
"""
Wizard cài đặt telecode qua web — thay cho hỏi từng bước qua terminal.

Pattern tham khảo từ /home/pvgiang396/yan2ai (public/setup.html + src/http/server.js):
1 HTTP server nhỏ (stdlib, không thêm dependency) serve 1 trang HTML tĩnh, JS thuần
fetch /api/status để tự vẽ đúng bước cần hỏi, rồi POST /api/save. Server ghi câu trả
lời ra file rồi tự thoát — setup.sh (bash) đọc file đó để tiếp tục cài đặt thật, không
hỏi lại qua terminal.

Chạy: python3 wizard.py <RUN_DIR> <DIR>
  RUN_DIR - nơi lưu wizard-answers.json (thường $RUN_DIR = <project>/.run)
  DIR     - thư mục project telecode (chứa assets/wizard.html)
"""
import http.server
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

PORT = 8899


def is_alive(pidfile: Path) -> tuple[bool, int]:
    if not pidfile.exists():
        return False, 0
    try:
        pid = int(pidfile.read_text().strip())
    except ValueError:
        return False, 0
    try:
        os.kill(pid, 0)
        return True, pid
    except OSError:
        return False, 0


def read_value(path: Path, key_prefix: str) -> str:
    """Đọc giá trị dạng 'key: "value"' hoặc 'key: value' từ file yaml đơn giản."""
    if not path.exists():
        return ""
    for line in path.read_text().splitlines():
        if line.strip().startswith(key_prefix):
            v = line.split(":", 1)[1].strip()
            return v.strip('"').strip("'")
    return ""


def probe_status(run_dir: Path) -> dict:
    cs_config = Path.home() / ".config/code-server/config.yaml"
    project_config = run_dir.parent / "config.yaml"

    cs_installed = shutil.which("code-server") is not None
    cs_version = ""
    if cs_installed:
        try:
            cs_version = subprocess.run(
                ["code-server", "--version"], capture_output=True, text=True, timeout=5
            ).stdout.splitlines()[0]
        except Exception:
            cs_version = ""

    # Tailscale thay cloudflared làm tunnel (xem setup.sh bước 4/5) — probe đúng 2
    # lệnh setup.sh tự dùng để quyết định "keep"/"redo" (tailscale version / tailscale
    # funnel status), không còn PID file/log riêng như cloudflared cũ (tailscaled là
    # daemon hệ thống, không phải tiến trình con setup.sh tự quản).
    ts_installed = shutil.which("tailscale") is not None
    ts_version = ""
    if ts_installed:
        try:
            ts_version = subprocess.run(
                ["tailscale", "version"], capture_output=True, text=True, timeout=5
            ).stdout.splitlines()[0]
        except Exception:
            ts_version = ""

    cs_running, cs_pid = is_alive(run_dir / "code-server.pid")
    bot_running, bot_pid = is_alive(run_dir / "bot.pid")

    funnel_configured = False
    tailscale_url = ""
    if ts_installed:
        try:
            fs = subprocess.run(
                ["tailscale", "funnel", "status"], capture_output=True, text=True, timeout=5
            ).stdout
            funnel_configured = "127.0.0.1:8443" in fs
        except Exception:
            pass
        try:
            st = json.loads(subprocess.run(
                ["tailscale", "status", "--json"], capture_output=True, text=True, timeout=5
            ).stdout)
            dns_name = st.get("Self", {}).get("DNSName", "").rstrip(".")
            if dns_name:
                tailscale_url = f"https://{dns_name}"
        except Exception:
            pass

    current_password = read_value(cs_config, "password:")
    current_token = read_value(project_config, "TELEGRAM_BOT_TOKEN:")
    if current_token == "YOUR_BOT_TOKEN_HERE":
        current_token = ""

    return {
        "codeServerInstalled": cs_installed,
        "codeServerVersion": cs_version,
        "codeServerRunning": cs_running,
        "codeServerPid": cs_pid,
        "tailscaleInstalled": ts_installed,
        "tailscaleVersion": ts_version,
        "funnelConfigured": funnel_configured,
        "tailscaleUrl": tailscale_url,
        "botRunning": bot_running,
        "botPid": bot_pid,
        "currentPassword": current_password,
        "currentToken": current_token,
    }


def make_handler(run_dir: Path, dir_: Path, caller_pid: str = ""):
    wizard_html = (dir_ / "assets" / "wizard.html").read_text(encoding="utf-8")
    icon_path = dir_ / "assets" / "icon.png"
    icon_bytes = icon_path.read_bytes() if icon_path.exists() else b""

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass  # im lặng, tránh rác log ra terminal

        def _send_json(self, status: int, payload: dict):
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/" or self.path == "":
                body = wizard_html.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif self.path == "/api/status":
                self._send_json(200, probe_status(run_dir))
            elif self.path == "/icon.png" and icon_bytes:
                # Favicon riêng của wizard — không có link này thì Chrome dùng icon
                # mặc định của nó cho cửa sổ --app=, kể cả taskbar/alt-tab (đã xác
                # nhận qua _NET_WM_ICON bằng xprop).
                self.send_response(200)
                self.send_header("Content-Type", "image/png")
                self.send_header("Content-Length", str(len(icon_bytes)))
                self.end_headers()
                self.wfile.write(icon_bytes)
            else:
                self._send_json(404, {"error": "not found"})

        def do_POST(self):
            if self.path != "/api/save":
                self._send_json(404, {"error": "not found"})
                return
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length)
            try:
                answers = json.loads(raw)
            except json.JSONDecodeError:
                self._send_json(400, {"error": "invalid json"})
                return
            # _callerPid lấy từ argv (server tự biết, KHÔNG lấy từ form client) để
            # tránh client giả mạo PID rồi làm setup.sh kill nhầm tiến trình khác.
            if caller_pid:
                answers["_callerPid"] = caller_pid
            (run_dir / "wizard-answers.json").write_text(json.dumps(answers, ensure_ascii=False, indent=2))
            self._send_json(200, {"ok": True})
            threading.Thread(target=lambda: (time.sleep(0.3), os._exit(0))).start()

    return Handler


def is_wsl() -> bool:
    try:
        return "microsoft" in Path("/proc/version").read_text().lower()
    except Exception:
        return False


def resolve_app_mode_browser_bin():
    """Dò Chrome/Edge/Chromium để mở --app= (ẩn thanh địa chỉ) — giống
    resolve_app_mode_browser_bin() trong setup.sh, tham khảo openAppModeBrowser()
    của yan2ai/tray.js."""
    if sys.platform == "darwin":
        candidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
        ]
        for c in candidates:
            if Path(c).exists():
                return c
        return None
    names = ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
             "microsoft-edge", "microsoft-edge-stable"]
    for n in names:
        p = shutil.which(n)
        if p:
            return p
    return None


def open_browser_plain(url: str):
    # Python trong WSL báo sys.platform == "linux" (không phải "win32") -> phải tự
    # phát hiện WSL riêng để gọi trình duyệt Windows qua cmd.exe, xdg-open không
    # có tác dụng gì trong WSL (không có X server).
    bin_ = resolve_app_mode_browser_bin()
    if bin_ and not is_wsl():
        # --app= ẩn thanh địa chỉ/tab, trông như 1 app desktop thay vì tab trình duyệt.
        opener = [bin_, f"--app={url}"]
    elif sys.platform == "darwin":
        opener = ["open", url]
    elif sys.platform == "win32":
        opener = ["cmd", "/c", "start", "", url]
    elif is_wsl():
        opener = ["cmd.exe", "/c", "start", "", url]
    else:
        opener = ["xdg-open", url]
    try:
        subprocess.Popen(opener, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        print(f"Không tự mở được trình duyệt — mở tay: {url}")


def main():
    if len(sys.argv) < 3:
        print("Usage: wizard.py <RUN_DIR> <DIR> [caller_pid]", file=sys.stderr)
        sys.exit(1)
    run_dir = Path(sys.argv[1])
    dir_ = Path(sys.argv[2])
    caller_pid = sys.argv[3] if len(sys.argv) > 3 else ""
    run_dir.mkdir(parents=True, exist_ok=True)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), make_handler(run_dir, dir_, caller_pid))
    url = f"http://127.0.0.1:{PORT}/"
    print(f"✅ Wizard đang chạy tại {url}")
    threading.Timer(0.5, lambda: open_browser_plain(url)).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
