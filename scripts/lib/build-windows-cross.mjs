// Cross-build Windows TỪ Linux — KHÁC HẲN k8sql: PyInstaller không cross-compile được (không có
// tương đương "postject tiêm blob trên Linux" cho Python), nên KHÔNG có bước build sidecar Windows
// ở đây. Chỉ cross-compile phần vỏ Rust/Tauri (không khai externalBin nào — trên Windows,
// telecode gọi wsl.exe thay vì .sidecar(), xem src-tauri/src/wsl_bridge.rs + CLAUDE.md mục
// "Windows/WSL2 — provisional, CHƯA verify trên máy Windows thật").

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.dirname(path.dirname(path.dirname(fileURLToPath(import.meta.url))));

const DOCKER_IMAGE_TAG = "telecode-windows-cross";
const WIN_TARGET_TRIPLE = "x86_64-pc-windows-gnu";

function ensureDockerImage() {
  console.log(`\n[build-windows-cross] docker build -t ${DOCKER_IMAGE_TAG} (lần đầu có thể mất vài phút)...`);
  execFileSync(
    "docker",
    ["build", "-t", DOCKER_IMAGE_TAG, "-f", path.join(REPO_ROOT, "docker", "windows-cross.Dockerfile"), REPO_ROOT],
    { stdio: "inherit" }
  );
}

export async function buildWindowsRustViaDocker() {
  console.log(
    `\n[build-windows-cross] === Cross-compile Tauri/Rust cho Windows qua Docker (RỦI RO CAO, thử nghiệm, CHƯA verify trên Windows thật) ===`
  );

  ensureDockerImage();

  const cargoRegistryVolume = "telecode-windows-cross-cargo-registry";
  const cargoTargetVolume = "telecode-windows-cross-target";
  const userInfo = os.userInfo();

  // Named volume mới kế thừa ownership root từ image — chown trước mỗi lần build (idempotent, xem
  // giải thích gốc trong k8sql/CLAUDE.md). Bug thật đã tự gặp KHÁC k8sql: dùng image `alpine` (như
  // k8sql) để chown tại path tạm /reg,/tgt KHÔNG đủ — Docker chỉ "populate volume rỗng từ nội dung
  // image" tại ĐÚNG path mount lần đầu gặp path đó; alpine không có sẵn /usr/local/cargo/registry
  // nên chown ở /reg không đụng gì, rồi khi build container (rust:1-bookworm, CÓ sẵn thư mục đó)
  // mount cùng volume vào /usr/local/cargo/registry lần đầu, Docker mới copy nội dung image (root-
  // owned) vào — XẢY RA SAU chown, ghi đè mất kết quả chown. Fix: chown bằng CHÍNH image build
  // (đã có sẵn cấu trúc thư mục cargo) tại ĐÚNG path sẽ dùng thật, để việc "populate từ image" xảy
  // ra TRƯỚC hoặc CÙNG lúc chown, không phải sau.
  execFileSync(
    "docker",
    [
      "run",
      "--rm",
      "-v",
      `${cargoRegistryVolume}:/usr/local/cargo/registry`,
      "-v",
      `${cargoTargetVolume}:/work/src-tauri/target`,
      DOCKER_IMAGE_TAG,
      "chown",
      "-R",
      `${userInfo.uid}:${userInfo.gid}`,
      "/usr/local/cargo/registry",
      "/work/src-tauri/target",
    ],
    { stdio: "inherit" }
  );

  const distDir = path.join(REPO_ROOT, "dist", "windows-x64");
  fs.rmSync(distDir, { recursive: true, force: true });
  fs.mkdirSync(distDir, { recursive: true });

  console.log("[build-windows-cross] docker run cargo tauri build --target " + WIN_TARGET_TRIPLE + " ...");
  const bundleDirInContainer = `/work/src-tauri/target/${WIN_TARGET_TRIPLE}/release/bundle/nsis`;
  execFileSync(
    "docker",
    [
      "run",
      "--rm",
      "--user",
      `${userInfo.uid}:${userInfo.gid}`,
      "-v",
      `${REPO_ROOT}:/work`,
      "-v",
      `${cargoRegistryVolume}:/usr/local/cargo/registry`,
      "-v",
      `${cargoTargetVolume}:/work/src-tauri/target`,
      "-e",
      "HOME=/tmp",
      "-w",
      "/work/src-tauri",
      DOCKER_IMAGE_TAG,
      "sh",
      "-c",
      // KHÔNG truyền --config externalBin ở đây — build Windows không có sidecar bundle (xem đầu file).
      `cargo tauri build --target ${WIN_TARGET_TRIPLE} --bundles nsis && mkdir -p /work/dist/windows-x64 && cp ${bundleDirInContainer}/*.exe /work/dist/windows-x64/`,
    ],
    { stdio: "inherit" }
  );

  const copied = fs.existsSync(distDir)
    ? fs
        .readdirSync(distDir)
        .map((entry) => path.join(distDir, entry))
        .filter((p) => fs.statSync(p).isFile())
    : [];

  if (copied.length === 0) {
    throw new Error(
      `[build-windows-cross] Docker build "thành công" nhưng không thấy file cài đặt nào ở ${distDir} — kiểm tra log Docker phía trên.`
    );
  }

  console.log(`[build-windows-cross] Xong. File đã copy vào ${distDir}:`);
  for (const f of copied) console.log(`  - ${f}`);
  return { distDir, files: copied };
}
