// Build native cho ĐÚNG OS đang chạy script này — khác k8sql (SEA Node), sidecar ở đây là
// PyInstaller (KHÔNG cross-compile được, xem CLAUDE.md) nên buildNative() chỉ thật sự dùng được
// khi platform === "linux" trên máy dev hiện tại (chưa có máy macOS/Windows thật để tự verify
// nhánh đó — xem CLAUDE.md mục "Windows/WSL2 — provisional").

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { buildEnvWithRustToolchain, runRustTriple } from "./env.mjs";

const REPO_ROOT = path.dirname(path.dirname(path.dirname(fileURLToPath(import.meta.url))));
const SIDECAR_DIR = path.join(REPO_ROOT, "sidecar");
const SRC_TAURI_DIR = path.join(REPO_ROOT, "src-tauri");

const DIST_DIR_NAME_BY_PLATFORM = {
  linux: "linux-x64",
  darwin: "darwin-arm64",
  win32: "windows-x64",
};

export async function buildNative({ platform = process.platform } = {}) {
  if (platform !== process.platform) {
    throw new Error(
      `buildNative() chỉ build ĐÚNG platform đang chạy (${process.platform}), không tự cross-build ${platform}.`
    );
  }

  console.log(`\n[build-native] === Bước 1/4: build sidecar Python (PyInstaller) ===`);
  execFileSync("node", [path.join(SIDECAR_DIR, "scripts", "build-pyinstaller.mjs")], {
    cwd: SIDECAR_DIR,
    stdio: "inherit",
  });

  const env = buildEnvWithRustToolchain();
  const triple = runRustTriple();
  const sidecarBinaryName = platform === "win32" ? "telecode-sidecar.exe" : "telecode-sidecar";
  const sidecarBinarySrc = path.join(SIDECAR_DIR, "dist", sidecarBinaryName);
  const binariesDir = path.join(SRC_TAURI_DIR, "binaries");
  fs.mkdirSync(binariesDir, { recursive: true });
  const sidecarBinaryDest = path.join(
    binariesDir,
    `telecode-sidecar-${triple}${platform === "win32" ? ".exe" : ""}`
  );

  console.log(`\n[build-native] === Bước 2/4: copy sidecar binary -> ${sidecarBinaryDest} ===`);
  fs.copyFileSync(sidecarBinarySrc, sidecarBinaryDest);
  if (platform !== "win32") fs.chmodSync(sidecarBinaryDest, 0o755);

  // externalBin KHÔNG khai trong tauri.conf.json base (Windows build không có sidecar Windows —
  // xem CLAUDE.md) — tiêm qua --config CHỈ cho build native (Linux/macOS thật có sidecar riêng).
  const configOverride = JSON.stringify({
    bundle: { externalBin: ["binaries/telecode-sidecar"] },
  });
  const bundles = platform === "win32" ? "nsis,msi" : platform === "darwin" ? "dmg" : "deb";
  console.log(`\n[build-native] === Bước 3/4: cargo tauri build --bundles ${bundles} ===`);
  execFileSync(
    "npx",
    ["tauri", "build", "--bundles", bundles, "--config", configOverride],
    { cwd: SRC_TAURI_DIR, stdio: "inherit", env }
  );

  console.log(`\n[build-native] === Bước 4/4: copy artifact ra dist/ ===`);
  const distSubdir = DIST_DIR_NAME_BY_PLATFORM[platform];
  const distDir = path.join(REPO_ROOT, "dist", distSubdir);
  fs.rmSync(distDir, { recursive: true, force: true });
  fs.mkdirSync(distDir, { recursive: true });

  const bundleRoot = path.join(SRC_TAURI_DIR, "target", "release", "bundle");
  const copied = [];
  for (const kind of fs.existsSync(bundleRoot) ? fs.readdirSync(bundleRoot) : []) {
    const kindDir = path.join(bundleRoot, kind);
    if (!fs.statSync(kindDir).isDirectory()) continue;
    for (const entry of fs.readdirSync(kindDir)) {
      const entryPath = path.join(kindDir, entry);
      if (fs.statSync(entryPath).isFile()) {
        const dest = path.join(distDir, entry);
        fs.copyFileSync(entryPath, dest);
        copied.push(dest);
      }
    }
  }

  console.log(`[build-native] Xong. File đã copy vào ${distDir}:`);
  for (const f of copied) console.log(`  - ${f}`);

  return { distDir, files: copied };
}
