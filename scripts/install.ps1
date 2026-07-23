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

# Shortcut Desktop mở VS Code (code-server) từ phía Windows — WSL2 tự forward
# localhost sang Windows host (localhostForwarding, bật mặc định) nên
# http://localhost:8443 mở thẳng từ trình duyệt Windows là vào được code-server
# đang chạy trong WSL, không cần biết địa chỉ IP của WSL.
#
# Dùng .lnk (không phải .url) để: (1) gắn được icon riêng (icon.ico bundle sẵn
# trong repo, đọc qua đường dẫn UNC \\wsl$\...), (2) mở Edge ở chế độ --app= (ẩn
# thanh địa chỉ, giống app desktop thật) thay vì mở tab trình duyệt thường.
$desktop = [Environment]::GetFolderPath("Desktop")
$shortcutPath = Join-Path $desktop "VS Code (code-server).lnk"

$wslUser = (wsl -d Ubuntu -- whoami 2>$null).Trim()
$iconPath = if ($wslUser) { "\\wsl$\Ubuntu\home\$wslUser\telecode\assets\icon.ico" } else { $null }

$edgeCandidates = @(
    "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
)
$edgeBin = $edgeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut($shortcutPath)
if ($edgeBin) {
    $Shortcut.TargetPath = $edgeBin
    $Shortcut.Arguments = "--app=http://localhost:8443"
} else {
    # Không tìm thấy Edge -> fallback mở bằng trình duyệt mặc định (tab thường, có address bar)
    $Shortcut.TargetPath = "http://localhost:8443"
}
if ($iconPath -and (Test-Path $iconPath -ErrorAction SilentlyContinue)) {
    $Shortcut.IconLocation = $iconPath
}
$Shortcut.Save()
Write-Host "Đã tạo shortcut Desktop: $shortcutPath" -ForegroundColor Green

Write-Host ""
Write-Host "Xong. Bot Telegram và code-server đang chạy bên trong WSL." -ForegroundColor Green
Write-Host "Lưu ý: mỗi lần khởi động lại Windows, WSL không tự chạy nền các tiến trình này —" -ForegroundColor Yellow
Write-Host "mở lại 'Ubuntu' từ Start Menu và chạy lại đúng lệnh cài ở trên (idempotent, không hỏi lại token đã lưu)." -ForegroundColor Yellow
