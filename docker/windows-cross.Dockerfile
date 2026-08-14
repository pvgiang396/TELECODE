# Cross-compile Tauri/Rust cho Windows TỪ Linux — hướng KHÔNG CHÍNH THỨC (Tauri khuyến nghị build
# native trên Windows thật hoặc CI runner Windows), dùng target GNU (`x86_64-pc-windows-gnu`) thay
# vì MSVC (target MSVC không cross-compile được từ Linux — cần Visual Studio Build Tools thật).
# Copy gần verbatim từ k8sql/docker/windows-cross.Dockerfile — cùng rủi ro/gotcha, xem
# telecode/CLAUDE.md. KHÔNG build sidecar Python ở đây (PyInstaller không cross-compile — xem
# CLAUDE.md), image này chỉ compile phần vỏ Rust/Tauri.
FROM rust:1-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc-mingw-w64-x86-64 \
    nsis \
    curl \
    ca-certificates \
    libayatana-appindicator3-dev \
    && rm -rf /var/lib/apt/lists/*
# libayatana-appindicator3-dev: bug thật đã gặp ở k8sql (xem k8sql/CLAUDE.md) — `cargo tauri build`
# (tray-icon feature) tự kiểm tra thư viện appindicator trên HOST build (container Linux này) dù
# target là Windows — thiếu package này khiến build panic "Can't detect any appindicator library"
# ngay cả khi cross-build cho Windows.

RUN rustup target add x86_64-pc-windows-gnu

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN cargo install tauri-cli --locked --version "^2"

WORKDIR /work
