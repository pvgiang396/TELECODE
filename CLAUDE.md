# 🤖 Project Guide for Claude AI

Hướng dẫn toàn diện giúp Claude (hoặc bất kỳ AI nào) hiểu cấu trúc project và có thể phát triển tiếp.

## 📌 Mục Đích Project

Project này là một Telegram Mini App cho phép người dùng:
1. Mở VS Code từ điện thoại qua Telegram
2. Điều khiển VS Code Server trên máy tính từ xa
3. Sử dụng Claude for VS Code Extension để coding từ xa
4. Giao việc cho AI mà không cần mở terminal trên điện thoại

## 🏗️ Kiến Trúc Hệ Thống

```
┌─────────────────────────────────────────────────────────────┐
│                      Telegram Client                        │
│                   (User's Smartphone)                       │
└────────────────────────┬────────────────────────────────────┘
                         │ (HTTPS)
                         ↓
┌─────────────────────────────────────────────────────────────┐
│                 Telegram Mini App                           │
│                 (mini_app.html)                             │
│         ● WebApp UI ● Iframe loader ● Status               │
└────────────────────────┬────────────────────────────────────┘
                         │ (HTTPS)
                         ↓
┌─────────────────────────────────────────────────────────────┐
│              Internet Tunnel Layer                          │
│         ● Tailscale Funnel (URL cố định, dùng hiện tại)     │
└────────────────────────┬────────────────────────────────────┘
                         │ (Local network)
                         ↓
┌─────────────────────────────────────────────────────────────┐
│              VS Code Server (code-server)                   │
│         ● Runs on localhost:8443                           │
│         ● Serves VS Code in browser                        │
└────────────────────────┬────────────────────────────────────┘
                         │ (VS Code API)
                         ↓
┌─────────────────────────────────────────────────────────────┐
│          Claude for VS Code Extension                       │
│    ● Processes user requests                               │
│    ● Generates code suggestions                            │
│    ● Integrates with VS Code editor                        │
└─────────────────────────────────────────────────────────────┘
```

## 📦 Cài đặt

Repo public tại `gitlab.com/pvgiang396/telecode` (SSH cho push, HTTPS cho clone/curl công khai — chỉ chủ tài khoản mới push được).

