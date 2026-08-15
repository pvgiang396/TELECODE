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
import { dispatchGithubBuild } from "./lib/github-actions.mjs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PLATFORM_ALIASES = { windows: "win32", macos: "darwin", linux: "linux" };
const REPO_ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const PLATFORM_OPTIONS = [
  { value: "win32", label: "Windows" },
  { value: "linux", label: "Linux" },
  { value: "darwin", label: "macOS desktop" },
  { value: "android", label: "Android" },
  { value: "ios", label: "iOS" },
];

function parseExplicitTargets() {
  const idx = process.argv.indexOf("--targets");
  if (idx === -1 || idx + 1 >= process.argv.length) return null;
  return process.argv[idx + 1].split(",").map((target) => target.trim().toLowerCase()).map((target) => PLATFORM_ALIASES[target] || target);
}

function renderTargetPicker(cursor, selected) {
  process.stdout.write("\x1b[2J\x1b[H");
  console.log("telecode - Chọn nền tảng cần build");
  console.log("Dùng ↑/↓ để di chuyển, Space để chọn/bỏ chọn, Enter để bắt đầu, Q để thoát.\n");
  for (const [index, option] of PLATFORM_OPTIONS.entries()) {
    console.log(`${index === cursor ? "❯" : " "} [${selected.has(option.value) ? "x" : " "}] ${option.label}`);
  }
}

async function selectTargetsInteractively() {
  if (!process.stdin.isTTY || !process.stdout.isTTY) return defaultTargetsFor(process.platform);
  const selected = new Set(PLATFORM_OPTIONS.map((option) => option.value));
  let cursor = 0;
  renderTargetPicker(cursor, selected);
  process.stdin.setRawMode(true);
  process.stdin.resume();
  process.stdin.setEncoding("utf8");
  return new Promise((resolve, reject) => {
    const cleanup = () => {
      process.stdin.setRawMode(false);
      process.stdin.pause();
      process.stdin.removeListener("data", onData);
      process.stdout.write("\n");
    };
    const onData = (input) => {
      if (input === "\u0003" || input.toLowerCase() === "q") {
        cleanup();
        reject(new Error("Đã hủy build."));
        return;
      }
      if (input === "\u001b[A" || input === "k") cursor = (cursor + PLATFORM_OPTIONS.length - 1) % PLATFORM_OPTIONS.length;
      else if (input === "\u001b[B" || input === "j") cursor = (cursor + 1) % PLATFORM_OPTIONS.length;
      else if (input === " ") {
        const value = PLATFORM_OPTIONS[cursor].value;
        if (selected.has(value)) selected.delete(value); else selected.add(value);
      } else if (input === "\r" || input === "\n") {
        if (selected.size === 0) return;
        const targets = PLATFORM_OPTIONS.filter((option) => selected.has(option.value)).map((option) => option.value);
        cleanup();
        resolve(targets);
        return;
      }
      renderTargetPicker(cursor, selected);
    };
    process.stdin.on("data", onData);
  });
}

function defaultTargetsFor(currentOS) {
  if (currentOS === "linux") return ["linux", "win32"];
  return [currentOS];
}

async function main() {
  const currentOS = process.platform;
  const targets = parseExplicitTargets() ?? (await selectTargetsInteractively());

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
      console.log("\n[build] ── Dispatch GitHub Actions macOS desktop ──");
      results.darwin = dispatchGithubBuild({ projectRoot: REPO_ROOT, targets: ["macos"] });
      continue;
    }

    if (target === "android" || target === "ios") {
      console.log(`\n[build] ── Dispatch GitHub Actions ${target} ──`);
      results[target] = dispatchGithubBuild({ projectRoot: REPO_ROOT, targets: [target] });
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
