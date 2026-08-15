// CHỈ dùng trên Windows — CHƯA tự verify được trên máy Windows+WSL2 thật (máy dev chỉ có Linux),
// xem CLAUDE.md mục "Windows/WSL2 — provisional, chưa verify" trước khi tin tưởng module này.
//
// Ý tưởng: binary telecode-sidecar chỉ build được cho Linux (PyInstaller không cross-compile —
// xem CLAUDE.md gốc). Trên Windows, thay vì spawn .sidecar() (không tồn tại bản Windows), gọi thẳng
// `wsl.exe` có sẵn trên mọi máy Windows 11 hiện đại, chạy binary Linux đó BÊN TRONG WSL2 — đúng kiến
// trúc `install.ps1` gốc vốn đã yêu cầu WSL2 (code-server không chạy native Windows).
//
// Giả định CHƯA kiểm chứng: binary `telecode-sidecar` (Linux) + toàn bộ source tree
// (wizard.py/scripts/assets) đã được đặt sẵn tại `~/.local/share/telecode/source` BÊN
// TRONG distro WSL2 mặc định — bước "provision vào WSL2 lúc cài đặt lần đầu" CHƯA triển khai ở đây,
// cần làm thêm 1 bước cài đặt riêng (tương tự install.ps1 cũ tự bootstrap WSL2 rồi git clone) trước
// khi module này có thể chạy đúng trên máy thật.
use std::path::Path;
use tauri::AppHandle;
use tauri_plugin_shell::process::{CommandChild, CommandEvent};
use tauri_plugin_shell::ShellExt;

/// Đường dẫn source bên TRONG WSL2 — khác hẳn Windows app-data dir (2 filesystem tách biệt), xem
/// ghi chú đầu file.
const WSL_SOURCE_DIR: &str = "$HOME/.local/share/telecode/source";
const WSL_SIDECAR_BIN: &str = "$HOME/.local/share/telecode/bin/telecode-sidecar";

/// `spawn_sidecar()` trong sidecar.rs gọi hàm này thay vì `.sidecar()` khi target_os = "windows".
/// Nhận `args` đã tính theo quy ước Windows Path (sidecar.rs's `source_dir.join(...)`) — nhưng path
/// đó KHÔNG dùng được bên trong WSL, nên hàm này bỏ qua `args` gốc và tự dựng lại đường dẫn WSL
/// tương ứng theo subcommand đầu tiên. Cách này chỉ đúng cho subcommand cố định (wizard-server) mà
/// sidecar.rs hiện gọi — không tổng quát cho subcommand tuỳ ý.
pub fn spawn_via_wsl(
    app: &AppHandle,
    args: Vec<String>,
) -> Result<(tauri::async_runtime::Receiver<CommandEvent>, CommandChild), String> {
    let subcommand = args.first().cloned().unwrap_or_default();
    let wsl_args: Vec<String> = match subcommand.as_str() {
        "wizard-server" => vec![
            "wizard-server".to_string(),
            format!("{WSL_SOURCE_DIR}/wizard.py"),
            "/tmp/telecode-run".to_string(),
            WSL_SOURCE_DIR.to_string(),
        ],
        other => return Err(format!("wsl_bridge: subcommand không hỗ trợ: {other}")),
    };

    let distro = std::env::var("TELECODE_WSL_DISTRO").ok();
    let mut wsl_command_args: Vec<String> = Vec::new();
    if let Some(d) = distro {
        wsl_command_args.push("-d".to_string());
        wsl_command_args.push(d);
    }
    wsl_command_args.push("--".to_string());
    wsl_command_args.push(WSL_SIDECAR_BIN.to_string());
    wsl_command_args.extend(wsl_args);

    app.shell()
        .command("wsl.exe")
        .args(wsl_command_args)
        .spawn()
        .map_err(|e| format!("Không spawn được qua wsl.exe (đã cài WSL2 + provision telecode chưa? xem CLAUDE.md): {e}"))
}

/// Chưa gọi ở đâu — placeholder cho bước "provision vào WSL2 lúc cài đặt lần đầu" (copy resource
/// bundle Windows sang bên trong WSL2 qua UNC path `\\wsl$\<distro>\...`, rồi build/copy
/// telecode-sidecar). Để lại chữ ký hàm ở đây làm điểm bắt đầu cho phiên làm việc sau.
#[allow(dead_code)]
pub fn ensure_provisioned(_app: &AppHandle, _windows_resource_dir: &Path) -> Result<(), String> {
    Err("wsl_bridge::ensure_provisioned() chưa triển khai — xem ghi chú đầu file".to_string())
}
