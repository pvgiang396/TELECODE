#!/usr/bin/env node
// Patch Android adaptive icon background để transparent (thay vì nền xanh lá default)
// Chạy sau mỗi lần `npx tauri android init`
//
// Nguyên nhân: Android adaptive icon gồm 2 layer (foreground + background).
// Tauri sinh background.xml với fillColor="#3DDC84" (xanh lá), nhưng chúng ta muốn transparent
// để icon Telecode có nền trong suốt như trên desktop.

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = fileURLToPath(new URL("..", import.meta.url));
const backgroundPath = join(
  projectRoot,
  "src-tauri/gen/android/app/src/main/res/drawable/ic_launcher_background.xml",
);

try {
  const content = readFileSync(backgroundPath, "utf8");
  if (content.includes('android:fillColor="#00000000"')) {
    console.log(`[patch-android-icon] Icon background already transparent, skipping.`);
    process.exit(0);
  }
  
  const patched = content.replace(
    'android:fillColor="#3DDC84"',
    'android:fillColor="#00000000"'
  );
  
  writeFileSync(backgroundPath, patched, "utf8");
  console.log(`[patch-android-icon] ✓ Icon background changed to transparent`);
} catch (err) {
  console.error(`[patch-android-icon] ERROR: ${err.message}`);
  process.exit(1);
}
