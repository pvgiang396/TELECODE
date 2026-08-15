# telecode — AI Reference

> File này tự đủ để hiểu kiến trúc telecode và tiếp tục triển khai.

**2026-08-14 — hợp nhất gói đóng gói Tauri vào repo gốc:** bản đóng gói Tauri (phát triển song song
từ 2026-08-13 trong thư mục riêng, tên tạm `televscode`) đã hợp nhất làm nội dung chính thức của
repo `telecode` (git history gốc của `telecode` — Python/Flask thuần, không có gói cài đặt desktop —
được giữ nguyên, nội dung Tauri đè lên làm commit mới). Từ nay **chỉ còn 1 project tên `telecode`**
trong workspace, không còn thư mục/tên gọi tạm ở trên.

## Vai trò

telecode là bản đóng gói desktop-app thật (Tauri, cài đặt 1 click) + app Android riêng, mở VS Code
(code-server) từ xa qua Tailscale Funnel. Kế thừa **gần như nguyên vẹn** toàn bộ business logic
Python/Bash gốc (`wizard.py`, `setup.sh`, `scripts/lib_status.py`, `scripts/reconnect.sh`) — chỉ đổi
lớp vỏ cài đặt/khởi chạy, theo đúng pattern đã dùng khi chuyển `k8sctl` → [`k8sql`](../k8sql/CLAUDE.md).
Đã dọn sạch toàn bộ subsystem bot Telegram/Mini App cũ (không còn dùng) — xem mục "Dọn dẹp bot
Telegram" gần cuối file.

## Khác biệt kiến trúc so với k8sql (đọc trước khi sửa)

k8sql wrap 1 backend Node.js bằng SEA (Single Executable Application) sidecar — cross-compile được
từ Linux sang Windows (`postject` chỉ thao tác byte, không phụ thuộc `process.platform`). telecode
là **Python + Bash**, không có tương đương — dẫn tới 2 khác biệt cốt lõi:

1. **Sidecar Python đóng gói bằng PyInstaller, KHÔNG cross-compile được** — chỉ build ra binary
   đúng cho OS đang chạy lệnh build. Sidecar Linux chỉ build được TRÊN Linux.
2. **Windows KHÔNG có sidecar Python riêng** — thay vào đó gọi qua `wsl.exe`, tái dùng ĐÚNG binary
   Linux đã build, chạy BÊN TRONG WSL2 (`src-tauri/src/wsl_bridge.rs`). Đây không phải hạn chế mới:
   telecode gốc trên Windows *vốn đã* yêu cầu WSL2 (`install.ps1` tự cài WSL2 rồi chạy toàn bộ
   `setup.sh` bên trong đó, vì code-server chưa từng chạy native Windows).

## Kiến trúc

```
telecode/
├── package.json                  # orchestrator: "build": "node scripts/build-cross-platform.mjs"
├── scripts/
│   ├── build-cross-platform.mjs  # mirror k8sql — tự nhận diện OS, build native + thử cross Windows
│   └── lib/{env.mjs, build-native.mjs, build-windows-cross.mjs}
├── docker/windows-cross.Dockerfile  # Rust+mingw+nsis, KHÔNG build sidecar (xem trên)
├── sidecar/
│   ├── dispatcher.py              # entrypoint PyInstaller đóng gói — xem docstring, giải thích
│   │                              #   TẠI SAO không `import` tĩnh wizard.py
│   ├── requirements.txt           # deps để PyInstaller bundle (khớp deps thật wizard.py dùng)
│   └── scripts/build-pyinstaller.mjs
├── wizard.py, setup.sh, scripts/, assets/, requirements.txt, tray.py
│                                  # NGUYÊN VẸN từ telecode — KHÔNG sửa nghiệp vụ (1 ngoại lệ nhỏ,
│                                  #   xem "Thay đổi tối thiểu" bên dưới). tray.py không dùng nữa
│                                  #   (Tauri có tray native) nhưng giữ lại tham khảo.
├── src-tauri/
│   ├── src/{main.rs, sidecar.rs, wsl_bridge.rs}
│   ├── binaries/                  # sidecar Linux đã build, đặt tên theo target-triple
│   ├── frontend-placeholder/      # frontendDist rỗng — KHÔNG dùng lúc runtime, chỉ thoả yêu cầu
│   │                              #   config Tauri (cửa sổ thật load qua WebviewUrl::External)
│   ├── tauri.conf.json            # KHÔNG khai externalBin ở đây (xem "Vì sao không externalBin
│   │                              #   trong base config" bên dưới)
│   └── icons/                     # sinh từ assets/icon.png qua `npx tauri icon`
```

## Cách hoạt động lúc chạy (đã tự verify trên Linux, xem "Đã verify" bên dưới)

