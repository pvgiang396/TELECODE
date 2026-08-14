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

sys.path.insert(0, str(Path(__file__).resolve().parent / "scripts"))
from lib_status import get_status  # noqa: E402

PORT = 8899


def probe_status(run_dir: Path) -> dict:
    """Wrapper mỏng gọi scripts/lib_status.py (dùng chung với tray.py) — giữ
    nguyên tên hàm/field cũ để không phải sửa chỗ gọi bên dưới. check_public=False
    vì UI wizard poll liên tục lúc cài đặt, không cần tốn round-trip curl public
    mỗi lần (tray.py mới là nơi cần check_public=True để quyết định icon)."""
    return get_status(run_dir, check_public=False)


def make_handler(run_dir: Path, dir_: Path, caller_pid: str = ""):
    wizard_html = (dir_ / "assets" / "wizard.html").read_text(encoding="utf-8")
    icon_path = dir_ / "assets" / "icon.png"
    icon_bytes = icon_path.read_bytes() if icon_path.exists() else b""
    pat_guide_path = dir_ / "assets" / "pat-guide.html"
    pat_guide_html = pat_guide_path.read_text(encoding="utf-8") if pat_guide_path.exists() else ""
    pat_guide_img1 = (dir_ / "assets" / "pat-guide-1.jpg")
    pat_guide_img1_bytes = pat_guide_img1.read_bytes() if pat_guide_img1.exists() else b""
    pat_guide_img2 = (dir_ / "assets" / "pat-guide-2.jpg")
    pat_guide_img2_bytes = pat_guide_img2.read_bytes() if pat_guide_img2.exists() else b""

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
            elif self.path == "/pat-guide.html" and pat_guide_html:
                body = pat_guide_html.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif self.path == "/pat-guide-1.jpg" and pat_guide_img1_bytes:
                self.send_response(200)
                self.send_header("Content-Type", "image/jpeg")
                self.send_header("Content-Length", str(len(pat_guide_img1_bytes)))
                self.end_headers()
                self.wfile.write(pat_guide_img1_bytes)
            elif self.path == "/pat-guide-2.jpg" and pat_guide_img2_bytes:
                self.send_response(200)
                self.send_header("Content-Type", "image/jpeg")
                self.send_header("Content-Length", str(len(pat_guide_img2_bytes)))
                self.end_headers()
                self.wfile.write(pat_guide_img2_bytes)
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
    # telecode (Tauri shell) đã tự mở 1 cửa sổ native trỏ vào URL này — tự mở thêm 1 trình duyệt
    # ở đây sẽ ra 2 cửa sổ trùng lặp. Đặt TELECODE_MANAGED=1 (dispatcher.py không set biến này —
    # chỉ Rust side set khi spawn qua sidecar) để bỏ qua bước tự mở trình duyệt; chạy độc lập qua
    # CLI như telecode gốc (không có biến này) thì hành vi giữ nguyên y hệt.
    if os.environ.get("TELECODE_MANAGED") != "1":
        threading.Timer(0.5, lambda: open_browser_plain(url)).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
