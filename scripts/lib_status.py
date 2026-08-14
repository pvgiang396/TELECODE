"""
Logic kiểm tra trạng thái telecode (code-server/bot/tailscale/funnel) dùng chung
giữa wizard.py (probe_status cho UI cài đặt) và tray.py (poll cho system tray).
Tách ra từ wizard.py's probe_status() cũ — giữ nguyên các field/hành vi cũ, chỉ
thêm check_funnel_public_reachable() mới (curl thẳng URL public, tiêu chí HTTP
code giống hệt bước verify funnel trong setup.sh — không phải 000/502/503/504).

Field `tailscaleSelfOnline` (từ `tailscale status --json`'s `Self.Online`) —
bug thật đã gặp: `BackendState` có thể vẫn `"Running"` (chưa đăng xuất) trong
khi control-plane của `tailscaled` bị treo (thường do xung đột Cloudflare
WARP chạy song song — `warp-svc` làm gián đoạn kết nối tới
`controlplane.tailscale.com`, log thật thấy `control: map response long-poll
timed out!`), khiến server coi node này offline → Funnel relay không proxy
được về máy dù mọi service local vẫn chạy bình thường. Chỉ check
`BackendState != "Running"` (như code cũ) bỏ sót đúng trường hợp này — xem
`reconnect.sh` dùng field này để tự phục hồi.
"""
import json
import os
import shutil
import subprocess
from pathlib import Path
from urllib.parse import urlparse

# Bug thật đã gặp: máy chạy telecode có cài Tailscale -> resolver hệ thống
# (systemd-resolved/127.0.0.53) tự trả MagicDNS (IP nội bộ tailnet 100.x.x.x)
# cho mọi domain *.ts.net, KHÁC HẲN IP relay Funnel công khai mà 1 client
# ngoài tailnet (điện thoại không cài Tailscale) thực sự dùng -> check "public
# reachable" chạy trên chính máy này sẽ luôn PASS giả (false positive) dù
# đường đi internet thật đang lỗi. Phải ép resolve qua DNS resolver công khai,
# không tin resolver hệ thống, cho hostname *.ts.net.
_PUBLIC_DNS_RESOLVERS = ["1.1.1.1", "8.8.8.8"]


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


def _service_running(run_dir: Path, pidfile_name: str, service_name: str) -> tuple[bool, int]:
    running, pid = is_alive(run_dir / pidfile_name)
    if (Path.home() / f".config/systemd/user/{service_name}.service").exists():
        try:
            active = subprocess.run(
                ["systemctl", "--user", "is-active", service_name],
                capture_output=True, text=True, timeout=5,
            ).stdout.strip()
            running = active == "active"
            if running:
                pid = int(subprocess.run(
                    ["systemctl", "--user", "show", service_name, "-p", "MainPID", "--value"],
                    capture_output=True, text=True, timeout=5,
                ).stdout.strip() or 0)
        except Exception:
            pass
    return running, pid


def resolve_public_ip(hostname: str, timeout: int = 5) -> str:
    """dig qua resolver công khai (1.1.1.1/8.8.8.8), KHÔNG dùng resolver hệ
    thống — xem giải thích false-positive ở đầu file. Trả '' nếu không dò được
    (thiếu lệnh dig, timeout, NXDOMAIN...)."""
    if not shutil.which("dig"):
        return ""
    for resolver in _PUBLIC_DNS_RESOLVERS:
        try:
            out = subprocess.run(
                ["dig", f"@{resolver}", hostname, "+short", "+time=3", "+tries=1"],
                capture_output=True, text=True, timeout=timeout,
            ).stdout.strip()
        except Exception:
            continue
        for line in out.splitlines():
            line = line.strip()
            if line and line[0].isdigit():  # dòng đầu tiên là địa chỉ IPv4
                return line
    return ""


def check_funnel_public_reachable(url: str, timeout: int = 5) -> tuple[bool, int]:
    """Coi 'OK' khi HTTP code không phải 000/502/503/504 — đúng tiêu chí verify
    funnel đã dùng trong setup.sh (bước 4/5). 000 = không kết nối được
    (DNS/timeout/không dò được IP public). Ép `curl --resolve` vào đúng IP dò
    được qua DNS công khai thay vì để curl tự resolve qua resolver hệ thống
    (sẽ bị MagicDNS chi phối nếu chạy trên máy có cài Tailscale)."""
    if not url:
        return False, 0
    hostname = urlparse(url).hostname
    if not hostname:
        return False, 0
    ip = resolve_public_ip(hostname, timeout=timeout)
    if not ip:
        return False, 0
    try:
        code_str = subprocess.run(
            ["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}",
             "--max-time", str(timeout), "--resolve", f"{hostname}:443:{ip}", url],
            capture_output=True, text=True, timeout=timeout + 2,
        ).stdout.strip()
        code = int(code_str) if code_str.isdigit() else 0
    except Exception:
        code = 0
    ok = code not in (0, 502, 503, 504)
    return ok, code


