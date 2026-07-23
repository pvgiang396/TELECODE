#!/usr/bin/env bash
#
# Sao lưu cấu hình AI CLI tool (Claude Code / GitHub Copilot / Gemini CLI / DeepSeek)
# thành 1 file .tar.gz.gpg mã hoá AES256 — dùng bởi lệnh /backup_configs trong bot.py.
#
# Passphrase đọc qua STDIN (KHÔNG qua argv) — tránh lộ qua `ps aux` cho user khác
# nếu máy nhiều người dùng chung.
#
# Usage: echo "<passphrase>" | bash backup-ai-configs.sh <output-file.gpg>

set -euo pipefail
OUT="${1:?Usage: backup-ai-configs.sh <output.gpg> (passphrase qua stdin)}"

FILES=()
add_if_exists() { [ -e "$1" ] && FILES+=("$1"); }

# Claude Code
add_if_exists "$HOME/.claude/settings.json"
add_if_exists "$HOME/.claude/.credentials.json"
add_if_exists "$HOME/.claude.json"
# GitHub Copilot (gh CLI)
add_if_exists "$HOME/.config/gh/hosts.yml"
add_if_exists "$HOME/.config/gh/config.yml"
add_if_exists "$HOME/.config/github-copilot/oauth.json"
add_if_exists "$HOME/.config/github-copilot/apps.json"
add_if_exists "$HOME/.config/github-copilot/versions.json"
add_if_exists "$HOME/.config/github-copilot/auth.db"
# Gemini CLI
add_if_exists "$HOME/.gemini/oauth_creds.json"
add_if_exists "$HOME/.gemini/settings.json"
add_if_exists "$HOME/.gemini/google_accounts.json"
add_if_exists "$HOME/.gemini/installation_id"
# DeepSeek — không có CLI login riêng, chỉ 1 file env nếu user tự tạo
add_if_exists "$HOME/.telecode-deepseek.env"

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "Không tìm thấy file cấu hình AI tool nào trên máy này (chưa đăng nhập claude/gh copilot/gemini?)." >&2
    exit 1
fi

TMP_TAR="$(mktemp --suffix=.tar.gz)"
cleanup() { shred -u "$TMP_TAR" 2>/dev/null || rm -f "$TMP_TAR"; }
trap cleanup EXIT

# Giữ path tương đối từ $HOME (-C "$HOME") để giải nén lại đúng vị trí ở máy đích.
REL_FILES=()
for f in "${FILES[@]}"; do REL_FILES+=("${f#"$HOME"/}"); done
tar -czf "$TMP_TAR" -C "$HOME" "${REL_FILES[@]}"

# --passphrase-fd 0: đọc passphrase từ stdin, không hiện trong `ps aux`/argv.
gpg --batch --yes --symmetric --cipher-algo AES256 --passphrase-fd 0 -o "$OUT" "$TMP_TAR"

echo "Đã tạo $OUT (${#FILES[@]} file: ${FILES[*]})"
