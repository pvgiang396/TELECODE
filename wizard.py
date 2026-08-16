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
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "scripts"))
from lib_status import get_status, overall_ok  # noqa: E402
from cleanup_codex_writers import cleanup_codex_writer_locks  # noqa: E402
from lib_env import prepare_env_for_codex  # noqa: E402

PORT = 8899


def cleanup_startup_state() -> None:
    """Clear only Codex lock files that no live process currently holds."""
    for lock_name in cleanup_codex_writer_locks():
        print(f"[telecode] removed abandoned Codex writer lock: {lock_name}", flush=True)


def _cmdctl_exec(command: str, sudo: bool = False, timeout_ms: int = 120000) -> dict:
    """Gọi cmdctl (đã có sẵn trong workspace, xem root CLAUDE.md) để chạy lệnh cần sudo —
    KHÔNG tự gọi sudo trực tiếp (sẽ treo chờ nhập mật khẩu tương tác)."""
    cmdctl_url = os.environ.get("CMDCTL_URL", "http://127.0.0.1:3003")
    payload = json.dumps({"command": command, "sudo": sudo, "timeoutMs": timeout_ms}).encode("utf-8")
    req = urllib.request.Request(
        f"{cmdctl_url}/exec", data=payload, method="POST",
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout_ms / 1000 + 10) as resp:
        return json.loads(resp.read())


