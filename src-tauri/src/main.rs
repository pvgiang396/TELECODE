// telecode — Tauri shell. Kế thừa nguyên vẹn wizard.py/setup.sh từ telecode (xem
// sidecar/dispatcher.py + CLAUDE.md) — module này chỉ lo: cửa sổ, tray, spawn/kill sidecar
// wizard-server (phục vụ UI cài đặt/VS Code), copy resource bundle (read-only) ra 1 bản ghi
// được trong app-data lúc chạy lần đầu (setup.sh cần ghi config.yaml/.env/venv cạnh chính nó
// — không ghi được vào /usr/lib/telecode/... trên .deb đã cài).
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod sidecar;
#[cfg(target_os = "windows")]
mod wsl_bridge;

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tauri::image::Image;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};

fn wants_tray_only() -> bool {
    std::env::args().any(|a| a == "--tray")
}

fn show_main_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}

/// Thoát THẬT — chỉ gọi từ menu tray "Exit". Đóng cửa sổ (nút X) chỉ ẩn, xem `on_window_event`.
fn quit_app(app: &AppHandle) {
    if let Some(state) = app.try_state::<std::sync::Mutex<Option<sidecar::SidecarChildren>>>() {
        if let Ok(mut guard) = state.lock() {
            if let Some(children) = guard.take() {
                sidecar::shutdown(children);
            }
        }
    }
    app.exit(0);
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            show_main_window(app);
        }))
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            Some(vec!["--tray"]),
        ))
        .setup(|app| {
            let app_handle = app.handle().clone();
            let tray_only = wants_tray_only();

            let source_dir = resolve_writable_source_dir(app)?;
            let run_dir = app.path().app_data_dir()?.join("run");

            let open_item = MenuItem::with_id(app, "open", "Open", true, None::<&str>)?;
            let exit_item = MenuItem::with_id(app, "exit", "Exit", true, None::<&str>)?;
            let tray_menu = Menu::with_items(app, &[&open_item, &exit_item])?;

            // Icon tray xanh (chấm xanh = đang hoạt động) làm mặc định lúc mới mở — trước đây dùng
            // `default_window_icon()` (icon app trơn, không chấm màu nào) khiến tray trông như app
            // "không rõ trạng thái" dù đang chạy bình thường. Poll định kỳ bên dưới sẽ tự đổi sang
            // tray-icon-off.png (chấm đỏ) nếu `overall_ok()` (scripts/lib_status.py) báo có thành
            // phần nào đó không sống/không truy cập được từ internet.
            let tray_icon_on = tray_icon_image(&source_dir, "tray-icon-on.png")
                .or_else(|| app.default_window_icon().cloned());

            let mut tray_builder = TrayIconBuilder::new()
                .menu(&tray_menu)
                .on_menu_event(|app, event| match event.id().as_ref() {
                    "open" => show_main_window(app),
                    "exit" => quit_app(app),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        show_main_window(tray.app_handle());
                    }
                });
            if let Some(icon) = tray_icon_on {
                tray_builder = tray_builder.icon(icon);
            }
            let tray = tray_builder.build(app)?;
            app.manage(tray);

            {
                let source_dir = source_dir.clone();
                let app_handle = app_handle.clone();
                std::thread::spawn(move || poll_tray_status(&app_handle, &source_dir));
            }

            tauri::async_runtime::spawn(async move {
                match sidecar::spawn_all(&app_handle, &source_dir, &run_dir).await {
                    Ok(children) => {
                        app_handle.manage(std::sync::Mutex::new(Some(children)));

                        // ?tauri=1 — wizard.html đọc query này để KHÔNG gọi window.close() sau khi
                        // lưu xong (xem CloseRequested handler bên dưới): webview trong cửa sổ Tauri
                        // thật (khác cửa sổ Chrome --app= do wizard.py tự mở ở chế độ CLI độc lập) sẽ
                        // bị blank trắng nếu JS tự gọi window.close() — webview unload nội dung trước
                        // khi prevent_close()/hide() kịp chạy, để lại cửa sổ trắng trơn (bug thật đã
                        // gặp, xem CLAUDE.md).
                        let url = "http://127.0.0.1:8899/?tauri=1"
                            .parse()
                            .expect("URL wizard-server không hợp lệ");

                        let window = WebviewWindowBuilder::new(
                            &app_handle,
                            "main",
                            WebviewUrl::External(url),
                        )
                        .title("Telecode")
                        .inner_size(900.0, 720.0)
                        .visible(!tray_only)
                        .build()
                        .expect("Không tạo được cửa sổ chính");
                        if !tray_only {
                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                    }
                    Err(e) => {
                        eprintln!("[telecode] Lỗi khởi động sidecar: {e}");
                    }
                }
            });

            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .run(tauri::generate_context!())
        .expect("Lỗi khi chạy telecode");
}

fn tray_icon_image(source_dir: &Path, file_name: &str) -> Option<Image<'static>> {
    let path = source_dir.join("assets").join(file_name);
    Image::from_path(&path).ok()
}

