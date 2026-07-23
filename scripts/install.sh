#!/usr/bin/env bash
# Cài đặt nhanh telecode: clone repo rồi chạy setup.sh (cài code-server, cloudflared,
# mở 2 tunnel, hỏi Telegram Bot Token, khởi động bot) — xem telecode/CLAUDE.md để hiểu
# kiến trúc, hoặc README.md để biết chi tiết từng bước setup.sh làm.
#
# Chạy:
#   curl -fsSL https://gitlab.com/pvgiang396/telecode/-/raw/main/scripts/install.sh | bash
set -euo pipefail

REPO_URL="https://gitlab.com/pvgiang396/telecode.git"
INSTALL_DIR="${TELECODE_DIR:-$HOME/telecode}"

command -v git >/dev/null 2>&1 || { echo "Cần cài git trước."; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Cần cài Python 3 trước."; exit 1; }

if [ -d "$INSTALL_DIR/.git" ]; then
  echo "== Đã có sẵn, cập nhật $INSTALL_DIR =="
  git -C "$INSTALL_DIR" pull --ff-only
else
  echo "== Clone về $INSTALL_DIR =="
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"
exec bash setup.sh
