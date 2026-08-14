#!/usr/bin/env node
// Lệnh build duy nhất cho telecode — mirror k8sql/scripts/build-cross-platform.mjs, tự nhận diện
// OS hiện tại, build native cho đúng OS đó, thử cross-build Windows nếu khả thi. Khác k8sql: không
// có sidecar Windows (PyInstaller không cross-compile — xem CLAUDE.md), build Windows chỉ cross-
// compile phần vỏ Rust/Tauri, chạy trên WSL2 lúc runtime (CHƯA verify trên máy Windows thật).
//
// Cách dùng:
//   node scripts/build-cross-platform.mjs                  # mặc định theo OS hiện tại
//   node scripts/build-cross-platform.mjs --targets linux,windows

import { buildNative } from "./lib/build-native.mjs";
import { buildWindowsRustViaDocker } from "./lib/build-windows-cross.mjs";

const PLATFORM_ALIASES = { windows: "win32", macos: "darwin", linux: "linux" };

function parseTargets() {
  const idx = process.argv.indexOf("--targets");
  if (idx === -1 || idx + 1 >= process.argv.length) return null;
  return process.argv[idx + 1]
    .split(",")
    .map((t) => t.trim().toLowerCase())
    .map((t) => PLATFORM_ALIASES[t] || t);
}

function defaultTargetsFor(currentOS) {
  if (currentOS === "linux") return ["linux", "win32"];
  return [currentOS];
}

async function main() {
  const currentOS = process.platform;
  const targets = parseTargets() ?? defaultTargetsFor(currentOS);

  console.log(`[build] Máy hiện tại: ${currentOS}. Target sẽ build: ${targets.join(", ")}`);

  const results = {};

  for (const target of targets) {
    if (target === currentOS) {
      console.log(`\n[build] ── Native build cho ${target} ──`);
      results[target] = await buildNative({ platform: target });
      continue;
    }

    if (target === "win32" && currentOS === "linux") {
      console.log(`\n[build] ── Cross-build Windows từ Linux (chỉ vỏ Rust, không sidecar) ──`);
      try {
        results.win32 = await buildWindowsRustViaDocker();
      } catch (err) {
        console.error(`\n[build] ✗ Cross-build Windows LỖI: ${err.message}`);
        console.error(
          "[build] Hướng build KHÔNG chính thức — nếu lỗi, dùng máy/VM Windows thật hoặc CI runner " +
            "Windows thay vì cố sửa tiếp Docker (xem telecode/CLAUDE.md)."
        );
        results.win32 = { error: err.message };
      }
      continue;
    }

    if (target === "darwin") {
      console.warn(
        "\n[build] ⚠ Bỏ qua macOS — KHÔNG thể cross-build qua Docker (giới hạn Apple, không phải " +
          "thiếu cấu hình). Cần máy Mac thật hoặc CI runner macOS."
      );
      results.darwin = { skipped: true };
      continue;
    }

    console.warn(`\n[build] ⚠ Chưa hỗ trợ cross-build "${target}" từ ${currentOS}, bỏ qua.`);
    results[target] = { skipped: true };
  }

  console.log("\n[build] === Tổng kết ===");
  for (const [target, result] of Object.entries(results)) {
    if (result?.error) {
      console.log(`  ✗ ${target}: LỖI — ${result.error}`);
    } else if (result?.skipped) {
      console.log(`  ⚠ ${target}: bỏ qua`);
    } else {
      console.log(`  ✓ ${target}: ${result.files?.length ?? 0} file → ${result.distDir}`);
    }
  }

  const hasFailure = Object.values(results).some((r) => r?.error);
  process.exit(hasFailure ? 1 : 0);
}

main().catch((err) => {
  console.error("[build] Lỗi không mong đợi:", err);
  process.exit(1);
});