def run_self_update() -> dict:
    """Tính năng "Cập nhật ứng dụng" (nút 🔄 trong wizard.html) — port từ
    k8sql/server/src/selfUpdate.ts: git pull -> build lại .deb -> cài qua cmdctl -> tự
    restart. CHỈ hoạt động trên máy có sẵn git checkout nguồn (TELECODE_SOURCE_DIR), giống
    hệt phạm vi K8SQL_SOURCE_DIR bên k8sql — máy user cài .deb bình thường (không có
    checkout) sẽ nhận lỗi rõ ràng ở đây, không có hạ tầng phân phối/CI cho trường hợp đó."""
    if os.environ.get("TELECODE_MANAGED") != "1":
        raise RuntimeError("Tính năng Cập nhật ứng dụng chỉ dùng được trong bản Tauri.")
    if sys.platform != "linux" or is_wsl():
        raise RuntimeError("Cập nhật ứng dụng hiện chỉ hỗ trợ Linux native (không WSL).")
    source_dir = os.environ.get("TELECODE_SOURCE_DIR")
    if not source_dir:
        raise RuntimeError(
            "Chưa có TELECODE_SOURCE_DIR (đường dẫn git checkout nguồn telecode) trong môi "
            "trường — tính năng này chỉ dùng được trên máy dev có sẵn checkout, xem CLAUDE.md."
        )
    source_path = Path(source_dir)
    if not source_path.is_dir():
        raise RuntimeError(f"TELECODE_SOURCE_DIR không tồn tại: {source_dir}")

    git_out = subprocess.run(
        ["git", "-C", str(source_path), "pull"],
        capture_output=True, text=True, timeout=60,
    )
    if git_out.returncode != 0:
        raise RuntimeError(f"git pull lỗi: {git_out.stderr.strip()}")

    build = subprocess.run(
        ["npm", "run", "build", "--", "--targets", "linux"],
        cwd=str(source_path), capture_output=True, text=True, timeout=600,
    )
    if build.returncode != 0:
        raise RuntimeError(f"Build lỗi: {build.stderr[-2000:]}")

    deb_dir = source_path / "dist" / "linux-x64"
    debs = sorted(deb_dir.glob("*.deb"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not debs:
        raise RuntimeError(f"Không tìm thấy .deb mới trong {deb_dir}")
    deb_path = debs[0]

    try:
        result = _cmdctl_exec(f'dpkg -i "{deb_path}"', sudo=True, timeout_ms=120000)
    except (urllib.error.URLError, OSError) as e:
        raise RuntimeError(
            f"Không gọi được cmdctl để cài .deb (đã chạy chưa? xem projects/cmdctl/CLAUDE.md): {e}"
        )
    if result.get("exitCode", 0) != 0:
        raise RuntimeError(f"Cài .deb thất bại (exitCode={result.get('exitCode')}): {result.get('stderr')}")

    # Kill + respawn detached — pattern/gotcha giống hệt k8sql (xem selfUpdate.ts):
    # (1) -9 vì graceful shutdown có thể treo do chính request HTTP đang mở; (2) -f (khớp
    # cmdline) vì binary Rust/PyInstaller không lộ đúng tên qua /proc/pid/comm; (3) neo ^
    # BẮT BUỘC — thiếu neo thì chính lệnh pkill đang chạy trong script này (chứa chữ
    # "telecode-sidecar"/"telecode" trong cmdline của nó) sẽ tự khớp và tự giết mình giữa
    # chừng trước khi kịp respawn.
    respawn_script = (
        "sleep 1\n"
        "pkill -9 -f '^[^ ]*telecode-sidecar' || true\n"
        "pkill -9 -f '^[^ ]*telecode( --tray)?$' || true\n"
        "sleep 2\n"
        "DISPLAY=${DISPLAY:-:0} nohup telecode --tray >/dev/null 2>&1 &\n"
    )
    subprocess.Popen(["bash", "-c", respawn_script], start_new_session=True)

    return {
        "ok": True,
        "message": f"Đã cập nhật lên bản build mới ({deb_path.name}) — ứng dụng sẽ tự khởi động lại sau vài giây.",
    }


def probe_status(run_dir: Path, dir_: Path) -> dict:
    """Wrapper mỏng gọi scripts/lib_status.py (dùng chung với tray.py) — giữ
    nguyên tên hàm/field cũ để không phải sửa chỗ gọi bên dưới. check_public=False
    vì UI wizard poll liên tục lúc cài đặt, không cần tốn round-trip curl public
    mỗi lần (tray.py mới là nơi cần check_public=True để quyết định icon).
    project_dir=dir_ — BẮT BUỘC truyền tường minh, không để get_status() tự suy ra từ
    run_dir.parent (chỉ đúng ở CLI gốc — xem docstring get_status())."""
    return get_status(run_dir, check_public=False, project_dir=dir_)


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
            # bỏ query string trước khi so khớp route — self.path giữ nguyên full path+query
            # (BaseHTTPRequestHandler không tự tách), cần thiết từ khi main.rs (Tauri) mở URL kèm
            # ?tauri=1 để wizard.html biết bỏ qua window.close() (xem CLAUDE.md).
            self.path = self.path.split("?", 1)[0]
            if self.path == "/" or self.path == "":
                body = wizard_html.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif self.path == "/api/status":
                self._send_json(200, probe_status(run_dir, dir_))
            elif self.path == "/api/tray-status":
                # Route riêng cho main.rs (Tauri) poll đổi icon tray xanh/đỏ — TÁCH
                # khỏi /api/status vì cần check_public=True (curl thật tới Funnel
                # public URL, xem overall_ok() trong lib_status.py) trong khi
                # /api/status ở trên cố tình check_public=False để UI wizard poll
                # nhanh/liên tục không bị chậm bởi round-trip mạng ngoài.
                status = get_status(run_dir, check_public=True, project_dir=dir_)
                self._send_json(200, {"overallOk": overall_ok(status)})
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
            if self.path == "/api/self-update":
                try:
                    self._send_json(200, run_self_update())
                except Exception as e:
                    self._send_json(500, {"ok": False, "error": str(e)})
                return
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
            if os.environ.get("TELECODE_MANAGED") == "1":
                # Chạy trong Tauri: KHÔNG có tiến trình bash setup.sh nào đang chờ đọc
                # wizard-answers.json (khác luồng CLI gốc, xem dưới) — tự spawn nền ở đây,
                # KHÔNG tự thoát server vì cửa sổ Tauri còn cần /api/status để hiển thị
                # tiến trình cài đặt/link VS Code sau khi xong.
                log_dir = dir_ / "logs"
                log_dir.mkdir(parents=True, exist_ok=True)
                env = prepare_env_for_codex()
                env["TELECODE_APPLYING"] = "1"
                env["TELECODE_RUN_DIR"] = str(run_dir)
                with open(log_dir / "setup-apply.log", "ab") as log_f:
                    subprocess.Popen(
                        ["bash", str(dir_ / "setup.sh")],
                        cwd=str(dir_), env=env, stdout=log_f, stderr=subprocess.STDOUT,
                        start_new_session=True,
                    )
            else:
                # Luồng CLI gốc: setup.sh (bash) đang chạy foreground `python3 wizard.py`,
                # đợi tiến trình này thoát để đọc file answers rồi tự tiếp tục cài đặt.
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
    cleanup_startup_state()
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
