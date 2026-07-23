# Cài đặt telecode trên Windows.
#
# code-server chỉ hỗ trợ chính thức Linux/macOS (xem docs code-server) -> trên Windows
# phải chạy qua WSL2. Script này tự kiểm tra/cài WSL (Ubuntu) nếu chưa có, rồi gọi lại
# scripts/install.sh (bash) bên trong WSL — không viết lại logic setup 2 lần.
#
# Chạy trong PowerShell (Run as Administrator nếu WSL chưa được cài):
#   powershell -ExecutionPolicy Bypass -Command "irm https://gitlab.com/pvgiang396/telecode/-/raw/main/scripts/install.ps1 | iex"

$ErrorActionPreference = "Stop"

function Test-WSLInstalled {
    try {
        $null = wsl.exe --status 2>$null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

if (-not (Test-WSLInstalled)) {
    Write-Host "== Chưa phát hiện WSL, đang cài (cần khởi động lại máy sau bước này) ==" -ForegroundColor Yellow
    wsl --install -d Ubuntu
    Write-Host ""
    Write-Host "WSL vừa được cài — hãy KHỞI ĐỘNG LẠI máy, mở lại 'Ubuntu' từ Start Menu để" -ForegroundColor Yellow
    Write-Host "hoàn tất tạo tài khoản Linux lần đầu, rồi chạy lại đúng lệnh PowerShell này." -ForegroundColor Yellow
    exit 0
}

Write-Host "== Cài đặt telecode bên trong WSL (Ubuntu) ==" -ForegroundColor Cyan
wsl -d Ubuntu -- bash -lc "curl -fsSL https://gitlab.com/pvgiang396/telecode/-/raw/main/scripts/install.sh | bash"

Write-Host ""
Write-Host "Xong. Bot Telegram và code-server đang chạy bên trong WSL." -ForegroundColor Green
Write-Host "Lưu ý: mỗi lần khởi động lại Windows, WSL không tự chạy nền các tiến trình này —" -ForegroundColor Yellow
Write-Host "mở lại 'Ubuntu' từ Start Menu và chạy lại đúng lệnh cài ở trên (idempotent, không hỏi lại token đã lưu)." -ForegroundColor Yellow