- Linux/macOS: `curl -fsSL https://gitlab.com/pvgiang396/telecode/-/raw/main/scripts/install.sh | bash` → `scripts/install.sh` clone/pull về `~/telecode` (hoặc `$TELECODE_DIR`) rồi `exec bash setup.sh`.
- Windows: `scripts/install.ps1` (code-server không hỗ trợ Windows native) — tự cài WSL2/Ubuntu nếu chưa có rồi gọi lại `install.sh` bên trong WSL, không viết lại logic setup riêng cho Windows.
- `setup.sh` (root project) là script idempotent chính: cài code-server + Tailscale, patch trang login code-server thêm icon hiện/ẩn mật khẩu (xem dưới), cài sẵn extension GitHub Copilot + Copilot Chat (xem mục riêng bên dưới), tạo password, chạy code-server nền qua `systemd --user` (mở đúng `$CODE_SERVER_WORKSPACE`, mặc định `~/Code` — KHÔNG mở cả `$HOME`, tránh lộ toàn bộ home directory qua Mini App; xem chi tiết ở bullet riêng bên dưới), bật Tailscale Funnel cho code-server, hỏi Telegram Bot Token, ghi `config.yaml`, hỏi khôi phục cấu hình AI tool qua Telegram (xem mục riêng bên dưới), cài Python deps (venv), chạy `bot.py` nền. Trạng thái tiến trình lưu PID ở `.run/` (gitignored, chỉ để tương thích hiển thị khi chạy qua systemd — xem bullet riêng) — chạy lại an toàn, không tạo tiến trình trùng lặp. Đổi mật khẩu code-server (bước 2) tự ép restart code-server (bước 3) — code-server chỉ đọc `config.yaml` lúc khởi động, không restart thì tiến trình cũ vẫn giữ mật khẩu cũ trong bộ nhớ dù file đã ghi giá trị mới.
- **Bước 3 (chạy code-server) ưu tiên `systemd --user`, giống hệt pattern bot ở bullet dưới — ĐÃ FIX bug thật gây mất đăng nhập GitHub Copilot/Gemini mỗi khi "đóng mở lại telecode"**: gói `.deb` code-server cài kèm sẵn 1 unit `systemd --user` riêng (`/usr/lib/systemd/user/code-server.service`, `Restart=always`, `WantedBy=default.target`, tự bật ở nhiều máy) — unit này **tranh nhau** quản lý cùng 1 tiến trình code-server với `nohup code-server ...` cũ của `setup.sh` (cả 2 đọc chung `~/.config/code-server/config.yaml` nên khó nhận ra là 2 cơ chế khác nhau); mỗi lần máy reboot/logout/crash, systemd tự spin lên 1 process **hoàn toàn mới**, và **đã xác nhận qua log thật** (`GitHub Authentication.log`, dòng `Got 0 sessions` ngay sau mỗi process mới) + snapshot file thay đổi lúc đăng nhập thành công (không có file nào được ghi xuống đĩa, kể cả `state.vscdb`, `secrets.json`, `~/.config/gh/hosts.yml`, `~/.copilot/*`) rằng **session GitHub OAuth của extension built-in `vscode.github-authentication` (dùng chung cho Copilot/Gemini "Use AI Features") chỉ tồn tại trong bộ nhớ tiến trình, KHÔNG có backend keytar/libsecret nào** (`package.json` của code-server không có dependency `keytar`) — dù `gnome-keyring-daemon` có chạy sẵn và D-Bus secret service khả dụng trong đúng session cũng KHÔNG giúp được gì, vì code-server không hề gọi tới nó cho việc này. **Giới hạn còn lại, CHƯA giải quyết được cho Copilot Chat/completions**: kể cả sau khi thống nhất về đúng 1 process qua `systemd --user` (giảm hẳn tần suất restart), mỗi lần code-server THỰC SỰ phải restart (reboot máy, `systemctl --user restart code-server`, crash) thì user vẫn phải đăng nhập lại Copilot Chat/completions từ đầu — không có cách nào persist session OAuth này ở tầng script/config vì nó không hề chạm tới filesystem. **Đã giải quyết riêng cho nhánh agent "Copilot CLI"** bằng PAT thay vì OAuth — xem bullet Bước 6c bên dưới. Đã sinh unit `~/.config/systemd/user/code-server.service` qua hàm `start_code_server()`/`stop_code_server()`/`is_code_server_alive()` trong `setup.sh` (`ExecStart=$(command -v code-server) --bind-addr 127.0.0.1:8443 $CODE_SERVER_WORKSPACE`, `EnvironmentFile=-$RUN_DIR/code-server.env` — nạp PAT của Bước 6c nếu có, dấu `-` để không lỗi khi file chưa tồn tại, `Restart=always`, `RestartSec=3`, log `logs/code-server.log`) — theo thứ tự tìm unit của systemd, file này tự động ĐÈ lên bản `/usr/lib/systemd/user` cùng tên sau `daemon-reload`, không cần mask/disable riêng. `is_code_server_alive()` trong `setup.sh` và `probe_status()` trong `wizard.py` đều ưu tiên `systemctl --user is-active code-server`, fallback PID file (`.run/code-server.pid`, lỗi thời ngay sau lần `Restart=always` kế tiếp) nếu không có systemd.
- **Bước 9 (chạy `bot.py`) ưu tiên `systemd --user` (Linux có systemd)** — unit `~/.config/systemd/user/telecode-bot.service` sinh động bởi `setup.sh` (`ExecStart=$VENV_PY $DIR/bot.py`, `Restart=always`, `RestartSec=3`, log nối vào `logs/bot.log` qua `StandardOutput=append:...`) — tự hồi sinh khi bot crash vì **bất kỳ lý do gì** (đã verify bằng `kill -9` PID thật, systemd tự start lại PID mới trong ~3s). `is_bot_alive()` trong `setup.sh` kiểm tra `systemctl --user is-active` thay vì đọc PID file khi dùng systemd — file `.run/bot.pid` lúc này chỉ để tương thích hiển thị (ghi qua `systemctl --user show ... -p MainPID`), **lỗi thời ngay sau lần Restart=always kế tiếp**, không dùng để quyết định alive nữa. `wizard.py`'s `probe_status()` cũng ưu tiên `systemctl --user is-active`/`MainPID` nếu file unit tồn tại, fallback PID-file cũ nếu không. Máy chủ 24/7 (VPS/Oracle Cloud) cần thêm `loginctl enable-linger $(whoami)` (setup.sh tự nhắc nếu chưa bật) để service sống được cả khi không có session đăng nhập nào — **áp dụng chung cho cả code-server** (bullet trên), không chỉ bot. macOS hoặc máy không có `systemd --user` thật (`systemctl --user show-environment` fail) → fallback `setsid nohup ... &` (không chỉ `nohup`) — bug thật đã gặp trước khi có systemd: chỉ `nohup` không tách session, terminal/session cha đóng đột ngột có thể kill theo cả tiến trình `nohup` con (nohup chỉ chặn SIGHUP). Nhánh fallback này CHỈ chống được đúng nguyên nhân đó, không tự phục hồi được các crash khác — đây là lý do systemd được ưu tiên khi khả dụng.
- **Bước 1e — GitHub Copilot + Copilot Chat cài sẵn mặc định** (`install_vsix_extension()` trong `setup.sh`): code-server dùng Open VSX làm marketplace mặc định, nhưng GitHub chỉ publish 2 extension này lên Visual Studio Marketplace chính thức (không có trên Open VSX) — không cài được qua UI Extensions bình thường. Script tải thẳng `.vsix` qua API `https://marketplace.visualstudio.com/_apis/public/gallery/publishers/{publisher}/vsextensions/{name}/latest/vspackage` rồi sideload bằng `code-server --install-extension --force`. **`curl` bắt buộc có cờ `--compressed`** — CDN Marketplace trả file kèm `content-encoding: gzip`, thiếu cờ này curl lưu thẳng byte gzip thô (không phải zip hợp lệ) xuống `.vsix`, khiến `code-server --install-extension` lỗi (bug thật đã gặp: do không kiểm tra exit code nên script vẫn báo "Đã cài" dù cài thất bại — nay đã bắt exit code và `warn` nếu lỗi).
- **Bước 6b — Codex CLI (Gemini qua 9Router), tuỳ chọn**: `setup.sh` hỏi `OPENAI_API_KEY` (đặt sau bước 6 Telegram token, để trống = bỏ qua, chạy lại setup.sh sau để bổ sung — dùng đúng `ask_value` với key `openaiApiKey`, không phải cơ chế mới). Nếu có giá trị: cài extension `openai.chatgpt` (Codex) — extension này CÓ trên Open VSX (marketplace mặc định code-server), nên cài thẳng bằng `code-server --install-extension openai.chatgpt --force`, KHÔNG qua `install_vsix_extension()` (hàm đó chỉ dành cho extension chỉ có trên VS Marketplace như Copilot). Ghi `~/.codex/config.toml` (model/base_url/wire_api cố định, trỏ "9Router" — proxy OpenAI-compatible dùng chung của team, xem `temp/huongdan.md` gốc) và `~/.codex/auth.json` (`{"auth_mode":"apikey","OPENAI_API_KEY":"..."}`, `chmod 600`). Giá trị `OPENAI_API_KEY` được lưu vào `config.yaml` (giữ nguyên khi để trống ở lần chạy sau, đúng convention `ask_value` chung). GUI wizard có field riêng (`openaiApiKey`, không `required`) — xem `assets/wizard.html`/`wizard.py`. `~/.codex/config.toml` + `~/.codex/auth.json` cũng đã thêm vào allowlist `scripts/backup-ai-configs.sh` và điều kiện hỏi khôi phục ở bước 7b.
- **Bước 6c — GitHub Copilot CLI qua PAT, tuỳ chọn — thay OAuth cho ĐÚNG 1 nhánh "Copilot CLI"**: agent picker của Gemini Code Assist ("Local"/"Copilot CLI"/"Cloud") có nhánh "Copilot CLI" spawn tiến trình con chạy binary `copilot` (npm `@github/copilot`, qua shim `copilotCLIShim.js` trong globalStorage của `github.copilot-chat`) — **hoàn toàn tách biệt** khỏi extension `github.copilot`/`github.copilot-chat` chính (dùng OAuth session của `vscode.github-authentication`, chỉ sống trong bộ nhớ tiến trình code-server, mất mỗi lần restart — xem giới hạn đã ghi ở bullet Bước 3). README chính thức `@github/copilot` xác nhận CLI này nhận **fine-grained PAT** (quyền "Copilot Requests", tạo tại `github.com/settings/personal-access-tokens/new`) không tương tác qua biến môi trường `GH_TOKEN`/`GITHUB_TOKEN` (theo thứ tự ưu tiên). Vì `copilot` là con của chính tiến trình code-server nên chỉ cần PAT có mặt trong environment của code-server là đủ — `setup.sh` hỏi `GITHUB_COPILOT_PAT` (`ask_value`, key `githubCopilotPat`, để trống = bỏ qua) rồi ghi `GH_TOKEN=...` vào `$RUN_DIR/code-server.env` (`chmod 600`, gitignored qua `.run/`) — unit `code-server.service` (bullet Bước 3) nạp file này qua `EnvironmentFile=-$CS_ENV_FILE` (dấu `-` = không lỗi nếu chưa có PAT). PAT đổi → so sánh nội dung cũ/mới, chỉ restart code-server khi thật sự đổi (tái dùng `start_code_server()`/`stop_code_server()`/`is_code_server_alive()` đã tách hàm ở Bước 3). **Giới hạn**: chỉ fix persistence cho nhánh "Copilot CLI" (agent kiểu terminal, không có inline completion) — Copilot Chat panel/completions gốc trong VS Code vẫn phải OAuth lại mỗi lần restart như cũ, PAT không thay thế được OAuth ở đó. Field GUI tương ứng trong `assets/wizard.html`/`wizard.py` (`githubCopilotPat`, không `required`) — hint có 2 link: link GitHub mở tab thường (`target="_blank"`), link "Click vào đây" mở `assets/pat-guide.html` (2 ảnh minh hoạ `pat-guide-1.jpg`/`pat-guide-2.jpg`, serve qua route riêng trong `wizard.py`'s `do_GET`, cùng khuôn với route `/icon.png` có sẵn) bằng `window.open(...,'toolbar=no,location=no,status=no,menubar=no')` — dạng popup ẩn thanh địa chỉ, không phải tab thường; `pat-guide.html` cũng tự chặn `contextmenu` (chuột phải), cùng pattern `wizard.html` đã dùng cho trang login code-server (xem mục login/favicon).
- **code-server bản mới (dựa VS Code core ≥1.99) đã bundle sẵn Copilot Chat làm built-in extension** (`{root}/lib/vscode/extensions/copilot`, package name `copilot-chat`, publisher GitHub — giống cách VS Code chính thức bundle Copilot Chat trong lõi từ bản gần đây) — không hiện trong tìm kiếm Extensions Marketplace (built-in không lấy từ gallery) và **không cần/không nên sideload `.vsix` đè lên** vì bản built-in thường mới hơn bản tải từ Marketplace. `code-server --install-extension` trả lỗi `Incompatible: ... is a built-in extension ... cannot be downgraded` trong trường hợp này — `install_vsix_extension()` bắt đúng pattern này và coi là **thành công** (đã có sẵn), không phải lỗi thật. `github.copilot` (phần completions, khác `copilot-chat`) thường KHÔNG built-in, vẫn cần sideload bình thường. Nếu bản built-in đã đăng nhập sẵn (dùng chung phiên GitHub auth của VS Code, kiểm tra qua log `~/.local/share/code-server/logs/<phiên>/exthost*/GitHub.copilot-chat/GitHub Copilot Chat.log` tìm dòng `Logged in as ...`/`copilot token sku: ...`) — lệnh "GitHub Copilot: Sign In" của extension `github.copilot` (completions) **sẽ không hiện** trong Command Palette (`enablement: "!github.copilot.activated"` trong package.json — chỉ hiện khi CHƯA đăng nhập, không phải bug). Mở Copilot Chat lúc này bằng `Ctrl+Alt+I` hoặc Command Palette → "Chat: Open Chat", không phải tìm "Sign In". Cài **mặc định, không hỏi** (khác các bước "giữ nguyên/cài lại" khác) — người chưa có quota Copilot vẫn cài extension bình thường, chỉ không đăng nhập được (không lỗi setup, tự bỏ qua nếu tải mạng thất bại). Đã cài rồi thì theo pattern chung: `ask_choice` menu "Giữ nguyên/Cài lại" (key `copilotExtAction`, GUI wizard **chưa có toggle riêng** cho bước này — vì mặc định không hỏi nên không cần thêm field). Đăng nhập là bước tay của người dùng sau: Command Palette → "GitHub Copilot: Sign In" (dùng account có quota công ty cấp).
- **Tunnel: Tailscale Funnel (không phải cloudflared quick tunnel nữa)** — lý do đổi: `cloudflared tunnel --url` sinh URL `*.trycloudflare.com` NGẪU NHIÊN mỗi lần restart, không đủ để bot chọn giữa nhiều máy đang chạy. Tailscale Funnel cho URL cố định vĩnh viễn `https://<hostname>.<tailnet>.ts.net` theo tên máy trong tailnet. Máy có GUI: `tailscale up` mở trình duyệt login 1 lần; máy headless (server SSH-only, vd Oracle Cloud): cần `TAILSCALE_AUTHKEY` (tạo tại `https://login.tailscale.com/admin/settings/keys`) truyền qua env var, không cần trình duyệt. `setup.sh` (bản Tailscale ≥1.9x) chỉ dùng đúng 1 lệnh `tailscale funnel --bg 8443` để expose code-server (không cần `tailscale serve` riêng nữa) — **cú pháp CLI serve/funnel đổi theo phiên bản Tailscale**, nếu lệnh trong `setup.sh` lỗi thì kiểm tra `tailscale serve --help`/`tailscale funnel --help` trên máy thật và chỉnh lại. **Bug thật đã gặp** (Tailscale 1.98.9): `<target>` của cả `serve` lẫn `funnel` giờ là **local port**, không phải cổng public như cú pháp cũ — chạy `tailscale funnel --bg 443` (tưởng "bật funnel ở cổng public 443") thực chất tạo 1 cấu hình serve+funnel MỚI trỏ vào cổng nội bộ 443 (không có gì lắng nghe), ĐÈ mất cấu hình `serve 8443` đã set trước đó, gây `HTTP ERROR 502` khi mở URL từ điện thoại dù code-server local vẫn chạy bình thường. Fix: `tailscale funnel reset` rồi `tailscale funnel --bg 8443` (đúng local port của code-server) — kiểm tra bằng `tailscale serve status --json`, field `Web.*.Handlers./.Proxy` phải là `http://127.0.0.1:8443`. **`setup.sh` tự verify end-to-end sau khi cấu hình** (không chỉ tin lệnh chạy xong không báo lỗi — đúng bug vừa nêu trên: lệnh sai vẫn "chạy xong" bình thường): `curl` thẳng `$VSCODE_PUBLIC_URL` (retry tới 10 lần, mỗi lần cách 1s vì Funnel/cert có thể mất vài giây để áp dụng), nếu HTTP code là `000`/`502`/`503`/`504` thì `err` + in sẵn lệnh debug (`tailscale serve status --json` + lệnh reset/reconfigure) rồi `exit 1` — không để `setup.sh` báo "✅ OK" trong khi Funnel thực chất chưa hoạt động, tình huống người dùng thường (không tự debug được như phiên troubleshoot gốc) sẽ gặp phải nếu thiếu bước verify này. **Khoảng trống còn lại, CHƯA xử lý**: bước verify chỉ *phát hiện* lỗi (báo rõ + dừng script), KHÔNG *tự sửa* được — nếu Tailscale ra bản mới đổi cú pháp `serve`/`funnel` theo cách khác hẳn (không chỉ đổi ý nghĩa target như lần này mà đổi tên subcommand/flag), người dùng thường vẫn cần liên hệ hỗ trợ khi gặp lỗi đó, `setup.sh` không tự dò/thử nhiều cú pháp để tự phục hồi. Cân nhắc hướng xử lý sau: parse `tailscale --version` để chọn nhánh cú pháp tương ứng, hoặc thử lần lượt vài cú pháp ứng viên khi cú pháp chính thất bại. `wizard.html`/`wizard.py` (GUI path) có toggle riêng cho Tailscale (`tailscaleAction`, probe `tailscale version`) và Tailscale Funnel (`funnelAction`, probe `tailscale funnel status` chứa `127.0.0.1:8443` + URL qua `tailscale status --json` field `Self.DNSName`) — **đã fix bug thật**: bản cũ (từ thời còn cloudflared) hiển thị nhầm `cloudflaredAction`/`tunnelAction` (đọc PID file `tunnel-code.pid`/log `tunnel-code.log` không còn ai ghi từ khi đổi sang Tailscale) — dead code chưa dọn khi migrate, khiến màn wizard luôn hiện "cloudflared" dù `setup.sh` đã bỏ hẳn cloudflared.
- **Đa máy cùng chạy telecode (multi-server)**: vì mọi máy join chung 1 tailnet, `bot.py` gọi `tailscale status --json` (lệnh cục bộ, không cần đăng ký thủ công) để tự liệt kê máy đang online, health-check từng URL rồi trả về nút mở thẳng (nếu chỉ 1 máy sống) hoặc inline keyboard chọn máy (nếu ≥2 máy sống) khi nhận `/start`. Không có registry/state riêng cho danh sách server — luôn tính động mỗi lần `/start`. Logic health-check dùng chung qua hàm `discover_alive_servers()`.
- **Menu button (icon cạnh khung nhập tin nhắn Telegram)**: `post_init()` cũng gọi `discover_alive_servers()` lúc bot khởi động — nếu đúng **1 máy online**, đặt `MenuButtonWebApp` trỏ thẳng URL đó (icon 1-chạm, không cần gõ `/start`); nếu **0 hoặc ≥2 máy online**, fallback `MenuButtonCommands` (icon danh sách lệnh, `/start` là điểm vào) vì 1 icon tĩnh không đại diện được nhiều lựa chọn. Icon chỉ phản ánh đúng trạng thái tại **thời điểm bot khởi động** — nếu server nào online thay đổi sau đó, `/start` vẫn luôn đúng nhưng icon menu không tự cập nhật cho tới lần bot restart kế tiếp (Telegram không có API "resolve URL lúc bấm" cho menu button).
- **Đồng bộ cấu hình AI CLI tool (claude/gh copilot/gemini/deepseek) giữa các máy**: `/backup_configs <passphrase>` (chỉ chủ sở hữu — xem `OWNER_CHAT_ID`/`state.json` ở mục Security bên dưới) đóng gói (`scripts/backup-ai-configs.sh`, tar các file tồn tại trong danh sách allowlist cứng theo tool) + mã hoá `gpg --symmetric AES256` (passphrase KHÔNG suy ra từ bot token) rồi gửi lại vào chat dưới dạng file `.gpg`. Máy đích (`setup.sh`, bước 7b) mở 1 HTTP receiver 1-lần-dùng (`scripts/receive-ai-configs.py`, stdlib `http.server`, không thêm dependency) qua path riêng trên chính Tailscale Funnel đã bật — người dùng tải file `.gpg` Telegram gửi về rồi chạy 1 lệnh `curl` in sẵn (kèm mã 1-lần-dùng) để đẩy sang máy đích, `setup.sh` tự giải mã + giải nén đúng vị trí gốc + `chmod 600` cho file credentials. **Giới hạn nền tảng quan trọng**: Telegram Bot API không có API đọc lịch sử chat, bot không nhận lại được chính file nó vừa gửi — nên bước "máy nguồn gửi → máy đích tự động nhận" không thể tự động 100%, luôn cần đúng 1 bước tay (tải file Telegram về + chạy lệnh curl in sẵn).
- **Wizard cài đặt qua web** (thay hỏi terminal): `wizard.py` (stdlib `http.server`, không thêm dependency) serve `assets/wizard.html` (1 file tĩnh, inline CSS/JS, không framework — pattern giống `yan2ai/public/setup.html`) tại `127.0.0.1:8899`. `setup.sh` detect GUI (`$DISPLAY`/`$WAYLAND_DISPLAY`, macOS luôn true, hoặc WSL qua `grep microsoft /proc/version`) — có GUI thì mở `wizard.py` (foreground, chờ user submit, truyền thêm `$PPID` làm `caller_pid` — xem mục tự đóng terminal bên dưới), ghi câu trả lời vào `$RUN_DIR/wizard-answers.json`, rồi tự thoát; `setup.sh` đọc file đó, re-exec chính nó ở nền với `TELECODE_APPLYING=1` (biến này khiến `ask_value`/`ask_choice` đọc từ JSON qua hàm `answers_get()` thay vì hỏi qua `/dev/tty`, dùng chung 100% logic 9 bước cũ không cần viết lại), rồi `exit 0` ngay. Không có GUI (server/VPS headless) → giữ nguyên luồng hỏi qua terminal cũ, không đổi gì.
- **4 mục "đã cài/đang chạy" thu gọn** trong `wizard.html` (`codeServerAction`, `codeServerRunAction`, `tailscaleAction`, `funnelAction` — đúng 4 mục luôn mặc định "Giữ nguyên") dùng `subRadioGroup()` (native `<details>/<summary>` bọc ngoài, không cần JS toggle riêng) thay vì `radioGroup()` thường. `password`/`token`/`botAction` vẫn hiển thị đầy đủ, không thu gọn.
- **Cài xong tự động (chỉ khi qua wizard web)**: bước cuối `setup.sh` (nhánh `TELECODE_APPLYING=1`, sau khi bot chạy xong) làm theo đúng thứ tự: (1) tự mở app Telecode — gọi `resolve_app_mode_browser_bin()` + `--app=http://localhost:8443` giống hệt lúc bấm shortcut Desktop; (2) tự đóng terminal — `setup.sh` lấy `$PPID` lúc mở wizard (PID shell cha — do `install.sh` dùng `exec bash setup.sh` nên PID không đổi xuyên suốt, `$PPID` chính là shell tương tác gõ lệnh), truyền làm argv thứ 3 cho `wizard.py`; `wizard.py` lưu PID này vào `wizard-answers.json` dưới key `_callerPid` **ở phía server** (từ argv, không lấy field cùng tên nếu client gửi lên trong form — tránh giả mạo); đọc lại `_callerPid` và `kill` nếu process còn sống — không hỏi xác nhận. Thứ tự bắt buộc mở app TRƯỚC rồi mới kill terminal — nếu đảo ngược, tiến trình cha có thể chết trước khi kịp mở app. Nhánh headless không có PID này (không qua wizard nên không áp dụng). Tab wizard cũng tự gọi `window.close()` sau khi lưu (best-effort — trình duyệt có thể chặn nếu không coi đây là cửa sổ do script mở).
- Wizard cũng mở bằng Chrome/Edge/Chromium `--app=` (hàm `resolve_app_mode_browser_bin()` trong `wizard.py`, bản Python của hàm cùng tên trong `setup.sh`) — ẩn thanh địa chỉ, trông như app desktop; `wizard.html` có JS chặn `contextmenu` (chuột phải), không chặn F12 (wizard không có nội dung nhạy cảm khi xem DevTools). Không tìm thấy trình duyệt Chromium nào → fallback `xdg-open`/`open`/`cmd.exe start` như thường.
- `patch_code_server_assets()` trong `setup.sh` (gộp chung, xem chi tiết ở mục login/favicon bên dưới) — lý do gộp: chạy nền qua `nohup` (không có TTY thật) khiến `sudo` không cache được xác thực giữa các lệnh riêng lẻ, từng tách 2 hàm (login patch + favicon patch) vẫn hỏi lại mật khẩu 1 lần nữa dù mỗi hàm tự nó đã gộp lệnh — phải gộp CHUNG thành đúng 1 lệnh `sudo python3` để chỉ hỏi mật khẩu 1 lần duy nhất (bug thật đã gặp, quan sát: 6 lần hỏi → tách hàm còn 2 lần → gộp hẳn còn 1 lần).
- **Bug thật nghiêm trọng hơn — cài qua wizard web thì `sudo` trong `patch_code_server_assets()` fail ÂM THẦM, favicon KHÔNG BAO GIỜ được patch**: nhánh GUI (`HAS_GUI=1`) sau khi nhận answers từ `wizard.py` thì re-exec `TELECODE_APPLYING=1 nohup bash "$0" ... &` rồi `exit 0` NGAY — TOÀN BỘ bước 1→9 (kể cả cài code-server, `patch_code_server_assets()`, `sudo tailscale up/serve/funnel`) chạy trong tiến trình nền detached khỏi terminal, không có TTY nào cả (khác nhận định cũ ở mục gộp lệnh phía trên — tưởng chỉ hỏi lại mật khẩu, thực ra hoàn toàn KHÔNG hỏi được, sudo lỗi ngay không hang, script không kiểm tra exit code nên vẫn báo "ok" nhầm). Xác minh qua `stat` mtime: `login.html`/`login.css` patch được từ 1 lần chạy tương tác thủ công (trước khi code copy favicon được thêm vào), còn `favicon.ico`/`favicon-dark-support.svg` chưa từng đổi (mtime = ngày cài code-server gốc) dù chạy quickstart nhiều lần sau đó.
  - **Fix lần 1 (KHÔNG đủ, đã xác minh thất bại thật qua log)**: thử `sudo -v` NGAY TRƯỚC khi background hoá (lúc tưởng vẫn còn TTY, "foreground") — log `logs/setup-apply.log` của 1 lần chạy thật qua `curl | bash` cho thấy NGAY CẢ Ở ĐÓ `sudo` cũng lỗi `unable to read password: Input/output error` — luồng `curl | bash` không đảm bảo TTY đọc được ngay từ đầu, không riêng gì sau khi `nohup`.
  - **Fix thật (đang dùng)**: dùng **`pkexec`** thay `sudo` cho đúng 1 việc — `chown -R` 1 lần thư mục `{root}/src/browser/{pages,media}` sang user hiện tại, ngay trước khi background hoá. `pkexec` hiện hộp thoại polkit ĐỒ HOẠ (không cần TTY, chỉ cần `DISPLAY` + polkit agent đang chạy — cả 2 luôn có sẵn vì nhánh này CHỈ chạy khi `HAS_GUI=1`). Sau khi chown xong 1 lần, `patch_code_server_assets()` tự phát hiện đã ghi được (`[ -w "$html" ]`) nên không cần `sudo`/`pkexec` nữa ở mọi lần chạy sau, kể cả chạy nền. Fallback về `sudo chown` nếu máy không có `pkexec` (server thật/không GUI — dù nhánh này về lý thuyết không chạy tới vì cần `HAS_GUI=1`).
  - Không giải quyết được trường hợp code-server CHƯA cài lần đầu (chưa có thư mục để chown) — chạy lại `bash setup.sh` 1 lần nữa sau khi code-server đã có sẽ tự fix. `sudo tailscale up/serve/funnel` (bước 4/5) vẫn dùng `sudo` thường (không đổi sang `pkexec`, vì đây là lệnh cần chạy LẶP LẠI mỗi lần chứ không phải việc 1 lần như chown) — vẫn có thể fail âm thầm khi qua wizard, CHƯA xử lý triệt để.
- **Bug thật khác, gây "chưa gì được fix" dù đã sửa favicon/shortcut**: `install_vsix_extension()` (bước cài Copilot) có lúc crash `line N: name: unbound variable` dưới `set -uo pipefail` (nguyên nhân gốc chưa xác định chắc chắn — các call site đều truyền đủ 2 tham số) — vì KHÔNG có `set -e`, các bước TRƯỚC điểm crash vẫn giữ nguyên hiệu lực nhưng MỌI bước SAU điểm crash (kể cả bước 4/5 Tailscale, 9 chạy bot, 10 tự mở app) không bao giờ chạy tới, khiến cả lần chạy "coi như chưa cập nhật gì" dù `setup-apply.log` dừng giữa chừng không có thông báo lỗi rõ ràng nào khác. Fix: `install_vsix_extension()` dùng `"${1:-}"`/`"${2:-}"` + kiểm tra rỗng → `warn` + `return 1` thay vì để `set -u` giết cả script. Đây cũng là lý do dời bước tạo shortcut Desktop lên sớm (`1cb`, xem mục trên) — để nó không còn phụ thuộc bước Copilot chạy trót lọt.
- `ensure_code_server_user_settings()` trong `setup.sh` đảm bảo `~/.local/share/code-server/User/settings.json` có `security.workspace.trust.enabled: false` (chỉ THÊM key còn thiếu, không ghi đè settings người dùng tự chỉnh) — Workspace Trust bật lên khiến extension như Claude Code bị vô hiệu hoá lại, phải bấm "Enable (Workspace)" mỗi lần mở, vì trạng thái trust/enablement theo workspace trong code-server web workbench lưu ở phía trình duyệt (IndexedDB theo origin) chứ không phải file server-side — không ổn định qua các lần mở lại (đổi origin/tunnel, xoá site data...). Tắt hẳn Workspace Trust là fix chuẩn, không cần tìm hiểu sâu hơn lý do cụ thể không persist.
- **Bước tạo shortcut Desktop đặt NGAY SAU patch favicon (`1cb`), không còn ở cuối (`3b` cũ)** — bug thật đã gặp: `set -uo pipefail` (không có `set -e`) khiến 1 lỗi crash ở bước sau đó (vd `install_vsix_extension()` cài Copilot, xem mục Copilot bên dưới) làm TOÀN BỘ các bước phía sau điểm crash không chạy, kể cả tạo lại shortcut — dời lên sớm để icon/shortcut luôn được áp dụng bất kể các bước Copilot/Tailscale/bot phía sau có lỗi hay không.
- `setup.sh` tự tạo shortcut Desktop tên **"Telecode"** (`Name=Telecode`, `Comment=Telecode by Yan`) mở `http://localhost:8443` (`~/Desktop/telecode.desktop` trên Linux, `~/Desktop/Telecode.command` trên macOS — dùng icon bundle `assets/icon.png`; tự xoá shortcut tên cũ `code-server.desktop`/`VS Code (code-server).command` nếu còn sót từ bản trước khi đổi tên) — dùng VS Code như app desktop ngay trên máy chạy code-server, không cần qua tunnel/Telegram. Mở bằng Chrome/Edge/Chromium ở chế độ `--app=` (hàm `resolve_app_mode_browser_bin()`, dò `google-chrome`/`chromium`/`microsoft-edge`) — ẩn thanh địa chỉ, giống app thật; không tìm thấy trình duyệt nào trong nhóm đó thì fallback `xdg-open`/`open` (tab thường). **Linux — icon taskbar riêng, đã fix bug thật**: `Exec=` thêm `--class=Telecode` (flag vẫn hoạt động ở Chrome bản mới dù không còn tài liệu chính thức) + `.desktop` thêm `StartupWMClass=Telecode`. Không có 2 dòng này, Chrome `--app=` mặc định đặt `WM_CLASS="Google-chrome"` (giống hệt cửa sổ Chrome thật, xác minh qua `xprop WM_CLASS`) khiến Cinnamon/GNOME nhận diện trùng với `google-chrome.desktop` đã cài sẵn trên máy và luôn hiện icon Chrome thật ở taskbar — bỏ qua cả favicon (`_NET_WM_ICON`, Chrome vẫn set đúng nhưng DE ưu tiên match `.desktop` trước) lẫn `Icon=` riêng. `resolve_app_mode_browser_bin()`/`nohup ... --app=` ở nhánh "Cài xong tự động" (mục dưới) cũng phải truyền `--class=Telecode` để nhất quán. **Bug thật khác, đã fix**: khi máy KHÔNG có Chrome/Edge/Chromium, nhánh fallback ghi `Exec=xdg-open http://localhost:8443` (mở thẳng trình duyệt mặc định thật, không phải app-mode) nhưng code cũ vẫn set `StartupWMClass=Telecode` không điều kiện — cửa sổ trình duyệt mặc định mở ra mang `WM_CLASS` thật của chính nó (vd Firefox), không khớp `Telecode`, khiến Cinnamon/GNOME không nhận diện được cửa sổ thật nên taskbar giữ nguyên icon của launcher (`Icon=` icon Telecode) thay vì icon thật của trình duyệt. Fix: chỉ set `StartupWMClass=Telecode` khi thực sự dùng `$APP_BROWSER --class=Telecode` (nhánh Chrome/Edge/Chromium app-mode); nhánh `xdg-open` fallback để trống dòng này. **Không đổi title bar trình duyệt** (code-server tự đặt động theo file đang mở — cố định sẽ phải patch `workbench.html`, mất khả năng thấy tên file, không làm). `install.ps1` (Windows) tạo `.lnk` thật tên `Telecode.lnk` (không phải `.url` — cần cho icon + flag `--app=`) trỏ `msedge.exe --app=http://localhost:8443`, icon đọc qua UNC `\\wsl$\Ubuntu\home\<user>\telecode\assets\icon.ico` (convert từ `icon.png` bằng ImageMagick `convert`, xem `assets/icon.ico`).
- **Nguồn icon**: `assets/telecode-source.svg` (logo ruy-băng VS Code + máy bay giấy Telegram) là vector gốc — mọi file raster trong `assets/` (`icon.png`, `icon.ico`, `favicon.svg`, `pwa-icon-{192,512}.png`) render từ file này, KHÔNG tự vẽ tay. `icon.png` là nguồn trung gian duy nhất (512×512, nền trong suốt) — mọi file còn lại resize/convert từ `icon.png`, không render lại từ SVG mỗi lần (tránh lệch màu giữa các tool render). **Render bằng Chrome headless** (`google-chrome --headless --window-size=512,512 --default-background-color=00000000 --screenshot=...` trên 1 HTML wrapper nhúng thẳng SVG), KHÔNG dùng `convert` (ImageMagick) trực tiếp từ SVG — ImageMagick fallback về renderer `MSVG` nội bộ khi thiếu gói `librsvg2-bin` (`rsvg-convert` CLI, khác `librsvg2-2`/`librsvg2-common` là thư viện runtime, thường đã có sẵn nhưng không có binary CLI), cho gradient bị dải màu (banding) và không hỗ trợ filter `feDropShadow` — bug thật đã gặp khi thử `convert -background none -density ... .svg icon.png` cho kết quả ảnh vỡ. Từ `icon.png`: `icon.ico` = `convert` gộp nhiều size (16/32/48/64/128/256) đúng chuẩn multi-res Windows; `favicon.svg` = wrapper SVG bọc `icon.png` base64 `data:image/png` (không phải vector thật — pattern có sẵn, xem hàm patch ở mục login/favicon phía trên); `pwa-icon-192.png` = resize từ `icon.png`.
- **Không dùng iframe/mini_app.html trong luồng mặc định** — `bot.py` mở nút "Open VS Code" thẳng vào `VSCODE_PUBLIC_URL` (top-level navigation, không nhúng iframe). Lý do: code-server đặt cookie `SameSite=Lax`; nếu load trong iframe khác domain (kiến trúc ban đầu: `mini_app.html` qua tunnel riêng nhúng code-server qua tunnel khác), nhiều WebView di động (đặc biệt iOS WKWebView của Telegram) coi cookie này là bên thứ 3 và chặn lưu — server xác thực đúng mật khẩu nhưng cookie không lưu được, đăng nhập luôn quay lại y hệt màn login. `mini_app.html` vẫn còn trong repo (không xoá) nhưng không được `setup.sh` sinh/dùng nữa — chỉ giữ tham khảo nếu sau này cần domain con cùng root domain (first-party thật) mới an toàn dùng lại iframe.
- **Nút "Mở VS Code" trong `/start` dùng `web_app=WebAppInfo(url=...)`, KHÔNG dùng `url=...`** (`bot.py`'s `start()`) — **bug thật đã gặp + đã fix**: nút kiểu `url=` (Telegram tự mở bằng trình duyệt trong-app riêng, không phải Mini App WebView chuẩn) báo lỗi "Không thể truy cập trang web này" trên máy thật dù server hoàn toàn bình thường (đã xác nhận qua `curl --resolve` thẳng tới IP relay Funnel công khai, hoàn toàn bypass máy chạy server, vẫn trả về đúng `302`) — trong khi icon Menu Button (đã dùng `WebAppInfo` từ trước, xem `post_init()`) mở CÙNG URL đó vẫn vào bình thường. Khác biệt duy nhất là cơ chế mở link, không phải DNS/Tailscale/code-server. `WebAppInfo` mở URL làm document top-level của 1 WebView Mini App riêng do Telegram quản lý — **không phải iframe** (khác hẳn kiến trúc `mini_app.html` cũ đã bỏ ở bullet trên) nên KHÔNG tái phát sự cố cookie `SameSite=Lax` đã ghi ở trên; đổi cả `/start` lẫn Menu Button dùng chung `WebAppInfo` để nhất quán, không phụ thuộc hành vi trình duyệt trong-app (tuỳ phiên bản/nền tảng Telegram, không đáng tin cậy bằng Mini App WebView chính thức).
- **Giới hạn CHƯA giải quyết — `AskUserQuestion`/prompt tương tác của 1 session Claude Code không hiển thị được khi xem qua telecode trên điện thoại**: quan sát thực tế qua Claude extension FleetView (danh sách các session agent đang chạy) — 1 session đang chạy trên máy tính (desktop) gọi tool đặt câu hỏi cho user (`AskUserQuestion`) thì timeline trong FleetView mở từ điện thoại (qua telecode) chỉ hiện dòng nhãn `AskUserQuestion`/`Thinking`, KHÔNG hiện UI tương tác thật (các lựa chọn để bấm trả lời) — người dùng phải quay lại đúng máy tính đang chạy session đó để trả lời. Đây là hành vi của **Claude Code VS Code extension's webview** (không phải cơ chế của `bot.py`/`setup.sh`/Tailscale Funnel trong repo này) — nghi vấn do UI tương tác của 1 tool-call được render bởi 1 webview/kênh riêng gắn với đúng cửa sổ VS Code đã khởi tạo session đó, không phải state đồng bộ được qua mọi client nối vào cùng code-server. **Chưa có cách khắc phục trong phạm vi telecode** (không có API/hook nào để proxy lại tương tác này qua tunnel) — ghi nhận làm giới hạn nền tảng, không phải bug của telecode.
- **`lib_status.check_funnel_public_reachable()` phải resolve DNS qua resolver CÔNG KHAI, không dùng resolver hệ thống** (`scripts/lib_status.py`) — **bug thật đã gặp + đã fix**: chạy trên chính máy có cài Tailscale, `/etc/resolv.conf` trỏ `systemd-resolved` (`127.0.0.53`) và Tailscale tự chèn **MagicDNS** cho mọi domain `*.ts.net` — `curl`/`urllib` gọi thẳng `https://<hostname>.ts.net` từ máy này resolve về **IP nội bộ tailnet** (`100.x.x.x`) chứ không phải IP relay Funnel công khai (`103.84.155.x`, xác nhận qua `dig @8.8.8.8`) mà điện thoại (không cài Tailscale) thực sự dùng — tray báo "hoạt động" (`funnelPubliclyReachable=true`) dù đường đi thật ngoài internet đang có vấn đề khác (false positive, đúng thứ user report: icon xanh nhưng điện thoại "Không thể truy cập trang web này"). Fix: `check_funnel_public_reachable()` tự `dig @1.1.1.1 <host> +short` (hoặc `@8.8.8.8` fallback) lấy IP public thật rồi gọi `curl --resolve <host>:443:<IP>` — ép resolve đúng IP mà 1 client bên ngoài tailnet (điện thoại) sẽ nhận được, không tin resolver cục bộ. `setup.sh`'s bước 4/5 verify funnel lúc cài đặt cũng áp dụng lại đúng cơ chế này (cùng 1 class bug, sửa đồng bộ cả 2 chỗ).
- Menu "giữ nguyên/cài lại" (`ask_choice` trong `setup.sh`) là radio 2 dòng chọn bằng phím ↑/↓ + Enter (mặc định "Giữ nguyên"), fallback về nhập số 1/2 nếu không có `/dev/tty` thật. **Quan trọng**: hàm được gọi qua `$(ask_choice ...)` để lấy kết quả — mọi echo/tput hiển thị menu bên trong hàm phải ghi thẳng `/dev/tty`, KHÔNG được ghi ra stdout thường (nếu không sẽ bị command substitution chụp mất, người dùng thấy màn hình trắng treo im chờ phím mà không có gì hiển thị — đã từng là bug thật).
- Trang login code-server (`{root}/src/browser/pages/login.html` + `login.css`, tìm qua `find_code_server_root()` trong `setup.sh`) không có API tuỳ biến chính thức — `patch_code_server_assets()` vá thẳng file HTML/CSS đóng gói sẵn để thêm icon hiện/ẩn mật khẩu + chặn F12/chuột phải, **và trong CÙNG 1 lệnh sudo đó** copy luôn favicon/PWA icon riêng (`{root}/src/browser/media/favicon.ico`, `favicon-dark-support.svg`, `pwa-icon-{192,512}.png`, `pwa-icon-maskable-{192,512}.png` nếu tồn tại) từ `assets/` (`icon.ico`, `favicon.svg` — SVG bọc `icon.png` dạng base64 data URI, `pwa-icon-{192,512}.png` resize từ `icon.png`) — icon taskbar khi mở qua Chrome `--app=` lấy từ favicon của trang, không phải từ `Icon=` trong `.desktop`/`.lnk`. HTML idempotent qua 2 marker riêng biệt (kiểm tra độc lập): `telecode-eye-toggle` (icon con mắt) và `telecode-anti-inspect` (script chặn F12/contextmenu chèn trước `</body>`); CSS idempotent qua `telecode-eye-toggle-css-v2` — do input bọc thêm `<div class="password-wrap">` khiến selector CSS gốc dùng child combinator (`.field > .password`) không còn khớp, phải đổi sang descendant combinator (`.field .password`); favicon idempotent qua so sánh byte trực tiếp `icon.ico` với `favicon.ico` hiện có. Favicon riêng này quyết định icon hiện trong tab/`_NET_WM_ICON` của cửa sổ (đúng như code-server đọc), nhưng **không** phải yếu tố quyết định icon taskbar Linux — xem `--class=Telecode`/`StartupWMClass=Telecode` ở mục "shortcut Desktop" phía trên (bug thật đã xác minh qua `xprop`: taskbar Cinnamon/GNOME ưu tiên match `.desktop` theo `WM_CLASS` hơn `_NET_WM_ICON`). Bash chỉ gọi `sudo python3` **1 lần duy nhất** nếu BẤT KỲ phần nào trong 3 phần (html/css/favicon) chưa đạt — cả 3 việc (patch login + patch css + copy favicon) đều nằm trong CÙNG 1 script Python đó (dùng `shutil.copy`, không gọi `cp` riêng) để không phát sinh thêm lệnh `sudo`. **Chặn F12/chuột phải CHỈ áp dụng cho `login.html`, không đụng `workbench.html`** — F12 là phím tắt thật "Go to Definition" trong VS Code, chặn toàn trang sẽ phá tính năng đó khi đang code; đây cũng chỉ là ngăn cản hình thức (JS không chặn được DevTools trình duyệt thật), tham khảo cách làm/comment gốc trong `yan2ai/public/chat.html`. `login.js` đọc lại HTML/CSS ở mỗi request (không cache) nên patch có hiệu lực ngay, không cần restart — nhưng bị mất mỗi khi code-server cài lại/nâng cấp, nên `setup.sh` gọi lại hàm này mỗi lần chạy.
- Khi chạy qua `curl | bash`, mọi prompt trong `setup.sh`/`scripts/install.sh` phải đọc từ `/dev/tty` (không dùng `read` mặc định) vì stdin đã bị nội dung script từ `curl` chiếm — xem comment trong `setup.sh`.
- **Đồng bộ ảnh/file từ điện thoại về máy tính**: `bot.py`'s `file_handler()` (đăng ký qua `MessageHandler(filters.PHOTO | filters.Document.ALL, ...)`) nhận mọi ảnh (kiểu "Photo", nén sẵn) HOẶC file bất kỳ (kiểu "File"/"Document", giữ nguyên gốc + tên file thật qua `message.document.file_name`) gửi trong chat (chỉ chủ sở hữu, qua `is_owner()`), tải bằng `context.bot.get_file()` rồi lưu vào `FILE_INBOX_DIR` (`config.yaml`, tên file `YYYYmmdd-HHMMSS-<tên gốc hoặc file_unique_id>`) — cách chính để làm việc từ xa qua telecode khi cần đưa tài liệu/ảnh lỗi màn hình vào máy tính mà điện thoại không truy cập được filesystem máy tính. Muốn giữ nguyên chất lượng/EXIF ảnh gốc, gửi kiểu "File" trên Telegram thay vì chọn ảnh qua khung chat thường (kiểu "Photo" bị Telegram nén). Mặc định `FILE_INBOX_DIR` = thư mục con `files/` trong thư mục cài telecode (`$DIR/files`, KHÔNG phải chính `$DIR` — tránh trộn lẫn với source code thực thi), hỏi lại được ở **bước 6d** (`ask_value ... "fileInboxDir"`) — đổi trỏ sang 1 thư mục con trong `$CODE_SERVER_WORKSPACE` nếu muốn thấy file ngay trong VS Code Explorer. GUI wizard có field tương ứng (`fileInboxDir`, text input thường không phải password) trong `assets/wizard.html`, giá trị hiện tại lấy qua `probe_status()`'s `currentFileInboxDir` trong `wizard.py`. **Cách khác không cần code**: Explorer trong code-server web hỗ trợ sẵn chuột phải → "Upload..." — mở file picker của trình duyệt điện thoại, phù hợp cho upload thủ công 1-2 file không cần qua bot.
- **Shortcut Desktop "Telecode" tự khởi động lại code-server/bot/Tailscale nếu đang tắt trước khi mở app** (`scripts/launch.sh`, gọi bởi `Exec=` của `telecode.desktop`/`Telecode.command` — setup.sh bước 1cb sinh ra) — xử lý đúng tình huống thật đã gặp: Tailscale tự đăng xuất ("Stopped; run 'tailscale up' to log in") sau khi máy sleep/đổi mạng/xung đột VPN khác (vd Cloudflare WARP bật cùng lúc — đã gặp thật, WARP không tự phá Tailscale nhưng khiến `tailscale status`'s `Self.Online` báo sai/treo tới khi disconnect WARP), `tailscaled` daemon + code-server + bot vẫn chạy bình thường nhưng mini app trên điện thoại không vào được (Funnel không còn public) dù mở trên máy tính vẫn OK — trước đây phải tự debug tay (`tailscale status`, `tailscale up ...`). Logic restart+reconnect (bước 1+2 cũ) đã **tách riêng ra `scripts/reconnect.sh`** (exit code 0 = OK, 1 = Tailscale reconnect thất bại) để dùng chung với `tray.py` (mục dưới) — `launch.sh` giờ chỉ gọi `bash scripts/reconnect.sh` rồi mới mở trình duyệt (bước 3), không còn inline logic riêng. `reconnect.sh`: (1) start lại `code-server`/`telecode-bot` qua `systemctl --user` nếu không active (KHÔNG tạo/ghi đè unit, chỉ start service đã có sẵn từ lần chạy `setup.sh` trước); (2) kiểm tra `tailscale status --json`'s `BackendState` khác `"Running"` thì chạy lại `tailscale up --hostname=$(hostname) --operator=$(whoami)` (kèm `systemctl start tailscaled` trước nếu daemon cũng tắt hẳn) qua **`pkexec`** (không phải `sudo`/cmdctl — cmdctl chỉ dành cho AI agent chạy lệnh từ xa qua chat, còn shortcut/tray chạy trực tiếp trong phiên đồ hoạ của user nên `pkexec` tự hiện popup xin mật khẩu, không cần TTY/terminal). macOS/máy không có `systemd --user` → fallback `nohup` (đọc lại `CS_ENV_FILE`/workspace mặc định đã ghi từ lần `setup.sh` trước, không hỏi lại gì). **Windows (WSL) chưa áp dụng** — `.lnk` do `install.ps1` sinh vẫn mở thẳng `msedge.exe` như cũ, không gọi qua `launch.sh`/`reconnect.sh` (cần wrapper `.bat`/PowerShell gọi `wsl.exe bash -lc ...` để làm tương tự, chưa triển khai).

- **`reconnect.sh`/`lib_status.py` bước 2b — bug thật khác: `BackendState` vẫn `"Running"` nhưng control-plane treo, `tailscale up` không tự sửa được** — khác hẳn tình huống "Stopped" ở bước 2 phía trên (đăng xuất hẳn): Cloudflare WARP (`warp-svc`) chạy song song có thể làm gián đoạn kết nối `tailscaled` tới `controlplane.tailscale.com` (log thật: `control: map response long-poll timed out!` + `dns: resolver: forward: no upstream resolvers set`) mà KHÔNG đăng xuất Tailscale — `BackendState` vẫn báo `"Running"` nên bước 2 (chỉ check `BackendState != "Running"`) bỏ sót, trong khi `tailscale status --json`'s `Self.Online` thật sự là `false` → Funnel relay coi node offline, TLS handshake từ ngoài bị đứt giữa chừng (`SSL: unexpected eof while reading`) dù code-server/bot/Tailscale cục bộ đều "chạy bình thường". `lib_status.get_status()` thêm field `tailscaleSelfOnline` (từ `Self.Online`) để phân biệt 2 tình huống; `reconnect.sh`'s bước 2b (chỉ chạy khi `BackendState=="Running"` NHƯNG `tailscaleSelfOnline=false`) tự: (1) `systemctl restart tailscaled` qua `pkexec`/`sudo` (đã verify: chỉ `tailscale up` KHÔNG đủ vì phiên vẫn "Running" nên daemon không tự thử reconnect lại control-plane, phải restart hẳn tiến trình). `tray.py`'s `status_summary_text()` báo riêng dòng "Tailscale control-plane bị treo (thử Kết nối lại — có thể do xung đột WARP)" cho đúng tình huống này thay vì gộp chung "mini app không vào được".
  - **Bug thật đã gặp + đã fix — check nhầm tín hiệu WARP**: bản đầu chỉ ngắt WARP khi `warp-cli --accept-tos status` báo `"Connected"` (best-effort, không cần root) trước khi restart `tailscaled`. Thực tế `warp-cli status` chỉ phản ánh trạng thái "kết nối VPN" phía người dùng, KHÔNG phản ánh daemon `warp-svc` (root, systemd) có đang chạy hay không — đã xác minh thật: `warp-cli` báo `"Disconnected"` nhưng service `warp-svc` vẫn `active`, daemon vẫn giữ hook/route mạng đủ để làm đứt TLS handshake tới relay Funnel (`unexpected eof while reading`), khiến bấm "Kết nối lại" chỉ restart `tailscaled` suông mà không hết lỗi (`tray.py` báo "Đã restart service nhưng mini app vẫn chưa vào được"). Fix: bước 2b giờ kiểm tra thẳng `systemctl is-active --quiet warp-svc` (không dựa `warp-cli`), nếu active thì `systemctl stop warp-svc` gộp chung 1 lệnh root với `systemctl restart tailscaled` (chỉ 1 hộp thoại `pkexec`).

- **Tray icon trạng thái (`tray.py`) + autostart cùng OS** — giải quyết đúng vấn đề "không có cách nào xác nhận mini app thật sự truy cập được mà không phải ngồi tra tay trên máy chạy telecode" (sự cố thật: Cloudflare WARP che mất kết nối Tailscale, không ai biết cho tới khi debug tay qua `tailscale status`/`curl`). Kiến trúc:
  - **`scripts/lib_status.py`** (mới, tách từ `wizard.py`'s `probe_status()` cũ) — module logic kiểm tra dùng chung giữa `wizard.py` (UI cài đặt) và `tray.py`: `get_status(run_dir, check_public: bool)` trả dict (giữ nguyên field cũ + field mới `tailscaleBackendState`, `tailscaleSelfOnline`, `funnelPubliclyReachable`, `funnelPublicHttpCode`) và `overall_ok(status)` (1 boolean tổng). `check_funnel_public_reachable()` **thật sự `curl` tới `tailscaleUrl`** (không chỉ kiểm tra service/config đã đúng) — coi OK khi HTTP code không phải `000/502/503/504` (đúng tiêu chí verify funnel đã dùng ở bước 4/5 `setup.sh`). `wizard.py`'s `probe_status()` giờ chỉ là wrapper gọi `get_status(..., check_public=False)` (không tốn round-trip curl mỗi lần UI cài đặt poll).
  - **`tray.py`** (mới, root project) — dùng `pystray`+`Pillow` (thêm vào `requirements.txt`). **Bug thật đã gặp + đã fix**: `pystray` tự chọn backend theo thứ tự `appindicator → gtk → xorg` — cả `appindicator`/`gtk` cần import `gi` (PyGObject, gói hệ thống `python3-gi`/`gir1.2-ayatanaappindicator3-0.1`, không cài qua pip được), venv mặc định (`include-system-site-packages=false`) không thấy `gi` nên `pystray` âm thầm rơi xuống backend `xorg` (legacy XEmbed) — backend này **click trái CHỈ gọi được đúng 1 menu item đánh dấu `default=True`, KHÔNG hiện popup menu đầy đủ** (đã xác minh qua source `pystray/_xorg.py`'s `_on_button_press`/`Menu.__call__`), khiến bấm icon không ra menu gì cả dù code hoàn toàn đúng. Fix: `setup.sh` bước 8 tạo venv với `python3 -m venv --system-site-packages` (chỉ Linux — macOS/Windows dùng backend `darwin`/`win32` riêng, không cần `gi`) để venv thấy được `gi` hệ thống, `pystray` tự chọn đúng backend `_appindicator` (StatusNotifierItem, có popup menu thật, đã test xác nhận menu hiện đầy đủ). **Bug thật khác đã gặp + đã fix**: `icon.title` (WM_NAME, dùng bởi backend Xorg khi khởi tạo cửa sổ dock) chỉ chấp nhận Latin-1 — `python-xlib`'s `set_wm_name()` ép `STRING` encoding, text tiếng Việt có dấu/emoji làm `UnicodeEncodeError` crash ngay lúc tạo icon; `tray.py`'s `title_ascii()` giữ `icon.title` thuần ASCII (`"Telecode - OK"`/`"Telecode - Down"`), tiếng Việt/emoji chỉ dùng trong menu items (render qua Gtk, không bị giới hạn này). Icon `assets/tray-icon-on.png`/`tray-icon-off.png` (sinh 1 lần từ `assets/icon.png` qua `assets/gen_tray_icons.py` — composite chấm tròn xanh/đỏ, đúng convention "mọi raster derive từ icon.png", commit thẳng 2 file output vào repo, không tự gọi lại trong `setup.sh`). Thread nền poll `lib_status.get_status(check_public=True)` mỗi 30s, icon xanh chỉ khi **toàn bộ** code-server+bot+Tailscale+funnel+public-reachable đều OK. Menu: dòng trạng thái (disabled) + "🔄 Kết nối lại" (gọi `scripts/reconnect.sh` headless, không mở browser) + "🖥️ Mở VS Code" (gọi `scripts/launch.sh`, đã bao gồm reconnect+mở browser) + "❌ Thoát". Notify-send chỉ bắn khi trạng thái đổi (so sánh `overall_ok()` trước/sau), tránh spam mỗi 30s. Single-instance qua `.run/tray.pid` (cùng pattern `is_alive()` đã có).
  - **Autostart qua `systemd --user` (`telecode-tray.service`), KHÔNG phải XDG autostart** (`setup.sh`, bước "9b", sau bước bot systemd) — **bug thật đã gặp + đã fix**: bản đầu dùng `~/.config/autostart/telecode-tray.desktop` + khởi động tay 1 lần qua `nohup` lúc cài (chạy trong tiến trình cài đặt, vd session AI agent) — tiến trình `nohup` đó chỉ sống chung vòng đời với session cha, KHÔNG phải service độc lập; hễ session cha kết thúc (không cần logout/khoá màn hình — user report: khoá màn hình xong đăng nhập lại đã thấy icon biến mất) là tray chết theo, và XDG autostart cũng không tự restart nếu tray crash giữa chừng. Fix: sinh `~/.config/systemd/user/telecode-tray.service` (`PartOf=graphical-session.target`, `WantedBy=graphical-session.target`, `Restart=always`, `RestartSec=3`, `ExecStart=$VENV_PY $DIR/tray.py`) — đúng pattern `code-server`/`telecode-bot` đã dùng, độc lập với mọi tiến trình cha, tự sống lại nếu crash. `graphical-session.target` đã active sẵn ngay khi đăng nhập Cinnamon và **tự có `DISPLAY`/`XAUTHORITY`** trong environment của systemd user manager (xác nhận qua `systemctl --user show-environment` trên máy dev — Cinnamon/lightdm tự import 2 biến này vào systemd user session) nên không cần khai báo `Environment=` thủ công. `setup.sh` tự dọn file `.desktop` kiểu cũ nếu còn sót (tránh chạy trùng 2 lần) rồi `systemctl --user daemon-reload && enable --now`. **Giới hạn nền tảng, không phải thiếu sót**: tray icon cần phiên X11/Wayland thật nên chỉ tự chạy được từ lần đăng nhập Cinnamon kế tiếp nếu cài lúc chưa có phiên đồ hoạ (`enable` không `--now`) — chỉ code-server/bot (`systemd --user`+linger) và `tailscaled` (system service) mới thật sự khởi động được trước-đăng-nhập. Máy không có `systemd --user` (hiếm) hoặc macOS/Windows: `setup.sh` chỉ `warn` rõ ràng (chưa triển khai LaunchAgent/Task Scheduler cho tray trên các OS đó), không im lặng bỏ qua.
  - **Tự động bật `loginctl enable-linger $(id -un)`** thay vì chỉ cảnh báo như trước (`setup.sh`, đoạn sau khi start bot systemd) — thử lệnh trực tiếp trước (nhiều distro cho tự bật cho chính mình qua polkit `auth_self_keep`, đã xác nhận hoạt động không cần root trên máy dev), fallback `pkexec`/`sudo` (cùng pattern `tailscale up`), chỉ `warn` nếu cả 2 đều thất bại. Đảm bảo code-server/bot (`systemd --user`, `Restart=always`) sống được ngay từ lúc máy khởi động, không cần ai đăng nhập trước.
  - **`tailscaled` tự enable ở boot** (`setup.sh`, ngay sau bước cài Tailscale, trước bước đăng nhập tailnet) — verify `systemctl is-enabled tailscaled`, tự `pkexec`/`sudo systemctl enable tailscaled` nếu chưa (thường gói cài đặt đã enable sẵn, đây chỉ là lớp phòng vệ bổ sung).

## 📂 Cấu Trúc File Chi Tiết

### Core Files

**`bot.py`** - Main Telegram Bot
```python
Responsibilities:
  ✓ Initialize Telegram bot with token
  ✓ Handle /start command
  ✓ Create inline keyboard with Web App button
  ✓ Manage polling for messages
  ✓ Load config from config.yaml

Key Functions:
  • start(update, context) - Gửi button "Open VS Code"
  • main() - Initialize và chạy bot
  
Dependencies:
  - python-telegram-bot==20.0
  - PyYAML
  - python-dotenv
```

**`mini_app.html`** - Web Interface
```html
Structure:
  ├── <head>
  │   ├── Telegram Web App SDK
  │   ├── Responsive meta tags
  │   └── Styling (dark theme for VS Code)
  │
  └── <body>
      ├── Header (status, connection info)
      ├── Iframe (for embedding VS Code)
      └── JavaScript
          ├── Load Telegram WebApp
          ├── Inject VS Code URL dynamically
          ├── Handle iframe lifecycle
          └── Display connection status

CORS Handling:
  - Cloudflare Tunnel handles CORS automatically
  - Telegram Mini App has its own sandbox

Configuration:
  - VSCODE_URL: Loaded from window data or hardcoded
  - Fallback: Try localhost first, then production URL
```

**`requirements.txt`** - Python Dependencies
```
Core:
  python-telegram-bot==20.0   # Telegram Bot API wrapper
  PyYAML                        # Config file parsing
  python-dotenv                 # Environment variables

Optional (for production):
  gunicorn                      # WSGI server
  aiohttp                       # Async HTTP client
```

**`config.example.yaml`** - Configuration Template
```yaml
Purpose: Centralized config file
Fields:
  TELEGRAM_BOT_TOKEN: str       # From @BotFather
  VSCODE_PORT: int              # code-server port (default: 8443)
  VSCODE_PUBLIC_URL: str        # Tailscale Funnel URL (https://<hostname>.<tailnet>.ts.net, cố định)
  VSCODE_PASSWORD: str          # code-server password
  BOT_POLLING_INTERVAL: int     # Seconds between polls
  MINI_APP_URL: str             # Where mini_app.html is hosted
```

**`.env.example`** - Environment Variables
```
TELEGRAM_BOT_TOKEN=your_token_here
VSCODE_TUNNEL_URL=https://your-tunnel.trycloudflare.com
```

## 🔄 Data Flow

### 1. Bot Initialization
```
app = Application.builder()
  .token(TELEGRAM_BOT_TOKEN)
  .build()
  
↓ (Register handlers)

app.add_handler(CommandHandler("start", start))

↓ (Start polling)

app.run_polling()
```

### 2. User Sends /start

```
User (Telegram)
  ↓
/start command
  ↓
bot.py: start() function
  ↓
Create inline keyboard:
  [Button: "🔧 Open VS Code"]
     ↓ (WebAppInfo)
     └→ mini_app.html
  ↓
Send message with button
  ↓
User's phone displays button
```

### 3. User Clicks Button

```
Telegram Client
  ↓
Open WebAppInfo URL (mini_app.html)
  ↓
Telegram Mini App Container
  ├─ Sandboxed environment
  ├─ Limited by Telegram security
  └─ Can access Telegram.WebApp API
  ↓
mini_app.html loads
  ├─ Initialize Telegram.WebApp
  ├─ Set iframe src to VSCODE_PUBLIC_URL
  └─ Display connection status
  ↓
Iframe loads VS Code Server
  ├─ HTTPS connection via tunnel
  ├─ Authenticate with password
  └─ Render full VS Code interface
  ↓
User sees VS Code in iframe on phone
  ↓
Can use Claude for VS Code extension
```

## 🔌 Component Responsibilities

### Telegram Bot (bot.py)
- **Input**: /start command from users
- **Output**: Inline keyboard with Web App button
- **State**: Stateless (polling-based)
- **Config**: Reads from config.yaml

### Mini App (mini_app.html)
- **Input**: Loaded in Telegram Mini App container
- **Output**: Iframe displaying VS Code
- **Responsibilities**:
  - Initialize Telegram WebApp
  - Manage iframe lifecycle
  - Display status indicators
  - Handle connection errors
- **Limitations**:
  - Runs in sandbox
  - No file system access
  - Limited to what iframe allows

### VS Code Server (code-server)
- **Input**: HTTP/HTTPS requests from mini_app.html
- **Output**: Web-based VS Code interface
- **Runs**: On localhost:8443 (configurable)
- **Features**:
  - Full VS Code features in browser
  - Extension support
  - File editing
  - Terminal access
  - Debugging

### Internet Tunnel (Cloudflare)
- **Purpose**: Expose localhost to internet securely
- **Input**: Local VS Code Server on localhost:8443
- **Output**: Public HTTPS URL (https://xxx.trycloudflare.com)
- **Benefits**:
  - No port forwarding needed
  - HTTPS by default
  - DDoS protection
  - Zero-knowledge architecture

### Claude for VS Code
- **Input**: User prompts in VS Code
- **Output**: Code suggestions, completions, refactoring
- **Integration**: Works through VS Code extension protocol
- **Accessed via**: VS Code UI in mini_app.html

## 🚀 Deployment Scenarios

### Scenario 1: Local Development
```
Developer's PC:
  ├─ bot.py runs (local polling)
  ├─ code-server runs on :8443
  └─ ngrok/cloudflare exposes it

Developer's Phone:
  └─ Connects to Telegram bot
     └─ Opens VS Code via Mini App
```

### Scenario 2: Docker Production
```
Docker Host:
  ├─ Bot container (running bot.py)
  ├─ code-server container
  ├─ Cloudflare tunnel container
  └─ Network: bridge mode (containers communicate)

User's Phone:
  └─ Connects to bot
     └─ Opens VS Code hosted on Docker
```

### Scenario 3: Multiple Users
```
Shared Server:
  ├─ Single bot instance
  ├─ Single code-server instance (shared workspace)
  └─ Multiple users connect simultaneously
  
Note: Each user sees same project directory
```

## 🔐 Security Architecture

### Authentication Layers

1. **Telegram Authentication + Owner claim (1 chủ sở hữu duy nhất)**
   - Bot token là secret chia sẻ — ai có token cũng gọi được API/chạy được instance (threat model hiện tại, không đổi).
   - **Owner claim qua mã 1 lần** (`state.json`, gitignored, KHÔNG nằm trong `config.yaml` vì `setup.sh` ghi đè `config.yaml` mỗi lần chạy lại) — **đã fix bug thật**: bản cũ ghi nhận `chat_id` của người `/start` đầu tiên làm owner (race condition — nếu bot token/username lộ ra trước khi chủ thật kịp `/start` lần đầu, kẻ tấn công tự nhận owner và dùng được `/backup_configs` để lấy config AI CLI tool). Nay `setup.sh` sinh `OWNER_CLAIM_CODE` (random hex, giữ nguyên qua các lần chạy lại tới khi đã claim) ghi vào `config.yaml`, in ra yêu cầu gửi đúng `/start <mã>` lần đầu mới được ghi `owner_chat_id` vào `state.json` (`bot.py:start()`). Sau khi đã claim, **MỌI lệnh** (`/start`, `/help`, `/status`, `/info`, `/backup_configs`) chỉ trả lời đúng `chat_id` này (`is_owner()`) — người khác nhắn bot nhận từ chối chung chung, không còn lộ `VSCODE_PUBLIC_URL`/token prefix qua `/status`.
   - **Rate-limit đăng nhập code-server: có sẵn, không cần tự làm thêm** — `code-server` (xem `/usr/lib/code-server/out/node/routes/login.js`, class `RateLimiter`) tự giới hạn 2 lần thử/phút + 12 lần/giờ (giới hạn toàn cục trên tiến trình, không phân biệt theo IP) trước khi từ chối luôn không kiểm tra password nữa — không cần thêm fail2ban/reverse-proxy cho việc này.

2. **Code-Server Authentication**
   - Password protection
   - HTTPS only
   - No public access (unless deliberately configured)

3. **Tunnel Authentication**
   - Tailscale Funnel — HTTPS public cố định theo tailnet, không phải Cloudflare Tunnel nữa (xem mục "Tunnel" ở phần Cài đặt)
   - IP-based access control possible qua Tailscale ACL (chưa cấu hình, dùng mặc định)
   - Automatic HTTPS

4. **Mini App Sandbox**
   - Telegram isolates Mini App
   - Cannot access phone file system
   - Cannot bypass Telegram authentication

### Data Protection
```
User Input → Telegram Encryption → Tunnel Encryption → 
code-server (local) → VS Code (local) → File System
```

## 📊 State Management

### Stateless Bot
The bot doesn't store user state. Each /start request:
- Creates new button
- Loads latest config
- Generates fresh UI

### Stateless Mini App
HTML file is loaded fresh each time. State kept in:
- Iframe (VS Code server session)
- Browser localStorage (if needed)

### Stateful Code-Server
Maintains:
- Open files
- Editor position
- Extensions state
- Workspace configuration

## 🛠️ Extension Points for Development

### Easy Modifications

1. **Change UI Theme**
   ```html
   <!-- Edit mini_app.html -->
   <style>
     /* Modify colors, fonts, layout */
   </style>
   ```

2. **Add Custom Buttons**
   ```python
   # Edit bot.py - add_handler() section
   keyboard = [[
       InlineKeyboardButton("🔧 VS Code", ...),
       InlineKeyboardButton("📁 File Manager", ...),
   ]]
   ```

3. **Add New Commands**
   ```python
   async def help_command(update, context):
       # New handler
   
   app.add_handler(CommandHandler("help", help_command))
   ```

4. **Change Configuration**
   ```yaml
   # Edit config.yaml
   # Restart bot.py
   ```

### Advanced Modifications

1. **Database Integration**
   - Store user preferences
   - Track usage logs
   - Persist settings

2. **Multiple Workspaces**
   - Allow users to switch projects
   - Different VS Code instances
   - Per-user configuration

3. **Analytics**
   - Track connections
   - Monitor usage patterns
   - Performance metrics

4. **Webhook Mode (vs Polling)**
   - Replace polling with webhooks
   - More efficient for high traffic
   - Requires public server

## 🐛 Debugging Guide

### For Claude AI Tasks

When debugging, check these in order:

**1. Configuration**
```bash
# Check config is loaded correctly
python -c "import yaml; print(yaml.safe_load(open('config.yaml')))"
```

**2. Bot Token**
```bash
# Validate token format (should be numbers:letters)
python -c "from bot import TELEGRAM_BOT_TOKEN; print(len(TELEGRAM_BOT_TOKEN))"
```

**3. Bot Connectivity**
```bash
# Test Telegram API access
curl -s https://api.telegram.org/bot<TOKEN>/getMe | jq
```

**4. VS Code Server**
```bash
# Check if code-server is running
curl -v http://localhost:8443

# Check port
netstat -an | grep 8443
```

**5. Tunnel**
```bash
# Verify tunnel is active
curl -v https://your-tunnel-name.trycloudflare.com

# Check tunnel logs
cloudflared tunnel --logfile=tunnel.log
```

**6. Bot Logs**
```bash
# Run with debug output
python bot.py --debug

# Or enable logging in code:
import logging
logging.basicConfig(level=logging.DEBUG)
```

### Common Issues & Solutions

| Issue | Cause | Solution |
|-------|-------|----------|
| Bot no response | Token invalid | Check config.yaml |
| Mini App frame blank | URL wrong | Verify VSCODE_PUBLIC_URL |
| Code-server 404 | Not running | Start code-server |
| CORS error | Tunnel config | Check Cloudflare settings |
| Password wrong | Mismatch | Verify in code-server config |
| Slow connection | Tunnel distance | Use nearest Cloudflare server |

## 📝 Common Tasks

### Task: Add a New Command
```python
# In bot.py, add this function:
async def project_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text("Which project?")

# Register it:
app.add_handler(CommandHandler("project", project_command))
```

### Task: Change Mini App URL
```yaml
# config.yaml
MINI_APP_URL: https://your-server.com/mini_app.html
```

### Task: Add More Buttons
```python
keyboard = [[
    InlineKeyboardButton("🔧 VS Code", web_app=WebAppInfo(url="...")),
    InlineKeyboardButton("📁 Files", callback_data="files"),
    InlineKeyboardButton("⚙️ Settings", callback_data="settings"),
]]
```

### Task: Customize Appearance
Edit `mini_app.html` - modify CSS and HTML structure.

## 📚 Code Location Reference

When working with the code:

- **Bot logic** → `bot.py`
- **Web UI** → `mini_app.html`
- **Configuration** → `config.yaml`
- **Dependencies** → `requirements.txt`
- **Docker setup** → `docker-compose.yml`, `Dockerfile`
- **Setup** → `setup.sh`

## 🎯 Next Steps for Development

1. **Basic**: Get project running locally
2. **Intermediate**: Customize UI and commands
3. **Advanced**: Add database, multiple workspaces
4. **Production**: Deploy with Docker, setup monitoring

## 💡 Important Notes for AI Work

### When Claude Reads This File
- Understand the full architecture before modifying
- Check data flow before changing component behavior
- Consider security implications of changes
- Test locally before deploying
- Update this CLAUDE.md when architecture changes

### When Asked to Debug
1. Always check configuration first
2. Test components in isolation
3. Verify connectivity at each layer
4. Check logs for error messages
5. Provide reproduction steps

### When Asked to Add Features
1. Document the new feature in this file
2. Update code comments
3. Test end-to-end flow
4. Consider security implications
5. Update README.md if user-facing

---

**This guide helps AI assistants understand the project deeply and make informed decisions.**
