#!/usr/bin/env python3
"""
Sinh 2 icon tray (xanh/đỏ) từ assets/icon.png — theo đúng convention "mọi file
raster derive từ icon.png, không vẽ tay/render lại từ SVG mỗi lần" (xem CLAUDE.md
mục "Nguồn icon"). Chạy 1 lần khi cần tạo/regen (không tự động gọi trong
setup.sh — 2 file output commit thẳng vào repo như các asset khác).

Output: assets/tray-icon-on.png (chấm xanh), assets/tray-icon-off.png (chấm đỏ).
"""
from pathlib import Path
from PIL import Image, ImageDraw

ASSETS = Path(__file__).parent
SRC = ASSETS / "icon.png"


def make(dot_color: tuple[int, int, int, int], out_name: str):
    base = Image.open(SRC).convert("RGBA")
    size = base.size[0]
    dot_r = int(size * 0.20)
    cx, cy = size - dot_r, size - dot_r
    draw = ImageDraw.Draw(base)
    # viền trắng quanh chấm để nổi bật trên icon nền tối/sáng bất kỳ của panel tray.
    border_r = int(dot_r * 1.18)
    draw.ellipse((cx - border_r, cy - border_r, cx + border_r, cy + border_r), fill=(255, 255, 255, 255))
    draw.ellipse((cx - dot_r, cy - dot_r, cx + dot_r, cy + dot_r), fill=dot_color)
    base.save(ASSETS / out_name)
    print(f"wrote {ASSETS / out_name}")


if __name__ == "__main__":
    make((46, 204, 113, 255), "tray-icon-on.png")   # xanh lá — hoạt động bình thường
    make((231, 76, 60, 255), "tray-icon-off.png")    # đỏ — ngắt kết nối/cần sửa
