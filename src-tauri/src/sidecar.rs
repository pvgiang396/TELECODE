// Sidecar Python cho telecode — khác hẳn mô hình k8sql (1 server sidecar duy nhất phục vụ toàn
// bộ UI): ở đây có 2 tiến trình con độc lập, cả 2 đều chạy file .py THẬT trên đĩa qua
// `dispatcher.py`'s runpy (xem docstring sidecar/dispatcher.py để hiểu lý do KHÔNG freeze bot.py/
// wizard.py vào binary PyInstaller):
//   - "wizard-server": HTTP server cố định cổng 8899 (PORT trong wizard.py, không đổi được) — cửa
//     sổ chính trỏ WebviewUrl::External vào đây, y hệt cách wizard.py từng mở qua Chrome --app=.
//   - "bot": tiến trình long-polling Telegram, KHÔNG có HTTP endpoint để health-check — chỉ spawn
//     và log, coi là "chạy được" ngay khi spawn thành công (khác wizard-server phải đợi bind cổng).
//
// Trên Windows, KHÔNG có binary PyInstaller nào cho Windows (PyInstaller không cross-compile được —
// xem CLAUDE.md) — cả 2 tiến trình trên được gọi qua wsl_bridge.rs (spawn `wsl.exe` thay vì
// `.sidecar()`), tái dùng đúng binary Linux đã build sẵn, chạy BÊN TRONG WSL2 — đúng kiến trúc
// install.ps1 gốc vốn đã yêu cầu (code-server chưa từng chạy native trên Windows).
use std::path::Path;
use std::time::Duration;
use tauri::AppHandle;
use tauri_plugin_shell::process::{CommandChild, CommandEvent};
#[cfg(not(target_os = "windows"))]
use tauri_plugin_shell::ShellExt;

#[cfg(target_os = "windows")]
use crate::wsl_bridge;

pub struct SidecarChildren {
    pub wizard: CommandChild,
    pub bot: CommandChild,
}

macro_rules! log_child_events {
    ($label:expr, $mut_rx:expr) => {
        let mut rx = $mut_rx;
        let label = $label;
        tauri::async_runtime::spawn(async move {
            while let Some(event) = rx.recv().await {
                match event {
                    CommandEvent::Stdout(line) => {
                        println!("[telecode:{label}] {}", String::from_utf8_lossy(&line));
                    }
                    CommandEvent::Stderr(line) => {
                        eprintln!("[telecode:{label}:err] {}", String::from_utf8_lossy(&line));
                    }
                    CommandEvent::Terminated(payload) => {
                        println!("[telecode:{label}] terminated: {:?}", payload);
                    }
                    _ => {}
                }
            }
        });
    };
}

const WIZARD_PORT: u16 = 8899; // = PORT trong wizard.py, không tham số hoá được — xem sidecar/dispatcher.py

/// Spawn cả 2 sidecar (wizard-server + bot) chạy nhắm vào đúng bộ source thật tại `source_dir`
/// (bản copy ghi được trong app-data — xem `main.rs::resolve_writable_source_dir()`; KHÔNG chạy
/// thẳng trên resource bundle read-only) và ghi runtime state vào `run_dir`.
pub async fn spawn_all(
    app: &AppHandle,
    source_dir: &Path,
    run_dir: &Path,
) -> Result<SidecarChildren, String> {
    std::fs::create_dir_all(run_dir).map_err(|e| format!("Không tạo được RUN_DIR: {e}"))?;

    let wizard_py = source_dir.join("wizard.py");
    let bot_py = source_dir.join("bot.py");

    let wizard_args = vec![
        "wizard-server".to_string(),
        wizard_py.to_string_lossy().to_string(),
        run_dir.to_string_lossy().to_string(),
        source_dir.to_string_lossy().to_string(),
    ];
    let bot_args = vec!["bot".to_string(), bot_py.to_string_lossy().to_string()];

    let (wizard_rx, wizard_child) = spawn_sidecar(app, wizard_args)?;
    log_child_events!("wizard", wizard_rx);
    wait_until_port_open(WIZARD_PORT).await?;

    let (bot_rx, bot_child) = spawn_sidecar(app, bot_args)?;
    log_child_events!("bot", bot_rx);

    Ok(SidecarChildren {
        wizard: wizard_child,
        bot: bot_child,
    })
}

#[cfg(not(target_os = "windows"))]
fn spawn_sidecar(
    app: &AppHandle,
    args: Vec<String>,
) -> Result<
    (
        tauri::async_runtime::Receiver<CommandEvent>,
        CommandChild,
    ),
    String,
> {
    let mut cmd = app
        .shell()
        .sidecar("telecode-sidecar")
        .map_err(|e| format!("Không resolve được sidecar binary telecode-sidecar: {e}"))?
        .args(args)
        // wizard.py check biến này để KHÔNG tự mở thêm 1 cửa sổ trình duyệt (Tauri đã mở cửa sổ
        // native trỏ cùng URL) — xem comment trong wizard.py's main().
        .env("TELECODE_MANAGED", "1");

    // Tính năng "Cập nhật ứng dụng" (nút 🔄) chỉ hoạt động trên máy có sẵn git checkout nguồn
    // (giống K8SQL_SOURCE_DIR bên k8sql) — forward nguyên trạng từ env của chính tiến trình
    // Tauri (KHÔNG hardcode path, đúng rule cross-platform ở CLAUDE.md gốc). Máy không set biến
    // này (đa số máy user cài .deb bình thường) -> wizard.py tự báo lỗi rõ ràng khi bấm 🔄.
    if let Ok(source_dir) = std::env::var("TELECODE_SOURCE_DIR") {
        cmd = cmd.env("TELECODE_SOURCE_DIR", source_dir);
    }

    cmd.spawn()
        .map_err(|e| format!("Không spawn được sidecar: {e}"))
}

#[cfg(target_os = "windows")]
fn spawn_sidecar(
    app: &AppHandle,
    args: Vec<String>,
) -> Result<
    (
        tauri::async_runtime::Receiver<CommandEvent>,
        CommandChild,
    ),
    String,
> {
    wsl_bridge::spawn_via_wsl(app, args)
}

async fn wait_until_port_open(port: u16) -> Result<(), String> {
    let deadline = std::time::Instant::now() + Duration::from_millis(15_000);
    while std::time::Instant::now() < deadline {
        // std::net (blocking) thay vì tokio::net — tránh phải thêm dependency `tokio` riêng chỉ để
        // poll 1 cổng cố định vài giây lúc khởi động; chấp nhận block 1 worker thread ngắn hạn.
        if std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    Err(format!(
        "wizard-server không mở cổng {port} sau 15s — kiểm tra log [telecode:wizard]"
    ))
}

pub fn shutdown(children: SidecarChildren) {
    let _ = children.wizard.kill();
    let _ = children.bot.kill();
}