def get_status(run_dir: Path, check_public: bool = True, project_dir: Path | None = None) -> dict:
    """Trả về dict trạng thái đầy đủ — format tương thích ngược với
    wizard.py's probe_status() cũ (giữ nguyên tên field), thêm 2 field mới
    funnelPubliclyReachable/funnelPublicHttpCode.

    project_dir — thư mục chứa config.yaml thật (nơi setup.sh/bot.py chạy). Mặc định
    `run_dir.parent` ĐÚNG cho CLI gốc (RUN_DIR = "$DIR/.run", DIR chính là project_dir) nhưng SAI ở
    bản Tauri — run_dir ở đó là `app_data_dir()/run`, KHÔNG nằm cạnh `app_data_dir()/source/
    config.yaml` — bug thật đã gặp: currentToken/currentOpenaiApiKey/currentGithubCopilotPat luôn
    đọc ra rỗng dù config.yaml có giá trị, khiến wizard tưởng "chưa cấu hình"/token bị mất. wizard.py
    (Tauri) phải truyền project_dir=dir_ tường minh; tray.py (CLI, chưa dùng trong Tauri) giữ nguyên
    hành vi cũ khi không truyền tham số này."""
    cs_config = Path.home() / ".config/code-server/config.yaml"
    project_root = project_dir if project_dir is not None else run_dir.parent
    project_config = project_root / "config.yaml"

    cs_installed = shutil.which("code-server") is not None
    cs_version = ""
    if cs_installed:
        try:
            cs_version = subprocess.run(
                ["code-server", "--version"], capture_output=True, text=True, timeout=5
            ).stdout.splitlines()[0]
        except Exception:
            cs_version = ""

    ts_installed = shutil.which("tailscale") is not None
    ts_version = ""
    ts_backend_state = ""
    ts_self_online = False
    if ts_installed:
        try:
            ts_version = subprocess.run(
                ["tailscale", "version"], capture_output=True, text=True, timeout=5
            ).stdout.splitlines()[0]
        except Exception:
            ts_version = ""

    cs_running, cs_pid = _service_running(run_dir, "code-server.pid", "code-server")
    bot_running, bot_pid = _service_running(run_dir, "bot.pid", "telecode-bot")

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
            ts_backend_state = st.get("BackendState", "")
            self_info = st.get("Self", {})
            ts_self_online = bool(self_info.get("Online", False))
            dns_name = self_info.get("DNSName", "").rstrip(".")
            if dns_name:
                tailscale_url = f"https://{dns_name}"
        except Exception:
            pass

    if not tailscale_url:
        tailscale_url = read_value(project_config, "VSCODE_PUBLIC_URL:")

    funnel_public_reachable = False
    funnel_public_http_code = 0
    if check_public and tailscale_url:
        funnel_public_reachable, funnel_public_http_code = check_funnel_public_reachable(tailscale_url)

    current_password = read_value(cs_config, "password:")
    current_token = read_value(project_config, "TELEGRAM_BOT_TOKEN:")
    if current_token == "YOUR_BOT_TOKEN_HERE":
        current_token = ""

    current_openai_key = read_value(project_config, "OPENAI_API_KEY:")
    if current_openai_key == "YOUR_OPENAI_API_KEY_HERE":
        current_openai_key = ""

    current_github_copilot_pat = read_value(project_config, "GITHUB_COPILOT_PAT:")
    if current_github_copilot_pat == "YOUR_GITHUB_COPILOT_PAT_HERE":
        current_github_copilot_pat = ""

    current_file_inbox_dir = read_value(project_config, "FILE_INBOX_DIR:")
    if not current_file_inbox_dir or current_file_inbox_dir == "/path/to/telecode/files":
        current_file_inbox_dir = str(project_root / "files")

    vscode_port = read_value(project_config, "VSCODE_PORT:") or "8443"

    return {
        "codeServerInstalled": cs_installed,
        "codeServerVersion": cs_version,
        "codeServerRunning": cs_running,
        "codeServerPid": cs_pid,
        "vscodePort": vscode_port,
        "tailscaleInstalled": ts_installed,
        "tailscaleVersion": ts_version,
        "tailscaleBackendState": ts_backend_state,
        "tailscaleSelfOnline": ts_self_online,
        "funnelConfigured": funnel_configured,
        "tailscaleUrl": tailscale_url,
        "funnelPubliclyReachable": funnel_public_reachable,
        "funnelPublicHttpCode": funnel_public_http_code,
        "botRunning": bot_running,
        "botPid": bot_pid,
        "currentPassword": current_password,
        "currentToken": current_token,
        "currentOpenaiApiKey": current_openai_key,
        "currentGithubCopilotPat": current_github_copilot_pat,
        "currentFileInboxDir": current_file_inbox_dir,
    }


def overall_ok(status: dict) -> bool:
    """1 boolean tổng dùng cho tray icon xanh/đỏ — mọi thành phần phải sống VÀ
    funnel phải thật sự truy cập được từ internet (không chỉ cấu hình đúng)."""
    return (
        status.get("codeServerRunning", False)
        and status.get("botRunning", False)
        and status.get("tailscaleBackendState") == "Running"
        and status.get("funnelConfigured", False)
        and status.get("funnelPubliclyReachable", False)
    )
