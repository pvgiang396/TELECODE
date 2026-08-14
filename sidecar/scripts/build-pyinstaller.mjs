#!/usr/bin/env node
// Build sidecar/dispatcher.py thành 1 binary "telecode-sidecar" bằng PyInstaller.
//
// LƯU Ý QUAN TRỌNG (đã ghi trong CLAUDE.md, không lặp lại chi tiết ở đây):
// PyInstaller KHÔNG cross-compile được — chỉ build ra binary đúng cho OS đang chạy
// lệnh này. Trên máy Linux, script này chỉ tạo ra binary Linux; sidecar cho Windows
// KHÔNG được build ở đây — trên Windows, telecode gọi qua WSL2 (xem
// src-tauri/src/wsl_bridge.rs), tái dùng đúng 1 binary Linux này bên trong WSL2.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const SIDECAR_DIR = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const PROJECT_ROOT = path.dirname(SIDECAR_DIR);
const VENV_DIR = path.join(SIDECAR_DIR, '.buildvenv');
const DIST_DIR = path.join(SIDECAR_DIR, 'dist');

const isWindows = process.platform === 'win32';
const venvPython = path.join(VENV_DIR, isWindows ? 'Scripts\\python.exe' : 'bin/python3');
const venvPyinstaller = path.join(VENV_DIR, isWindows ? 'Scripts\\pyinstaller.exe' : 'bin/pyinstaller');

function run(cmd, args, opts = {}) {
  console.log(`> ${cmd} ${args.join(' ')}`);
  execFileSync(cmd, args, { stdio: 'inherit', cwd: SIDECAR_DIR, ...opts });
}

function ensureVenv() {
  if (!existsSync(venvPython)) {
    run(process.platform === 'win32' ? 'python' : 'python3', ['-m', 'venv', VENV_DIR]);
  }
  run(venvPython, ['-m', 'pip', 'install', '-q', '--upgrade', 'pip']);
  run(venvPython, ['-m', 'pip', 'install', '-q', '-r', path.join(SIDECAR_DIR, 'requirements.txt')]);
}

// bot.py/wizard.py/lib_status.py không được `import` tĩnh trong dispatcher.py (lý do:
// xem docstring dispatcher.py) — PyInstaller vì vậy không tự dò ra dependency của
// chúng, phải khai báo tay đúng những gì các file .py THẬT đó import ở đầu file.
const HIDDEN_IMPORTS = [
  'yaml',
  'dotenv',
  'aiohttp',
  'telegram',
  'telegram.ext',
  'telegram.constants',
  // Submodule "chấm" của stdlib (http.server, urllib.parse...) — PyInstaller chỉ tự dò được qua
  // static analysis của statement `import`, nhưng dispatcher.py không `import` tĩnh bot.py/
  // wizard.py/lib_status.py (chạy qua runpy — xem dispatcher.py) nên các submodule này bị bỏ sót
  // dù bản thân chúng thuộc stdlib. Bug thật đã gặp + fix: thiếu 'http.server' khiến wizard.py crash
  // ngay dòng import đầu tiên lúc chạy trong binary đã đóng gói (chạy trực tiếp bằng `python3
  // wizard.py` không lộ ra vì đó không đi qua PyInstaller).
  'http.server',
  'urllib.parse',
];

function buildBinary() {
  rmSync(path.join(SIDECAR_DIR, 'build'), { recursive: true, force: true });
  const binaryName = isWindows ? 'telecode-sidecar.exe' : 'telecode-sidecar';
  const args = [
    '--onefile',
    '--name',
    'telecode-sidecar',
    '--distpath',
    DIST_DIR,
    '--workpath',
    path.join(SIDECAR_DIR, 'build', 'work'),
    '--specpath',
    path.join(SIDECAR_DIR, 'build', 'spec'),
  ];
  for (const mod of HIDDEN_IMPORTS) {
    args.push('--hidden-import', mod);
  }
  args.push(path.join(SIDECAR_DIR, 'dispatcher.py'));
  run(venvPyinstaller, args);
  const built = path.join(DIST_DIR, binaryName);
  if (!existsSync(built)) {
    throw new Error(`PyInstaller không tạo ra file mong đợi: ${built}`);
  }
  console.log(`✅ Sidecar built: ${built}`);
  return built;
}

mkdirSync(DIST_DIR, { recursive: true });
ensureVenv();
const builtPath = buildBinary();

export { builtPath, PROJECT_ROOT, DIST_DIR };