/// Poll `/api/tray-status` (wizard-server, xem wizard.py) mỗi 10s để đổi icon tray xanh/đỏ theo
/// `overall_ok()` (scripts/lib_status.py — đã có sẵn logic tổng hợp "mọi thành phần sống + Funnel
/// thật sự reachable từ internet", trước đây chưa từng được main.rs dùng tới). Chạy trên 1 thread
/// riêng (không phải async task) vì chỉ cần TCP request chặn đơn giản, cùng mức "chấp nhận block 1
/// thread ngắn" như `wait_until_port_open()` trong sidecar.rs — không đáng thêm dependency HTTP
/// client/JSON riêng chỉ cho 1 field boolean.
fn poll_tray_status(app: &AppHandle, source_dir: &Path) {
    let icon_on = tray_icon_image(source_dir, "tray-icon-on.png");
    let icon_off = tray_icon_image(source_dir, "tray-icon-off.png");
    let mut last_ok: Option<bool> = None;

    loop {
        std::thread::sleep(Duration::from_secs(10));
        let ok = fetch_overall_ok();
        if Some(ok) == last_ok {
            continue;
        }
        last_ok = Some(ok);
        let icon = if ok { &icon_on } else { &icon_off };
        if let (Some(icon), Some(tray)) = (icon, app.try_state::<TrayIcon>()) {
            let _ = tray.set_icon(Some(icon.clone()));
        }
    }
}

/// GET thô qua TCP tới `/api/tray-status` — tránh thêm dependency `reqwest`/`serde_json` chỉ để đọc
/// 1 field boolean; parse bằng cách tìm chuỗi con `"overallOk": true` (khớp đúng định dạng
/// `json.dumps()` mặc định của Python — separator `": "`, xem wizard.py).
fn fetch_overall_ok() -> bool {
    let Ok(mut stream) = std::net::TcpStream::connect(("127.0.0.1", 8899)) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let request = b"GET /api/tray-status HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    if stream.write_all(request).is_err() {
        return false;
    }
    let mut body = String::new();
    if stream.read_to_string(&mut body).is_err() {
        return false;
    }
    body.contains("\"overallOk\": true")
}

