"""Helpers để load environment từ ~/.codex/auth.json và config.yaml"""
import json
import os
from pathlib import Path


def load_openai_api_key() -> str | None:
    """Lấy OPENAI_API_KEY từ:
    1. Environment variable (nếu có)
    2. ~/.codex/auth.json (fallback)
    Trả về token hoặc None nếu không tìm thấy
    """
    # 1. Check env var trước
    if token := os.environ.get("OPENAI_API_KEY"):
        return token.strip() or None

    # 2. Fallback: đọc từ ~/.codex/auth.json
    try:
        auth_file = Path.home() / ".codex" / "auth.json"
        if auth_file.exists():
            auth_data = json.loads(auth_file.read_text())
            if token := auth_data.get("OPENAI_API_KEY", "").strip():
                return token
    except Exception:
        pass

    return None


def prepare_env_for_codex() -> dict:
    """Trả về dict env cho subprocess.Popen/run khi spawn codex.
    Bao gồm OPENAI_API_KEY từ ~/.codex/auth.json nếu cần."""
    env = dict(os.environ)
    if "OPENAI_API_KEY" not in env:
        if token := load_openai_api_key():
            env["OPENAI_API_KEY"] = token
    return env
