// Entry point RIÊNG cho Android/iOS — KHÔNG liên quan gì tới src/main.rs (desktop Linux/Windows,
// vẫn giữ nguyên tray/sidecar Python/wizard-server như cũ). `cargo tauri android build` chạy
// `cargo build --lib` (JNI cần .so từ lib target, xem [lib] trong Cargo.toml) — main.rs là bin
// target riêng, không được Android build tới, nên desktop KHÔNG bị ảnh hưởng bởi file này.
//
// Khác desktop (mở cửa sổ trỏ thẳng wizard-server cục bộ 127.0.0.1:8899 — không có trên điện
// thoại), app mobile là 1 client thuần túy: người dùng tự nhập URL Tailscale của máy đang chạy
// code-server (vd https://<máy>.<tailnet>.ts.net), lưu vào localStorage của WEBVIEW (không cần
// plugin/IPC Tauri nào) rồi hiển thị qua <iframe> trong 1 trang tĩnh bundle sẵn
// (`frontend-placeholder/index.html`, dùng lại đúng thư mục `frontendDist` desktop đã khai nhưng
// không dùng tới — an toàn). Lý do dùng app riêng thay vì Telegram Mini App WebView: webview của
// app này KHÔNG có JS bridge/chrome nào của bên thứ 3 (Telegram) can thiệp viewport/resize — xem
// phân tích chi tiết trong CLAUDE.md mục "Tauri Android".

#[cfg_attr(any(target_os = "android", target_os = "ios"), tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            tauri::WebviewWindowBuilder::new(
                app,
                "main",
                tauri::WebviewUrl::App("index.html".into()),
            )
            .build()?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("Lỗi khi chạy telecode (mobile)");
}
