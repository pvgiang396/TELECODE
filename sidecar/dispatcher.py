#!/usr/bin/env python3
"""Entrypoint đóng gói bởi PyInstaller thành 1 binary (`telecode-sidecar`).

QUAN TRỌNG: file này KHÔNG import bot.py/wizard.py bằng `import` tĩnh — nếu làm
vậy, PyInstaller sẽ đóng băng (freeze) 2 module đó vào bundle, khiến biến
module-level `Path(__file__).parent` bên trong bot.py/wizard.py (dùng để tìm
config.yaml/.env/state.json) trỏ vào thư mục tạm giải nén của PyInstaller
(`sys._MEIPASS`) thay vì thư mục cài đặt thật — tương đương bug `__dirname`
mà k8sql từng gặp khi đóng gói k8sctl bằng Node SEA.

Thay vào đó: bot.py/wizard.py/scripts/*.py vẫn là các file .py THẬT nằm trên đĩa
(deploy kèm theo, không đóng gói vào binary) — dispatcher dùng `runpy.run_path()`
để chạy đúng file thật đó, giữ `__file__` trỏ đúng vị trí thật. Binary PyInstaller
chỉ đóng vai trò "mang theo sẵn 1 Python interpreter + toàn bộ pip dependency"
(pyyaml/python-telegram-bot/python-dotenv...) — không cần cài venv tay nữa.

Vì bot.py/wizard.py không được `import` tĩnh, PyInstaller không tự dò ra
dependency của chúng — khai báo thủ công qua --hidden-import trong
scripts/build-pyinstaller.mjs (không sửa ở đây).

Usage:
    telecode-sidecar bot <path-to-bot.py>
    telecode-sidecar wizard-server <path-to-wizard.py> <RUN_DIR> <DIR> [caller_pid]
    telecode-sidecar status <path-to-scripts-dir-chứa-lib_status.py>
    telecode-sidecar reconnect <path-to-reconnect.sh>
"""
import runpy
import subprocess
import sys
from pathlib import Path


def _run_script(script_path: str, argv_rest: list[str]) -> None:
    """Chạy 1 file .py thật trên đĩa với __file__/sys.argv như thể gọi trực tiếp
    `python3 script_path argv_rest...` — giữ nguyên mọi Path(__file__).parent bên
    trong file gốc."""
    path = Path(script_path).resolve()
    if not path.is_file():
        print(f"Không tìm thấy file: {path}", file=sys.stderr)
        sys.exit(1)
    sys.argv = [str(path), *argv_rest]
    runpy.run_path(str(path), run_name="__main__")


def cmd_bot(args: list[str]) -> None:
    if not args:
        print("Usage: telecode-sidecar bot <path-to-bot.py>", file=sys.stderr)
        sys.exit(1)
    _run_script(args[0], [])


def cmd_wizard_server(args: list[str]) -> None:
    if len(args) < 3:
        print(
            "Usage: telecode-sidecar wizard-server <path-to-wizard.py> <RUN_DIR> <DIR> [caller_pid]",
            file=sys.stderr,
        )
        sys.exit(1)
    script_path, run_dir, dir_ = args[0], args[1], args[2]
    caller_pid = args[3] if len(args) > 3 else ""
    extra = [run_dir, dir_] + ([caller_pid] if caller_pid else [])
    _run_script(script_path, extra)


def cmd_status(args: list[str]) -> None:
    """In JSON trạng thái qua lib_status.get_status() — dùng cho Rust tray poll."""
    if len(args) < 2:
        print(
            "Usage: telecode-sidecar status <path-to-scripts-dir> <RUN_DIR> [--no-check-public]",
            file=sys.stderr,
        )
        sys.exit(1)
    scripts_dir = Path(args[0]).resolve()
    run_dir = Path(args[1]).resolve()
    check_public = "--no-check-public" not in args[2:]
    sys.path.insert(0, str(scripts_dir))
    from lib_status import get_status  # type: ignore  # noqa: E402

    import json

    print(json.dumps(get_status(run_dir, check_public=check_public), ensure_ascii=False))


def cmd_reconnect(args: list[str]) -> None:
    if not args:
        print("Usage: telecode-sidecar reconnect <path-to-reconnect.sh>", file=sys.stderr)
        sys.exit(1)
    result = subprocess.run(["bash", args[0]])
    sys.exit(result.returncode)


COMMANDS = {
    "bot": cmd_bot,
    "wizard-server": cmd_wizard_server,
    "status": cmd_status,
    "reconnect": cmd_reconnect,
}


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(f"Usage: telecode-sidecar <{'|'.join(COMMANDS)}> [args...]", file=sys.stderr)
        sys.exit(1)
    COMMANDS[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    main()
