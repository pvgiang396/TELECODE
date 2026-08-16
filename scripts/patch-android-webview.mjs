#!/usr/bin/env node
// Bật cookie bên thứ 3 cho WebView Android — BẮT BUỘC chạy sau MỖI lần `npx tauri android init`
// (file target bị tauri-cli ghi đè hoàn toàn từ template của crate `wry`, comment "DO NOT MODIFY"
// trong chính file đó — không có cách nào khác giữ được patch này qua các lần init).
//
// Root cause bug thật: frontend-placeholder/index.html nhúng code-server (origin khác) trong
// <iframe> bên trong trang top-level của app — đúng bối cảnh "cookie bên thứ 3". Android WebView
// (khác hẳn desktop WebKitGTK) CHẶN cookie bên thứ 3 theo mặc định trừ khi tự gọi
// CookieManager.setAcceptThirdPartyCookies(webview, true) — thiếu dòng này khiến sau khi code-server
// xác thực đúng password + trả Set-Cookie, WebView vẫn không lưu cookie, request kế tiếp lại bị coi
// là chưa đăng nhập -> quay lại /login, ô password bị xoá trắng (xem CLAUDE.md để biết chi tiết đã
// điều tra).
import { readFileSync, writeFileSync } from "node:fs";
import { globSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = fileURLToPath(new URL("..", import.meta.url));
const pattern = join(
  projectRoot,
  "src-tauri/gen/android/app/src/main/java/com/pvgiang396/telecode/generated/RustWebView.kt",
);

const matches = globSync(pattern);
if (matches.length === 0) {
  console.error(
    `[patch-android-webview] Không tìm thấy RustWebView.kt (glob: ${pattern}) — chạy 'npx tauri android init' trước.`,
  );
  process.exit(1);
}

const MARKER = "setAcceptThirdPartyCookies";
const INSERT_AFTER = "settings.javaScriptCanOpenWindowsAutomatically = true";
const PATCH_LINE =
  "        CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)";

for (const file of matches) {
  const content = readFileSync(file, "utf8");
  if (content.includes(MARKER)) {
    console.log(`[patch-android-webview] Đã patch từ trước, bỏ qua: ${file}`);
    continue;
  }
  if (!content.includes(INSERT_AFTER)) {
    console.error(
      `[patch-android-webview] Không tìm thấy điểm chèn trong ${file} (template wry có thể đã đổi) — hãy patch tay:`,
    );
    console.error(`  Tìm dòng: settings.javaScriptCanOpenWindowsAutomatically = true`);
    console.error(`  Thêm sau: CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)`);
    process.exit(1);
  }
  const patched = content.replace(
    INSERT_AFTER,
    `${INSERT_AFTER}\n${PATCH_LINE}`,
  );
  writeFileSync(file, patched, "utf8");
  console.log(`[patch-android-webview] Đã patch: ${file}`);
}
