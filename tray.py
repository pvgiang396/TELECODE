#!/usr/bin/env python3
"""
Tray icon trạng thái telecode (Linux/Cinnamon, X11) — hiển thị trực quan
code-server/bot/Tailscale/funnel có đang hoạt động VÀ mini app Telegram có thật
sự truy cập được từ internet hay không (không chỉ "service đang chạy"), thay vì
phải SSH/ngồi trước máy tra tay mỗi lần nghi ngờ. Bấm "Kết nối lại" tự sửa mọi
thứ (restart code-server/bot + đăng nhập lại Tailscale) qua scripts/reconnect.sh
— cùng logic shortcut Desktop "Telecode" đang dùng, không viết lại.

Chạy: python3 tray.py (cần DISPLAY — máy có phiên đồ hoạ Cinnamon đang mở).
Tự khởi động qua ~/.config/autostart/telecode-tray.desktop (setup.sh sinh).
"""
import subprocess
import sys
import threading
import time
from pathlib import Path

DIR = Path(__file__).resolve().parent
RUN_DIR = DIR / ".run"
LOG_DIR = DIR / "logs"
RUN_DIR.mkdir(exist_ok=True)
LOG_DIR.mkdir(exist_ok=True)

sys.path.insert(0, str(DIR / "scripts"))
from lib_status import get_status, is_alive, overall_ok  # noqa: E402

POLL_INTERVAL_SEC = 30
TRAY_PID_FILE = RUN_DIR / "tray.pid"


def notify(message: str):
    try:
        subprocess.Popen(
            ["notify-send", "Telecode", message],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        pass


def ensure_single_instance():
    alive, pid = is_alive(TRAY_PID_FILE)
    if alive:
        print(f"tray.py đã chạy (PID {pid}) — thoát.")
        sys.exit(0)
    TRAY_PID_FILE.write_text(str(__import__("os").getpid()))


def title_ascii(ok: bool) -> str:
    """icon.title (WM_NAME, X11 legacy tray protocol) chỉ chấp nhận Latin-1 — đã
    xác nhận qua test thật: python-xlib's set_wm_name() dùng STRING encoding,
    UnicodeEncodeError ngay với emoji/tiếng Việt có dấu. Menu items (Gtk popup)
    KHÔNG bị giới hạn này nên vẫn giữ nguyên tiếng Việt/emoji ở status_summary_text()."""
    return "Telecode - OK" if ok else "Telecode - Down"


def status_summary_text(status: dict) -> str:
    if overall_ok(status):
        return "🟢 Telecode: hoạt động — mini app dùng được"
    problems = []
    if not status.get("codeServerRunning"):
        problems.append("code-server tắt")
    if not status.get("botRunning"):
        problems.append("bot tắt")
    if status.get("tailscaleBackendState") != "Running":
        problems.append("Tailscale chưa đăng nhập")
    elif not status.get("tailscaleSelfOnline", True):
        problems.append("Tailscale control-plane bị treo (thử Kết nối lại — có thể do xung đột WARP)")
    elif not status.get("funnelConfigured"):
        problems.append("Funnel chưa cấu hình")
    elif not status.get("funnelPubliclyReachable"):
        problems.append(f"mini app KHÔNG vào được (HTTP {status.get('funnelPublicHttpCode')})")
    return "🔴 Telecode: " + (", ".join(problems) if problems else "ngắt kết nối")


def open_vscode():
    subprocess.Popen(
        ["bash", str(DIR / "scripts" / "launch.sh")],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def run_reconnect() -> bool:
    proc = subprocess.run(
        ["bash", str(DIR / "scripts" / "reconnect.sh")],
        capture_output=True, text=True, timeout=60,
    )
    return proc.returncode == 0


def main():
    ensure_single_instance()
    try:
        _run_tray()
    finally:
        TRAY_PID_FILE.unlink(missing_ok=True)


def _run_tray():
    import pystray
    from PIL import Image

    icon_on = Image.open(DIR / "assets" / "tray-icon-on.png")
    icon_off = Image.open(DIR / "assets" / "tray-icon-off.png")

    state = {"status": get_status(RUN_DIR, check_public=True), "checking": False}

    def current_ok():
        return overall_ok(state["status"])

    def label_status(item):
        return status_summary_text(state["status"])

    def on_reconnect(icon, item):
        state["checking"] = True
        icon.icon = icon_off
        icon.title = "Telecode - checking"
        ok = run_reconnect()
        state["status"] = get_status(RUN_DIR, check_public=True)
        state["checking"] = False
        refresh_icon(icon)
        if overall_ok(state["status"]):
            notify("✅ Đã kết nối lại — mini app trên điện thoại dùng được ngay.")
        elif ok:
            notify("⚠️ Đã restart service nhưng mini app vẫn chưa vào được — kiểm tra lại Tailscale.")
        else:
            notify("❌ Kết nối lại thất bại — xem logs/reconnect (chạy tay: bash scripts/reconnect.sh)")

    def on_open_vscode(icon, item):
        open_vscode()

    def on_quit(icon, item):
        icon.stop()

    def refresh_icon(icon):
        ok = current_ok()
        icon.icon = icon_on if ok else icon_off
        icon.title = title_ascii(ok)

    menu = pystray.Menu(
        pystray.MenuItem(label_status, None, enabled=False),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("🔄 Kết nối lại", on_reconnect),
        pystray.MenuItem("🖥️ Mở VS Code", on_open_vscode),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("❌ Thoát", on_quit),
    )

    icon = pystray.Icon(
        "telecode",
        icon=icon_on if current_ok() else icon_off,
        title=title_ascii(current_ok()),
        menu=menu,
    )

    def poll_loop():
        was_ok = current_ok()
        while True:
            time.sleep(POLL_INTERVAL_SEC)
            if state["checking"]:
                continue
            state["status"] = get_status(RUN_DIR, check_public=True)
            now_ok = current_ok()
            refresh_icon(icon)
            if now_ok != was_ok:
                notify("✅ Mini app hoạt động lại bình thường." if now_ok
                       else "⚠️ " + status_summary_text(state["status"]))
            was_ok = now_ok

    threading.Thread(target=poll_loop, daemon=True).start()
    icon.run()


if __name__ == "__main__":
    main()
