# telecode — AI Reference

> File này tự đủ để hiểu kiến trúc telecode và tiếp tục triển khai.

**2026-08-14 — hợp nhất gói đóng gói Tauri vào repo gốc:** bản đóng gói Tauri (phát triển song song
từ 2026-08-13 trong thư mục riêng, tên tạm `televscode`) đã hợp nhất làm nội dung chính thức của
repo `telecode` (git history gốc của `telecode` — Python/Flask thuần, không có gói cài đặt desktop —
được giữ nguyên, nội dung Tauri đè lên làm commit mới). Từ nay **chỉ còn 1 project tên `telecode`**
trong workspace, không còn thư mục/tên gọi tạm ở trên.

## Vai trò

telecode là bản đóng gói desktop-app thật (Tauri, cài đặt 1 click), mở VS Code (code-server) từ xa
qua Telegram Mini App. Kế thừa **gần như nguyên vẹn** toàn bộ business logic Python/Bash gốc
(`bot.py`, `wizard.py`, `setup.sh`, `scripts/lib_status.py`, `scripts/reconnect.sh`) — chỉ đổi lớp
vỏ cài đặt/khởi chạy, theo đúng pattern đã dùng khi chuyển `k8sctl` → [`k8sql`](../k8sql/CLAUDE.md).

## Khác biệt kiến trúc so với k8sql (đọc trước khi sửa)

k8sql wrap 1 backend Node.js bằng SEA (Single Executable Application) sidecar — cross-compile được
từ Linux sang Windows (`postject` chỉ thao tác byte, không phụ thuộc `process.platform`). telecode
là **Python + Bash**, không có tương đương — dẫn tới 2 khác biệt cốt lõi:

1. **Sidecar Python đóng gói bằng PyInstaller, KHÔNG cross-compile được** — chỉ build ra binary
   đúng cho OS đang chạy lệnh build. Sidecar Linux chỉ build được TRÊN Linux.
2. **Windows KHÔNG có sidecar Python riêng** — thay vào đó gọi qua `wsl.exe`, tái dùng ĐÚNG binary
   Linux đã build, chạy BÊN TRONG WSL2 (`src-tauri/src/wsl_bridge.rs`). Đây không phải hạn chế mới:
   telecode gốc trên Windows *vốn đã* yêu cầu WSL2 (`install.ps1` tự cài WSL2 rồi chạy toàn bộ
   `setup.sh`/`bot.py` bên trong đó, vì code-server chưa từng chạy native Windows).

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
│   │                              #   TẠI SAO không `import` tĩnh bot.py/wizard.py
│   ├── requirements.txt           # deps để PyInstaller bundle (khớp deps thật bot.py/wizard.py dùng)
│   └── scripts/build-pyinstaller.mjs
├── bot.py, wizard.py, setup.sh, scripts/, assets/, requirements.txt, tray.py
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

1. `main.rs` tạo tray (Open/Exit) + copy `bundle.resources` (bot.py/wizard.py/setup.sh/scripts/
   assets, khai trong `tauri.conf.json`) từ vị trí chỉ-đọc (vd `/usr/lib/telecode/src/` trên
   `.deb` đã cài) sang `app_data_dir()/source` (ghi được) — **chỉ copy 1 lần**, các lần chạy sau tái
   dùng bản copy này (`resolve_writable_source_dir()`). Lý do bắt buộc: `setup.sh` cần ghi
   `config.yaml`/`.env`/`venv/` NGAY CẠNH chính nó, không ghi được vào thư mục root-owned.
2. Spawn sidecar `wizard-server <path-tới-wizard.py-thật> <RUN_DIR> <DIR>` — dispatcher.py chạy
   `wizard.py` qua `runpy.run_path()` (KHÔNG `import` tĩnh — xem lý do trong dispatcher.py) để
   `Path(__file__).parent` bên trong wizard.py trỏ ĐÚNG vị trí thật, không trỏ vào thư mục tạm giải
   nén PyInstaller (`sys._MEIPASS`) — cùng lớp bug k8sql từng gặp với `__dirname` trong Node SEA.
3. Đợi cổng `8899` (PORT cố định trong wizard.py, không tham số hoá) mở, tạo cửa sổ Tauri
   `WebviewUrl::External("http://127.0.0.1:8899/")` — UI y hệt `assets/wizard.html` cũ, không đổi
   1 dòng HTML/CSS/JS.
4. Spawn sidecar `bot <path-tới-bot.py-thật>` song song — tiến trình polling Telegram, không có
   HTTP endpoint nên không health-check, chỉ log stdout/stderr. Lỗi "TELEGRAM_BOT_TOKEN is required"
   khi CHƯA chạy `setup.sh`/chưa có `config.yaml` là **hành vi đúng, không phải bug** — đúng validate
   gốc của `bot.py` không đổi.
5. `setup.sh` (cài code-server/Tailscale/systemd units, patch code-server login/favicon...) **giữ
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

- CI thật (GitLab runner build tự động) — build hiện chỉ chạy local qua `npm run build`.
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

## Đọc thêm

- [`k8sql/CLAUDE.md`](../k8sql/CLAUDE.md) — pattern gốc đã tham chiếu (Tauri + sidecar + tray +
  build đa nền tảng), nhiều gotcha (PATH rustup, `libayatana-appindicator3-dev`, `"windows": []`
  tránh panic label trùng...) áp dụng y hệt ở đây, không lặp lại chi tiết.
