// telecode — Tauri shell. Kế thừa nguyên vẹn bot.py/wizard.py/setup.sh từ telecode (xem
// sidecar/dispatcher.py + CLAUDE.md) — module này chỉ lo: cửa sổ, tray, spawn/kill 2 sidecar
// (wizard-server phục vụ UI cài đặt, bot chạy nền Telegram polling), copy resource bundle
// (read-only) ra 1 bản ghi được trong app-data lúc chạy lần đầu (setup.sh cần ghi config.yaml/.env/
// venv cạnh chính nó — không ghi được vào /usr/lib/telecode/... trên .deb đã cài).
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod sidecar;
#[cfg(target_os = "windows")]
mod wsl_bridge;

use std::path::{Path, PathBuf};
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
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

            let open_item = MenuItem::with_id(app, "open", "Open", true, None::<&str>)?;
            let exit_item = MenuItem::with_id(app, "exit", "Exit", true, None::<&str>)?;
            let tray_menu = Menu::with_items(app, &[&open_item, &exit_item])?;

            TrayIconBuilder::new()
                .icon(app.default_window_icon().unwrap().clone())
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
                })
                .build(app)?;

            let source_dir = resolve_writable_source_dir(app)?;
            let run_dir = app.path().app_data_dir()?.join("run");

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

/// setup.sh/bot.py/wizard.py cần ghi config.yaml/.env/state.json/venv NGAY CẠNH CHÍNH CHÚNG —
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
/// qua tính năng "Cập nhật ứng dụng") — đồng bộ lại các file "code" (bot.py/wizard.py/setup.sh/
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
/// `~/telecode` — `config.yaml`/`.env` thật (token bot Telegram, OPENAI_API_KEY, GITHUB_COPILOT_PAT)
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