1. `main.rs` tạo tray (Open/Exit) + copy `bundle.resources` (wizard.py/setup.sh/scripts/assets,
   khai trong `tauri.conf.json`) từ vị trí chỉ-đọc (vd `/usr/lib/telecode/src/` trên
   `.deb` đã cài) sang `app_data_dir()/source` (ghi được) — lần đầu copy toàn bộ, các lần sau tái
   dùng bản copy này NHƯNG tự đồng bộ lại nếu version bundle đổi (xem "Cơ chế versioning cache +
   tính năng Cập nhật ứng dụng" bên dưới) (`resolve_writable_source_dir()`). Lý do bắt buộc: `setup.sh`
   cần ghi `config.yaml`/`.env`/`venv/` NGAY CẠNH chính nó, không ghi được vào thư mục root-owned.
2. Spawn sidecar `wizard-server <path-tới-wizard.py-thật> <RUN_DIR> <DIR>` — dispatcher.py chạy
   `wizard.py` qua `runpy.run_path()` (KHÔNG `import` tĩnh — xem lý do trong dispatcher.py) để
   `Path(__file__).parent` bên trong wizard.py trỏ ĐÚNG vị trí thật, không trỏ vào thư mục tạm giải
   nén PyInstaller (`sys._MEIPASS`) — cùng lớp bug k8sql từng gặp với `__dirname` trong Node SEA.
3. Đợi cổng `8899` (PORT cố định trong wizard.py, không tham số hoá) mở, tạo cửa sổ Tauri
   `WebviewUrl::External("http://127.0.0.1:8899/")` — UI y hệt `assets/wizard.html` cũ, không đổi
   1 dòng HTML/CSS/JS. Chỉ còn ĐÚNG 1 sidecar (`wizard-server`) — trước đây có thêm sidecar `bot`
   (bot Telegram), đã bỏ hẳn (xem "Dọn dẹp bot Telegram" gần cuối file).
4. `setup.sh` (cài code-server/Tailscale/systemd units, patch code-server login/favicon...) **giữ
   nguyên là bước cài đặt riêng, KHÔNG chạy tự động bởi Tauri** — user tự chạy `bash setup.sh` (từ
   bản copy tại `app_data_dir()/source/setup.sh`, hoặc trực tiếp trong wizard UI như telecode cũ)
   như quy trình gốc.

## Thay đổi tối thiểu so với telecode gốc (không phải nghiệp vụ, chỉ presentation)

**`wizard.py`'s `main()`** — thêm 3 dòng guard: bỏ qua bước tự mở trình duyệt (`open_browser_plain`)
khi biến môi trường `TELECODE_MANAGED=1` (chỉ `sidecar.rs` set khi spawn qua Tauri). Lý do: Tauri
đã tự mở 1 cửa sổ native trỏ cùng URL — không guard sẽ ra 2 cửa sổ trùng lặp (đã tự verify bug này
trước khi fix, xem log build). Chạy `wizard.py` độc lập qua CLI như telecode gốc (không set biến
này) → hành vi y hệt cũ, tự mở Chrome `--app=`.

## Vì sao không khai `externalBin` trong `tauri.conf.json` base

Khác k8sql (luôn có sidecar cho mọi target build), telecode KHÔNG có sidecar Windows — nếu khai
`externalBin` trong config gốc, `cargo tauri build` cho target Windows sẽ đòi hỏi file
`binaries/telecode-sidecar-x86_64-pc-windows-gnu.exe` tồn tại (không có, build Windows sẽ fail
ngay ở bước bundle). Fix: `tauri.conf.json` base KHÔNG khai `externalBin`; `scripts/lib/
build-native.mjs` tiêm `externalBin` qua flag `--config` CHỈ khi build cho platform có sidecar thật
(Linux/macOS thật). Build Windows (`build-windows-cross.mjs`) không tiêm gì thêm — app Windows dùng
`wsl_bridge.rs` thay `.sidecar()`.

## Trạng thái đã verify

- [x] **PyInstaller sidecar + runpy pattern** — build binary Linux thành công, xác nhận chạy đúng
  `scripts/lib_status.py` thật qua subcommand `status` (in đúng JSON trạng thái máy dev thật — LƯU
  Ý: field `currentPassword`/`currentToken` là plaintext thật đọc từ `config.yaml`, cẩn thận khi
  test không vô tình in ra nơi log công khai). Bug thật đã gặp + fix: thiếu `--hidden-import
  http.server`/`urllib.parse` trong `build-pyinstaller.mjs` — dispatcher.py không `import` tĩnh
  wizard.py nên PyInstaller không tự dò ra 2 submodule "chấm" của stdlib này, crash ngay dòng
  `import http.server` khi chạy qua binary đã đóng gói (chạy trực tiếp `python3 wizard.py` không lộ
  bug vì không qua PyInstaller).
- [x] **`cargo check`/`cargo tauri build --bundles deb`** — compile sạch, `.deb` build thành công
  (17MB), layout đúng thiết kế (`/usr/lib/telecode/src/*` = resources, `/usr/bin/telecode` +
  `/usr/bin/telecode-sidecar`). AppImage bundler lỗi "failed to run linuxdeploy" (thiếu FUSE trong
  sandbox dev, KHÔNG liên quan .deb — bỏ qua, không cần cho mục tiêu Linux+Windows installer).
- [x] **Smoke-test app thật (giải nén `.deb`, không cần cài root, chạy trực tiếp binary)** —
  `--tray` mode: `wizard-server` bind đúng cổng 8899, trả đúng HTML `assets/wizard.html` gốc
  ("Cài đặt telecode"), KHÔNG mở trùng cửa sổ trình duyệt (sau fix `TELECODE_MANAGED`). `bot`
  sidecar spawn đúng, lỗi ra đúng thông báo gốc (chưa có `config.yaml`) — đúng hành vi mong đợi
  trước khi chạy `setup.sh`. Resource copy sang `app_data_dir()/source` hoạt động đúng.
- [x] **`npm run build` (target linux) end-to-end** — 1 lệnh từ sạch (xoá binary cũ) ra `.deb`+
  `.rpm` hoàn chỉnh trong `dist/linux-x64/`.
- [x] **Windows cross-compile qua Docker (`npm run build --targets win32` từ Linux)** — thành công
  sau khi fix bug thật: chown volume Docker bằng image `alpine` (theo đúng pattern k8sql) KHÔNG đủ —
  alpine không có sẵn `/usr/local/cargo/registry` nên "Docker tự populate volume rỗng từ nội dung
  image" không trigger lúc chown, chỉ trigger SAU đó khi build container (rust:1-bookworm, có sẵn
  thư mục này) mount cùng volume — ghi đè mất kết quả chown, gây `Permission denied` giữa chừng
  build. Fix: chown bằng CHÍNH image build tại ĐÚNG path mount thật (`/usr/local/cargo/registry`,
  `/work/src-tauri/target`) thay vì path tạm `/reg`/`/tgt` qua alpine. Kết quả:
  `dist/windows-x64/telecode_0.1.0_x64-setup.exe` (4.8MB, xác nhận `file` = "PE32 executable (GUI)
  ... Nullsoft Installer self-extracting archive" — hợp lệ). **Chưa cài/chạy thử trên Windows thật**
  (không có máy/VM Windows) — chỉ xác nhận file build ra hợp lệ, chưa xác nhận installer chạy được
  + app khởi động đúng trên Windows (đặc biệt phần `wsl_bridge.rs`, xem mục provisional bên dưới).
- [ ] **Windows/WSL2 runtime — provisional, CHƯA verify trên máy Windows thật** (không có máy/VM
  Windows lúc làm việc): `src-tauri/src/wsl_bridge.rs` giả định binary `telecode-sidecar` (Linux)
  + toàn bộ source tree đã được đặt sẵn tại `~/.local/share/telecode/{bin,source}` BÊN TRONG
  distro WSL2 mặc định — bước "provision vào WSL2 lúc cài đặt lần đầu" (copy resource bundle Windows
  sang WSL2 qua UNC `\\wsl$\<distro>\...`, build/copy sidecar) **CHƯA triển khai**, chỉ có hàm rỗng
  `wsl_bridge::ensure_provisioned()` làm điểm bắt đầu. Cần làm thêm 1 bước cài đặt riêng (tương tự
  `install.ps1` cũ tự bootstrap WSL2 + git clone) trước khi Windows installer thật sự chạy được.
- [ ] **`setup.sh` chạy từ bản copy `app_data_dir()/source`** — chưa tự chạy thử toàn bộ 9 bước
  thật (cài code-server/Tailscale, patch login page, systemd units...) từ vị trí mới này; về lý
  thuyết không có gì khác biệt (mọi biến `$DIR` trong `setup.sh` tính tương đối theo vị trí chính
  nó, không hardcode path telecode gốc) nhưng CHƯA tự chạy hết để xác nhận 100%.
- [ ] **Tray icon click "Open"/"Exit" qua UI thật** — chỉ mới verify gián tiếp qua
  `--tray` flag (không cửa sổ) và log — chưa tự click chuột qua tray icon thật (cùng giới hạn môi
  trường dev đã ghi trong k8sql/CLAUDE.md Phase 8, màn hình dev không tương tác chuột ổn định).

## Chưa làm (ngoài phạm vi lần triển khai này)

- CI GitHub Actions public đã thêm tại `.github/workflows/build.yml`: build Linux/Windows/macOS
  desktop và Android/iOS theo input `targets`; CLI `npm run build` dispatch target macOS/Android/iOS
  qua `gh`, rồi tải artifact về `dist/github-actions/<run-id>/`. Mặc định repo là
  `pvgiang396/TELECODE`, có thể đổi bằng `GITHUB_REPOSITORY`.
- macOS — không cross-compile được từ Linux (giới hạn Apple), cần máy Mac thật.

## Cấu hình UI (2026-08-14)

- `assets/wizard.html` — hộp thoại setup gốc đổi tên tiêu đề thành **"CẤU HÌNH CÀI ĐẶT"** (trước là
  "Cài đặt telecode"), giờ hiển thị dưới dạng modal overlay (`#settingsModal`) thay vì chiếm toàn bộ
  trang. Trang chính giờ có header ngang tối giản (theo pattern `k8sql/server/public/index.html`'s
  `<header>` + `.header-actions .icon-btn`) với 1 icon bánh răng (⚙️) mở lại modal này — modal tự mở
  sẵn lúc load lần đầu (giữ nguyên UX cũ, không bắt buộc user phải bấm gear mới thấy form). Đây mới
  là bước đặt nền header — menu ngang đầy đủ (nhiều mục) để sau, chưa làm trong lần này.
- **Bug đã fix — token/PAT "biến mất" sau khi đổi sang gói Tauri:** `TELEGRAM_BOT_TOKEN`/
  `OPENAI_API_KEY`/`GITHUB_COPILOT_PAT` đọc từ `config.yaml` NẰM CẠNH `wizard.py` đang chạy
  (`scripts/lib_status.py`'s `project_config = run_dir.parent / "config.yaml"`) — path này tính theo
  bản copy ghi-được `app_data_dir()/source` (xem `resolve_writable_source_dir()` trong `main.rs`),
  KHÁC HOÀN TOÀN với `config.yaml` thật của bản cài `telecode` cũ chạy qua systemd
  (`~/telecode/config.yaml`, `WorkingDirectory` trong `~/.config/systemd/user/telecode-bot.service`).
  Lần copy resource ĐẦU TIÊN sẽ tạo `config.yaml` rỗng (từ `config.example.yaml`) nên wizard báo
  "chưa có" dù thật ra máy đã cấu hình từ trước — Tailscale/code-server không bị ảnh hưởng vì 2 mục
  đó check qua `shutil.which()`/systemd (hệ thống, không phải file project). Fix:
  `resolve_writable_source_dir()` (`main.rs`) sau khi copy resource lần đầu, nếu phát hiện
  `~/telecode/config.yaml` (path cài đặt cũ, quy ước cứng) tồn tại → copy đè lên bản `config.yaml`
  vừa tạo (và `.env` nếu có) trước khi trả về — chỉ chạy đúng 1 lần lúc tạo `app_data_dir()/source`,
  không đụng tới ở các lần chạy sau (venv/config đã có sẽ giữ nguyên theo đúng thiết kế cache gốc).
- **Bug đã fix — Codex 401 `API key required for remote API access` dù đã nhập key:** root cause
  nằm ở file `~/.codex/config.toml` do `setup.sh` sinh thiếu `env_key = "OPENAI_API_KEY"` trong
  `[model_providers.9router]`, khiến Codex gọi custom provider mà không gắn auth header. Fix:
  `setup.sh` thêm `env_key`, đồng thời ghi `OPENAI_API_KEY` + `GH_TOKEN` vào cùng
  `.run/code-server.env` (trước đây chỉ có `GH_TOKEN`) và restart code-server khi env đổi để extension
  nạp lại. Wizard/setup cũng cảnh báo nếu key nhập có dạng `AQ...` (token đăng nhập Codex, không phải
  API key router/OpenAI kiểu `sk-...`).

## Bug đã fix (2026-08-14, phiên sau) — cửa sổ Tauri blank trắng + wizard không thực sự cài đặt

1. **`window.close()` trong webview Tauri gây blank trắng thay vì ẩn cửa sổ:** `wizard.html`
   (gốc cho Chrome `--app=`) tự gọi `window.close()` sau khi lưu — trong webview Tauri thật
   (`WebviewUrl::External`), lệnh này khiến webview unload nội dung TRƯỚC KHI `on_window_event`
   (`main.rs`) kịp `prevent_close()`/`hide()`, để lại cửa sổ mở nhưng trắng trơn. Fix: `main.rs` mở
   URL kèm `?tauri=1`, `wizard.html` đọc query này (`isTauriWindow`) để bỏ qua `window.close()`,
   chỉ đóng modal + hiện lại trang chính. **Kèm theo:** `wizard.py`'s `do_GET` so khớp
   `self.path == "/"` tuyệt đối — có query string sẽ không khớp, trả 404 — phải bóc query trước
   khi so khớp route.
2. **Wizard chỉ ghi `wizard-answers.json` rồi tự thoát server — KHÔNG có gì đọc file này để cài
   đặt thật** (khác luồng CLI gốc: `setup.sh` tự spawn `python3 wizard.py` foreground, đợi nó thoát
   rồi tự đọc file tiếp tục cài; bản Tauri spawn thẳng `wizard-server` qua sidecar, không qua
   `setup.sh`). Fix: `wizard.py`'s `do_POST`, khi `TELECODE_MANAGED=1` (chạy trong Tauri) — thay vì
   tự `os._exit(0)`, spawn nền `bash setup.sh` với `TELECODE_APPLYING=1` (log ra `logs/setup-apply.log`)
   và **không tự thoát server** (cửa sổ Tauri cần `/api/status` sống tiếp để hiển thị tiến trình).
   Luồng CLI gốc (không có `TELECODE_MANAGED`) giữ nguyên hành vi cũ.
3. **`RUN_DIR` lệch giữa `setup.sh` và Tauri:** `setup.sh` tự tính `RUN_DIR="$DIR/.run"` theo vị
   trí chính nó, nhưng Tauri truyền `run_dir` khác hẳn (`app_data_dir()/run`) cho `wizard.py` — nếu
   không đồng bộ, `setup.sh` (khi được spawn từ fix #2) sẽ tìm `wizard-answers.json` sai chỗ, và
   pidfile `code-server.pid`/`bot.pid` cũng ghi lệch chỗ `lib_status.py` đọc (máy có systemd không lộ
   bug vì `_service_running()` ưu tiên check qua `systemctl`, máy không dùng systemd — mac — sẽ lộ).
   Fix: `setup.sh` đổi `RUN_DIR="${TELECODE_RUN_DIR:-$DIR/.run}"` (override qua env, mặc định giữ
   nguyên hành vi CLI cũ); `wizard.py` set `TELECODE_RUN_DIR=<run_dir thật>` khi spawn.
4. **Trang chính giờ tự vẽ VS Code:** thêm field `vscodePort` vào `lib_status.py`'s `get_status()`
   (đọc `VSCODE_PORT` từ `config.yaml`, mặc định `8443`). `wizard.html`'s `#mainContent` tự
   `fetch('/api/status')` lúc load + sau khi lưu cấu hình — `codeServerRunning=true` thì render
   `<iframe id="vscodeFrame" src="http://127.0.0.1:<vscodePort>/">` (code-server không set
   `X-Frame-Options` nên nhúng được), chưa chạy thì hiện thông báo + tự poll lại mỗi 3s tới khi sẵn
   sàng.
5. **Button đổi tên** "Bắt đầu cài đặt" → "Lưu cấu hình" (khớp đúng hành vi mới — không tự đóng
   terminal/cửa sổ trong bản Tauri).
6. **Bug thật, nguyên nhân chính khiến "lưu token nhiều lần vẫn mất":** `lib_status.py`'s
   `get_status()` tính `project_config = run_dir.parent / "config.yaml"` — đúng ở CLI gốc (`RUN_DIR
   = "$DIR/.run"` nên `run_dir.parent == DIR`, đúng nơi có `config.yaml`) nhưng SAI hoàn toàn ở
   Tauri: `run_dir` truyền vào là `app_data_dir()/run` (thư mục app-data riêng, KHÔNG nằm cạnh
   `app_data_dir()/source/config.yaml`) → `currentToken`/`currentOpenaiApiKey`/
   `currentGithubCopilotPat` LUÔN đọc ra rỗng bất kể `config.yaml` có giá trị gì, khiến form wizard
   luôn hiện "chưa có token" (trường `required`) — user tưởng token bị mất, thật ra token trong
   `config.yaml` vẫn còn nguyên, chỉ là UI đọc sai path nên không hiển thị lại được. Fix: `get_status()`
   thêm tham số `project_dir` tường minh (mặc định `run_dir.parent` để không phá CLI/`tray.py` cũ);
   `wizard.py`'s `probe_status()` nhận thêm `dir_`, truyền `project_dir=dir_` (đúng
   `app_data_dir()/source`).

## Rebrand + header gọn + dark login + tính năng "Cập nhật ứng dụng" (2026-08-14)

- **"telecode" → "Telecode" (chỉ text hiển thị)**: `tauri.conf.json`'s `productName`, `main.rs`'s
  `.title()`, `assets/wizard.html`'s `<title>` — không đổi `identifier`
  (`com.pvgiang396.telecode`), Cargo `name`/npm `name` (vẫn lowercase, quy ước nội bộ).
- **Header `wizard.html` gọn lại**: bỏ hẳn logo 🚀 + text tiêu đề (`.header-left`) — chỉ còn
  `.header-actions` bên trái gồm 2 icon: ⚙️ (Cấu hình) + 🔄 (Cập nhật ứng dụng, mới thêm).
- **Trang login code-server chuyển dark theme**: `setup.sh`'s `patch_code_server_assets()` thêm
  khối CSS marker `telecode-dark-theme-css-v1` (độc lập với `telecode-eye-toggle-css-v2` cũ, check
  riêng) — ép `!important` theo cùng palette `wizard.html` (`#1e1e1e`/`#252526`/`#3c3c3c`/`#e5e5e5`/
  `#3f83f8`) lên `html/body`/`.login-form`/`.field`/input/nút submit — không liệt kê hết selector
  nội bộ code-server (dễ vỡ khi code-server update), chỉ ép các mức cha + selector đã biết chắc từ
  khối eye-toggle.
- **Cơ chế versioning cache + tính năng "Cập nhật ứng dụng"** (đóng gap cache đã ghi trước đây —
  "cài `.deb` bản mới không tự làm mới cache `app_data_dir()/source`"):
  - `main.rs`'s `resolve_writable_source_dir()` giờ ghi kèm marker `dest/.bundle-version` (version
    app lúc copy). Mỗi lần khởi động, nếu marker khác `app.package_info().version` hiện tại (tức
    vừa `dpkg -i` bản `.deb` mới hơn) → gọi lại `copy_dir_recursive(bundled_src, dest)` đồng bộ lại
    toàn bộ file "code" (`wizard.py`/`setup.sh`/`scripts/`/`assets/`...) — **an toàn với
    state user** vì hàm chỉ duyệt theo `bundled_src` (không có `config.yaml`/`.env`/`venv/`/`logs/`
    trong đó) nên các file/thư mục đó ở `dest` không bị đụng tới.
  - Nút 🔄 (`wizard.html`) gọi `POST /api/self-update` (endpoint mới trong `wizard.py`,
    `run_self_update()`) — port từ `k8sql/server/src/selfUpdate.ts`: `git pull` tại
    `TELECODE_SOURCE_DIR` → `npm run build -- --targets linux` → tìm `.deb` mới nhất
    `dist/linux-x64/` → cài qua `cmdctl` (`POST /exec {sudo:true}`, KHÔNG tự gọi `sudo` trực tiếp)
    → kill (`pkill -9 -f` có neo `^`, tránh tự-giết-mình — cùng bug đã biết bên k8sql) + respawn
    detached `telecode --tray`.
  - **Phạm vi CHỈ máy dev có sẵn checkout** — giống hệt tiền lệ `K8SQL_SOURCE_DIR` bên k8sql
    (Linux-only, không có hạ tầng CI/phân phối cho máy khác). `sidecar.rs` forward nguyên trạng
    `TELECODE_SOURCE_DIR` từ env của tiến trình Tauri sang sidecar (không hardcode path) — máy
    không set biến này (đa số máy user cài `.deb` bình thường) bấm 🔄 sẽ nhận lỗi rõ ràng, không
    crash ngầm.
  - **Đây chính là cơ chế khiến fix Codex 401 (mục "Bug đã fix — Codex 401" ở trên) thật sự tới
    được máy đang chạy bản cache cũ** — trước đây fix chỉ nằm trong file nguồn `setup.sh`, máy đã
    tạo `app_data_dir()/source` từ trước khi fix vào code vẫn chạy bản `setup.sh` cũ thiếu
    `env_key` mãi mãi (gap giờ đã đóng, không phải quyết định để sau nữa).
- **Đã tự verify end-to-end thật trên máy dev** (không chỉ đọc code): cài `.deb` mới qua cmdctl đè
  lên bản đang chạy sống (bot Telegram + wizard thật) → title/header/2 icon đúng như thiết kế; đặt
  `TELECODE_SOURCE_DIR` (qua `~/.config/environment.d/telecode-source-dir.conf`, áp dụng cho phiên
  đăng nhập sau — phiên hiện tại đã set tay lúc test) → bấm nút 🔄 thật chạy đúng toàn bộ chuỗi git
  pull → `npm run build` → cài `.deb` mới qua cmdctl → kill (`pkill -9 -f` có neo) + respawn detached
  → app lên lại khoẻ mạnh (`/api/status` sống, code-server 302). Dark-theme login đã tự verify bằng
  Playwright thật (`browser_evaluate` đọc `getComputedStyle`): `body` `rgb(30,30,30)` (#1e1e1e),
  `.login-form` `rgb(37,37,38)` (#252526), chữ `rgb(229,229,229)` (#e5e5e5) — khớp đúng palette.

## Tauri Android — app di động riêng thay Telegram Mini App WebView (2026-08-14)

**Vai trò**: giải quyết bug AskUserQuestion (button/radio/checkbox của Claude Code/Codex) không
hiện đủ khi dùng qua Telegram Mini App trên điện thoại. Root cause đã xác nhận: Telegram tiêm
`telegram-web-app.js` chủ động điều khiển viewport + có chrome/back-button riêng đè lên, gây xung
đột với overlay `position:fixed` (đúng dạng AskUserQuestion hay dùng) — không phải giới hạn của
WebView engine (cùng WKWebView/Chrome WebView với 1 app cài riêng). App Tauri cài riêng sở hữu
hoàn toàn webview của nó, không JS bridge/chrome bên thứ 3 nào chen vào → tránh được đúng cơ chế
gây lỗi này. **Chỉ làm Android** — iOS cần máy Mac thật (cùng lý do macOS desktop không cross-
compile được, xem "Chưa làm" phía dưới), để ngoài phạm vi lần này.

**Kiến trúc**: 2 entry point Rust hoàn toàn tách biệt trong CÙNG package Cargo `telecode`:
- `src/main.rs` (bin) — desktop Linux/Windows, KHÔNG đổi gì (tray/sidecar Python/wizard-server).
- `src/lib.rs` (lib, mới thêm — `[lib] crate-type = ["staticlib","cdylib","rlib"]` trong
  `Cargo.toml`, bắt buộc để Android JNI load `.so`) — mobile-only, hàm `run()` gắn
  `#[tauri::mobile_entry_point]`, tạo 1 cửa sổ `WebviewUrl::App("index.html")` trỏ vào
  `frontend-placeholder/index.html` (trước là placeholder rỗng, giờ là trang thật — desktop
  KHÔNG dùng tới file này, main.rs luôn override bằng `WebviewUrl::External` nên an toàn khi thay
  nội dung).
- `frontend-placeholder/index.html`: client thuần túy — form nhập URL Tailscale/Funnel của máy
  đang chạy code-server (lưu vào `localStorage` NGAY TRONG webview, không qua plugin/IPC Tauri
  nào), hiển thị qua `<iframe>` full màn hình (cùng pattern `#vscodeFrame` đã dùng ở
  `wizard.html` desktop). Icon ⚙️ ở header (cùng style dark palette #1e1e1e/#252526/#3f83f8) mở
  lại form đổi URL.
- Không cần capability `"remote"` trong `capabilities/default.json` — desktop cũng dùng
  `WebviewUrl::External` mà không cần khai gì thêm (khác giả định ban đầu tham chiếu k8sql: ACL
  chỉ chặn `invoke()` lệnh Tauri từ JS, trang này không gọi Tauri API nào nên không bị chặn).

**Setup máy dev** (1 lần, đã làm trên máy này — `~/Android/Sdk`): `sdkmanager` cài
`platform-tools` + `platforms;android-34` + `build-tools;34.0.0` + `ndk;27.0.12077973` (Gradle tự
tải thêm `build-tools;35`/`platforms;android-36` khi build vì AGP đòi compileSdk mới hơn — bình
thường, không cần cài tay trước) + `rustup target add aarch64-linux-android
armv7-linux-androideabi i686-linux-android x86_64-linux-android`. `ANDROID_HOME`/`NDK_HOME` ghi
vào `~/.bashrc` (không hardcode trong repo — máy khác cần tự set biến này theo path SDK của họ,
đúng rule cross-platform).

Android build yêu cầu Cargo/Rust mới có hỗ trợ Edition 2024. Máy dùng Cargo hệ thống `1.75`
sẽ lỗi khi đọc dependency `dlopen2_derive`; `scripts/build-android.mjs` tự ưu tiên Cargo trong
`$HOME/.cargo/bin` (rustup) trước `/usr/bin` để dùng toolchain đã cài qua rustup.

**Bug thật đã gặp + fix — `npm run tauri` không tồn tại**: template Gradle Tauri tự sinh
(`gen/android/buildSrc/.../BuildTask.kt`) chạy `npm run -- tauri android android-studio-script`
tại thư mục `src-tauri` (không có `package.json` riêng, npm tự tìm lên `package.json` gốc
workspace) — gốc `telecode-workspace`'s `package.json` trước đây chỉ có script `"build"`, thiếu
`"tauri": "tauri"` (quy ước chuẩn `create-tauri-app` mà template Gradle giả định luôn có). Fix:
thêm script này vào `package.json` gốc — không ảnh hưởng `npm run build` (build-cross-platform.mjs)
hiện có.

**Lệnh build — dùng `npm run build:android` để tự chạy đúng thứ tự 4 bước (tránh bỏ sót patch
cookie):**

1. `cd src-tauri && npx tauri android init` (sinh `gen/android/`, gitignored — đã có sẵn trong
   `.gitignore`'s `src-tauri/gen/`).
2. `node ../scripts/patch-android-webview.mjs` (từ `src-tauri/`, hoặc `node scripts/patch-android-webview.mjs`
   từ root project) — bật `CookieManager.setAcceptThirdPartyCookies` cho WebView, xem "Bug đã fix —
   đăng nhập code-server trên mobile không giữ session" bên dưới. THIẾU bước này: đăng nhập
   code-server trong app luôn bị đá về `/login` dù nhập đúng password.
3. `npx tauri icon assets/icon.png` — nạp icon telecode thật vào Android, xem "Bug đã fix — icon
   Android vẫn là icon mặc định Tauri" bên dưới. THIẾU bước này: launcher icon ra icon vô cực
   vàng/xanh mặc định của template Tauri.
4. `cd src-tauri && npx tauri android build` — build APK sau khi patch cookie và icon đã được áp dụng.

Chạy toàn bộ từ thư mục `telecode` bằng `npm run build:android`; script luôn chạy lại `android init`,
patch cookie và nạp icon trước khi build, không phụ thuộc trạng thái thư mục `gen/android/`.

Sau đó `npx tauri android build --debug --target aarch64` → ra APK trong
`gen/android/app/build/outputs/apk/`; `npm run build:android` tự copy các APK tìm được vào
`dist/android/` với tên `Telecode_<tên-gốc>.apk` (debug build chưa optimize/strip nên khá nặng;
build `--release` nhỏ hơn nhiều và script tự ký bằng keystore phát triển tại
`~/.android/telecode-debug.keystore` để cài trực tiếp). Khi phát hành chính thức, đặt
`TELECODE_ANDROID_KEYSTORE`, `TELECODE_ANDROID_KEY_ALIAS`, `TELECODE_ANDROID_KEYSTORE_PASSWORD`
và `TELECODE_ANDROID_KEY_PASSWORD` trước khi build. Bước 2/3 chỉ cần chạy LẠI khi `gen/android/` bị xoá/`android init` chạy lại (file
đích bị tauri-cli ghi đè hoàn toàn mỗi lần init) — build lại bình thường (không init lại) thì patch
vẫn còn nguyên, không cần lặp lại.

Đã tự verify: `aapt dump badging` xác nhận đúng `package: com.pvgiang396.telecode`,
`application-label: 'Telecode'`, permission `INTERNET`, icon `mipmap-anydpi-v26/ic_launcher.xml`
đúng icon telecode — build thành công thật; đã cài thử trên điện thoại Android thật nhiều lần
(2026-08-14, xem "Bug đã fix" bên dưới) — vẫn **chưa tự xác nhận được lần cài mới nhất (kèm fix
cookie + màn hình cài đặt full-page) trên điện thoại thật**, môi trường này không có thiết bị/adb
kết nối lúc làm — user tự cài `.apk` mới nhất ở `dist/android/Telecode_0.1.0_debug.apk` rồi báo lại.

**Chưa làm**: publish lên Play Store (không cần thiết cho dùng cá nhân, cài trực tiếp `.apk` đủ
dùng).

## iOS — cần build trên máy Mac thật (chưa tự làm, chỉ chuẩn bị sẵn code)

`lib.rs`/`Cargo.toml`/`frontend-placeholder/index.html` ở trên đã viết CHUNG cho cả Android lẫn
iOS ngay từ đầu (`#[cfg_attr(any(target_os = "android", target_os = "ios"), ...)]`) — không cần
sửa thêm gì để bắt đầu build iOS, chỉ cần chạy trên máy Mac thật (Apple không cho cross-compile/
chạy Xcode trên Linux/Windows dưới bất kỳ hình thức nào — khác Windows đã có đường vòng Docker
cross-compile, iOS không có đường vòng tương đương).

**Các bước trên máy Mac** (đã pull code mới nhất về):
1. Cài Xcode đầy đủ (từ Mac App Store) + `xcode-select --install` (Command Line Tools).
2. Cài Rust (`rustup`) nếu chưa có, rồi `rustup target add aarch64-apple-ios
   aarch64-apple-ios-sim x86_64-apple-ios`.
3. Cài Node.js (khớp version dùng ở `scripts/build-cross-platform.mjs`).
4. `cd src-tauri && npx tauri ios init` — sinh `gen/apple/` (gitignored, cùng pattern
   `gen/android/`).
5. Test nhanh trên Simulator (KHÔNG cần Apple Developer account trả phí):
   `npx tauri ios dev` — mở simulator, load app ngay.
6. Cài lên iPhone thật để test tay: mở project trong `gen/apple/` bằng Xcode, chọn "Signing &
   Capabilities" → chọn Apple ID cá nhân làm Team (miễn phí) → chọn thiết bị thật → Run. Giới hạn
   tài khoản miễn phí: app chỉ chạy được ~7 ngày trên máy rồi phải build/cài lại (không giới hạn
   nếu có Apple Developer Program trả phí, $99/năm — chỉ cần khi muốn cài lâu dài không phải build
   lại, hoặc publish lên TestFlight/App Store).
7. Build release archive (khi cần bản chính thức): `npx tauri ios build` — cần Team ID/certificate
   hợp lệ (trả phí) mới ký + xuất `.ipa` cài ngoài Xcode được.

## Bug đã fix (2026-08-14, phiên feedback thật đầu tiên từ thiết bị) — `srs/LoiTelecode/v3.md`

1. **Popup cài đặt che màn hình mỗi lần mở app dù đã cấu hình xong**: `assets/wizard.html` trước
   đây LUÔN tự gọi `openSettings()` sau khi fetch `/api/status`, bất kể đã lưu token/password từ
   trước hay chưa. Fix: chỉ tự mở modal khi `!s.currentToken || !s.currentPassword` (chưa cấu hình
   lần nào) — đã cấu hình rồi thì hiện thẳng trang chính (login code-server thật nếu chưa đăng
   nhập, hoặc iframe VS Code nếu đã chạy); modal vẫn mở tay được qua nút ⚙️.
2. **Điền sẵn password vào ô đăng nhập code-server**: thêm hàm mới
   `patch_code_server_login_password()` trong `setup.sh` (mục 2b, chạy SAU khi biết `$CS_PASSWORD`
   ở mục 2 — tách khỏi `patch_code_server_assets()` vì hàm đó chạy TRƯỚC khi biết password) — chèn
   `<script>` set `value` cho `input[name="password"]` trong `login.html`. Idempotent THEO GIÁ TRỊ
   (marker nhúng kèm password) chứ không chỉ theo tồn tại, để đổi password ở lần chạy `setup.sh` kế
   tiếp vẫn ghi đè đúng.
3. **Tray icon không đổi màu theo trạng thái (`scripts/lib_status.py`'s `overall_ok()` viết sẵn từ
   trước nhưng chưa từng được dùng)**: `wizard.py` thêm route `/api/tray-status` (tách khỏi
   `/api/status` vì cần `check_public=True` — curl thật ra Funnel public URL, tốn round-trip nên
   không dùng chung với `/api/status` vốn cần trả nhanh cho UI poll liên tục). `src-tauri/src/main.rs`
   giữ lại `TrayIcon` handle (trước đây bị drop ngay sau `.build(app)?`), thêm `poll_tray_status()`
   chạy trên 1 thread riêng, poll route trên mỗi 10s, đổi `tray-icon-on.png`/`tray-icon-off.png`
   (đã có sẵn từ trước, sinh bởi `assets/gen_tray_icons.py`, chỉ chưa wire). Cần thêm feature
   `image-png` cho crate `tauri` trong `Cargo.toml` (`Image::from_path` bị feature-gate).
4. **Icon Android vẫn là icon mặc định Tauri (logo vàng/xanh vô cực) thay vì icon telecode thật**:
   root cause — `npx tauri icon assets/icon.png` (sinh `src-tauri/icons/`) chạy TRƯỚC khi
   `gen/android/` tồn tại nên bỏ qua phần sinh icon mobile; `npx tauri android init` sau đó tự tạo
   icon mobile mặc định vì không có nguồn icon android nào. Fix: chạy LẠI `npx tauri icon
   assets/icon.png` sau khi `gen/android/` đã init — lệnh này phát hiện thư mục và ghi đè đúng
   `ic_launcher*.png` mọi mipmap density. `gen/android/` gitignored nên bước này phải làm LẠI mỗi
   máy/checkout mới build — đã ghi vào "Lệnh build" ở trên để không lặp lại bug.
5. **Nút tải lại trong app di động**: `src-tauri/frontend-placeholder/index.html` thêm nút 🔄 cạnh
   ⚙️ (ép `frame.src = 'about:blank'` rồi gán lại URL thật — không chỉ gán lại y hệt src cũ vì có
   thể bị coi là "cùng URL, không cần load lại").
6. **`ERR_CONNECTION_CLOSED` lúc mở app lần đầu trên điện thoại**: sau khi user thử lại nhiều lần
   (mạng khác nhau, cả Wifi lẫn 4G) và sau đó tự vào được tới màn login code-server ở lần thử kế
   tiếp — kết luận đây là Funnel/mạng gián đoạn TẠM THỜI đúng lúc test lần đầu, không phải lỗi cấu
   hình/code (đã xác nhận Funnel/tailscaled hoạt động bình thường từ trước). Không cần sửa gì thêm
   cho riêng triệu chứng này — xem mục 7 bên dưới cho bug THẬT SỰ chặn luồng đăng nhập phát hiện sau
   khi qua được màn hình này.
7. **Bug nghiêm trọng — đăng nhập code-server trên mobile không giữ session (nhập đúng password vẫn
   bị đá về `/login`, ô password bị xoá)**: root cause xác nhận qua đọc thẳng source `wry`
   (`~/.cargo/registry/.../wry-0.55.1/src/android/kotlin/RustWebView.kt`, template tauri-cli dùng
   sinh `gen/android/.../generated/RustWebView.kt`) — Android WebView mặc định CHẶN cookie bên thứ 3
   (khác hẳn desktop WebKitGTK), mà `frontend-placeholder/index.html` nhúng code-server (origin
   khác) trong `<iframe>` bên trong trang top-level của app → đúng bối cảnh cookie bên thứ 3. Server
   xác thực đúng password, set session cookie, nhưng WebView từ chối lưu (âm thầm, không báo lỗi) →
   request tiếp theo vẫn coi chưa đăng nhập → quay lại `/login`. Frontend mobile hiện mở URL
   code-server top-level thay vì iframe để cookie đăng nhập là first-party; patch cookie vẫn giữ
   cho các WebView cũ. Không có config chính thức nào
   trong `tauri.conf.json` để bật cờ này (đã grep toàn bộ source `tauri`/`tauri-utils` xác nhận
   không tồn tại) — fix bằng script mới `scripts/patch-android-webview.mjs` (idempotent, tìm
   `RustWebView.kt` qua glob) chèn `CookieManager.getInstance().setAcceptThirdPartyCookies(this,
   true)` vào `init {}` — file này bị tauri-cli ghi đè hoàn toàn mỗi lần `android init` nên PHẢI
   chạy lại script sau mỗi lần init, đã ghi vào "Lệnh build" ở trên (bước 2/3).
8. **Màn hình "Kết nối máy" vẫn dính sát mép trên dù đã fix padding ở mục 5 phiên trước**: root
   cause thật — fix `env(safe-area-inset-top)` trước đó chỉ áp cho `header` (thanh header màn hình
   CHÍNH), nhưng màn hình user thấy khi CHƯA kết nối là `.modal-overlay`/`#settingsModal` (1 element
   HOÀN TOÀN KHÁC, `position:fixed;inset:0` che phủ luôn `header`, tự căn
   `align-items:flex-start;padding:24px` không hề có safe-area) — sửa nhầm chỗ vì không nhận ra
   modal che mất header ở đúng màn hình test. Fix: bỏ hẳn kiểu popup/modal (backdrop mờ + hộp nổi
   giữa trang), đổi `#settingsModal` thành `#settingsScreen` — 1 màn hình toàn trang riêng (`.screen`,
   không dimming/backdrop) với header/safe-area riêng (dùng lại đúng style `header`) + nội dung căn
   giữa dọc (`.screen-body{display:flex;align-items:center;justify-content:center}`), đúng bố cục
   màn login code-server user dùng làm tham chiếu. Thêm nút back (←) trong header màn cài đặt — chỉ
   hiện khi ĐÃ từng kết nối trước đó (có gì để quay về); lần mở đầu tiên (chưa từng kết nối) ẩn nút
   back, giống màn login không có nút back.

## Cleanup Codex writer lock khi mở Telecode (2026-08-15)

Codex lưu lock writer theo thread tại `~/.codex/thread-writer-locks/`. Khi webview/Telecode cũ
thoát bất thường, lock file có thể còn lại và lần mở session cũ sau đó báo `already has an active
writer`, dẫn tới khung chat chớp liên tục. `wizard.py` gọi
`scripts/cleanup_codex_writers.py` ngay khi `wizard-server` khởi động. Script chỉ xóa lock mà nó
giành được `flock(LOCK_EX|LOCK_NB)`; lock đang được app-server sống giữ sẽ không bị xóa hoặc kill.
`.coordination.lock` luôn được bỏ qua vì là lock điều phối chung của Codex.

## Dọn dẹp bot Telegram (2026-08-14, phiên sau)

Không còn dùng Telegram Mini App/bot Telegram nữa (chỉ dùng qua desktop app + Android app) — đã xoá
sạch subsystem này:

- **Xoá hẳn**: `bot.py`, `mini_app.html`, `Dockerfile.bot`, `docker-compose.yml`, `nginx.conf`,
  `scripts/backup-ai-configs.sh`, `scripts/receive-ai-configs.py` (2 script cuối chỉ phục vụ đúng
  luồng khôi phục AI config qua Telegram, không còn cách nào trigger sau khi bỏ bot).
- **Sửa (giữ phần dùng chung)**: `src-tauri/src/sidecar.rs`/`wsl_bridge.rs` (bỏ spawn sidecar `bot`,
  chỉ còn `wizard-server`), `sidecar/dispatcher.py`/`build-pyinstaller.mjs` (bỏ subcommand `bot` +
  hidden-import `telegram`), `tauri.conf.json` (bỏ resource `bot.py`), `requirements.txt`/
  `sidecar/requirements.txt` (bỏ `python-telegram-bot`), `scripts/lib_status.py` (bỏ
  `botRunning`/`botPid`/`currentToken`/`currentFileInboxDir`, `overall_ok()` bỏ điều kiện
  `botRunning`), `assets/wizard.html` (bỏ field token/file-inbox, gate popup đổi thành
  `!s.currentPassword` — **lưu ý các đoạn "Bug đã fix" phía trên có nhắc `currentToken` là mô tả
  ĐÚNG TẠI THỜI ĐIỂM VIẾT, đã lỗi thời sau thay đổi này, không sửa lại lịch sử**), `setup.sh` (xoá
  mục Telegram Bot Token/FILE_INBOX_DIR/khôi phục AI config qua Telegram/chạy bot; thêm bước tự tắt+gỡ
  service `telecode-bot` cũ cho máy nâng cấp; di chuyển logic bật `loginctl enable-linger` từ bước
  "chạy bot" sang bước chạy code-server vì linger áp dụng cho toàn bộ systemd --user của user, không
  riêng 1 service), `config.example.yaml`/`.env.example` (bỏ field bot, sửa luôn phần Cloudflare/Ngrok
  lỗi thời thành Tailscale Funnel), `scripts/reconnect.sh` (bỏ restart `telecode-bot`/`bot.py` —
  **bug thật, không chỉ doc**: script này sẽ fail/no-op vô ích nếu không xoá vì service/file không
  còn tồn tại).
- **Docs người dùng** (`README.md`/`QUICK_START.md`/`TROUBLESHOOTING.md`/`PROJECT_STRUCTURE.md`/
  `LICENSE`): đổi tên sản phẩm khỏi "Telegram VS Code Mini App" → "Telecode", xoá hướng dẫn/troubleshoot
  qua Telegram, thay bằng hướng dẫn dùng app di động (bấm ⚙️, dán URL Tailscale Funnel) — theo yêu cầu
  user CHỈ sửa đúng đoạn liên quan, không viết lại toàn bộ.
- **Không đụng** (ngoài phạm vi): `tray.py` (không dùng nữa nhưng KHÔNG phải phần Telegram),
  `assets/pat-guide.html` (không có tham chiếu Telegram), comment lịch sử trong `lib.rs`/CLAUDE.md
  giải thích lý do KHÔNG dùng Telegram Mini App WebView (vẫn đúng, là bối cảnh kiến trúc).
- **Chưa làm**: chưa rebuild `.apk` Android (không đụng gì liên quan mobile trong lần này) — chỉ
  rebuild + cài lại `.deb` desktop.

## Đọc thêm

- [`k8sql/CLAUDE.md`](../k8sql/CLAUDE.md) — pattern gốc đã tham chiếu (Tauri + sidecar + tray +
  build đa nền tảng), nhiều gotcha (PATH rustup, `libayatana-appindicator3-dev`, `"windows": []`
  tránh panic label trùng...) áp dụng y hệt ở đây, không lặp lại chi tiết.