/// setup.sh/wizard.py cần ghi config.yaml/.env/venv NGAY CẠNH CHÍNH CHÚNG —
/// resource bundle (`bundle.resources` trong tauri.conf.json) nằm ở vị trí chỉ-đọc trên bản đã cài
/// (vd `/usr/lib/telecode/src/` trên .deb, root-owned) nên không thể chạy trực tiếp tại đó. Lần
/// chạy đầu tiên, copy toàn bộ resource "src/" sang `app_data_dir()/source` (ghi được, thuộc user
/// hiện tại) rồi mọi lần sau tái sử dụng bản copy này — config/venv/state của user sống sót qua các
/// lần update app (không bị ghi đè bởi bản resource mới trong installer kế tiếp; xem giới hạn ở
/// CLAUDE.md nếu cần buộc user "reset về bản gốc").
fn resolve_writable_source_dir(app: &tauri::App) -> Result<PathBuf, Box<dyn std::error::Error>> {
    let dest = app.path().app_data_dir()?.join("source");
    let bundled_src = app
        .path()
        .resolve("src", tauri::path::BaseDirectory::Resource)?;
    let bundled_version = app.package_info().version.to_string();
    let version_marker = dest.join(".bundle-version");

    if dest.is_dir() {
        let cached_version = std::fs::read_to_string(&version_marker).unwrap_or_default();
        if cached_version.trim() != bundled_version {
            refresh_cached_source(&bundled_src, &dest, &bundled_version, &version_marker)?;
        }
        return Ok(dest);
    }

    std::fs::create_dir_all(&dest)?;
    copy_dir_recursive(&bundled_src, &dest)?;
    std::fs::write(&version_marker, &bundled_version)?;
    migrate_legacy_config(&dest);
    Ok(dest)
}

/// Chạy khi `.bundle-version` khác version bundle đang chạy (vừa `dpkg -i` bản `.deb` mới, kể cả
/// qua tính năng "Cập nhật ứng dụng") — đồng bộ lại các file "code" (wizard.py/setup.sh/
/// scripts//assets/...) từ resource bundle mới NHẤT vào bản copy ghi-được. `copy_dir_recursive`
/// chỉ duyệt theo `bundled_src` nên chỉ ghi đè đúng các entry có trong đó — `config.yaml`/`.env`/
/// `venv/`/`logs/`/`.run/` (sinh ra bởi setup.sh, KHÔNG nằm trong bundled_src) không bị đụng tới,
/// giữ nguyên state/cấu hình user qua các lần update. Trước đây (không có cơ chế này) cache chỉ
/// copy đúng 1 lần lúc tạo — bản `.deb` mới không bao giờ tới được máy user đang chạy (gap đã ghi
/// trong CLAUDE.md, root cause khiến fix Codex 401 không áp dụng được tới máy đã cài từ trước).
fn refresh_cached_source(
    bundled_src: &Path,
    dest: &Path,
    bundled_version: &str,
    version_marker: &Path,
) -> Result<(), Box<dyn std::error::Error>> {
    copy_dir_recursive(bundled_src, dest)?;
    std::fs::write(version_marker, bundled_version)?;
    Ok(())
}

/// Bản cài `telecode` kiểu cũ (chạy trực tiếp qua systemd, không qua Tauri) quy ước clone vào
/// `~/telecode` — `config.yaml`/`.env` thật (OPENAI_API_KEY, GITHUB_COPILOT_PAT)
/// nằm ở đó, KHÁC với bản copy resource vừa tạo ở trên (rỗng, chỉ có giá trị placeholder từ
/// `config.example.yaml`). Không migrate sẽ khiến wizard báo "chưa cấu hình" dù máy đã cấu hình từ
/// trước (bug thật đã gặp khi chuyển sang gói Tauri) — Tailscale/code-server không bị ảnh hưởng vì
/// 2 mục đó check qua `shutil.which()`/systemd, không đọc file project. Chỉ chạy ĐÚNG 1 lần lúc tạo
/// `app_data_dir()/source` (không đụng tới ở các lần chạy sau).
fn migrate_legacy_config(dest: &Path) {
    let Some(home) = dirs_home() else { return };
    let legacy_dir = home.join("telecode");
    for name in ["config.yaml", ".env"] {
        let legacy_file = legacy_dir.join(name);
        if legacy_file.is_file() {
            let _ = std::fs::copy(&legacy_file, dest.join(name));
        }
    }
}

fn dirs_home() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
}

fn copy_dir_recursive(src: &Path, dst: &Path) -> std::io::Result<()> {
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        let dest_path = dst.join(entry.file_name());
        if file_type.is_dir() {
            std::fs::create_dir_all(&dest_path)?;
            copy_dir_recursive(&entry.path(), &dest_path)?;
        } else {
            std::fs::copy(entry.path(), &dest_path)?;
        }
    }
    Ok(())
}
