#!/usr/bin/env python3
"""Remove abandoned Codex thread-writer lock files without touching live writers."""

import fcntl
import os
from pathlib import Path


def cleanup_codex_writer_locks(codex_home: Path | None = None) -> list[str]:
    home = codex_home or Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    lock_dir = home / "thread-writer-locks"
    removed: list[str] = []
    if not lock_dir.is_dir():
        return removed

    for lock_path in lock_dir.glob("*.lock"):
        if lock_path.name == ".coordination.lock":
            continue
        try:
            with lock_path.open("a+") as lock_file:
                try:
                    fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    continue
                lock_path.unlink(missing_ok=True)
                removed.append(lock_path.name)
        except (FileNotFoundError, PermissionError, OSError):
            continue
    return removed


if __name__ == "__main__":
    for name in cleanup_codex_writer_locks():
        print(f"[telecode] removed abandoned Codex writer lock: {name}")
