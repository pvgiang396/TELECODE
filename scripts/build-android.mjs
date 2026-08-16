#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync, globSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const tauriRoot = path.join(projectRoot, "src-tauri");

const rustupCargoBin = path.join(process.env.HOME ?? "", ".cargo", "bin");
const buildEnv = {
  ...process.env,
  PATH: [rustupCargoBin, process.env.PATH].filter(Boolean).join(path.delimiter),
};

function run(command, args, cwd) {
  execFileSync(command, args, { cwd, stdio: "inherit", env: buildEnv });
}

function configureReleaseSigning() {
  const androidRoot = path.join(tauriRoot, "gen", "android");
  const appGradle = path.join(androidRoot, "app", "build.gradle.kts");
  const gradleProperties = path.join(androidRoot, "gradle.properties");
  const keystore = path.resolve(
    process.env.TELECODE_ANDROID_KEYSTORE ?? path.join(process.env.HOME ?? projectRoot, ".android", "telecode-debug.keystore"),
  );
  const alias = process.env.TELECODE_ANDROID_KEY_ALIAS ?? "telecode";
  const storePassword = process.env.TELECODE_ANDROID_KEYSTORE_PASSWORD ?? "android";
  const keyPassword = process.env.TELECODE_ANDROID_KEY_PASSWORD ?? storePassword;

  mkdirSync(path.dirname(keystore), { recursive: true });
  if (!existsSync(keystore)) {
    run("keytool", [
      "-genkeypair", "-v", "-keystore", keystore, "-storepass", storePassword,
      "-alias", alias, "-keypass", keyPassword, "-keyalg", "RSA", "-keysize", "2048",
      "-validity", "10000", "-dname", "CN=Telecode Development, OU=Telecode, O=Telecode, C=VN",
    ], projectRoot);
  }

  const properties = readFileSync(gradleProperties, "utf8")
    .split("\n")
    .filter((line) => !line.startsWith("telecode.signing."));
  properties.push(`telecode.signing.storeFile=${keystore}`);
  properties.push(`telecode.signing.storePassword=${storePassword}`);
  properties.push(`telecode.signing.keyAlias=${alias}`);
  properties.push(`telecode.signing.keyPassword=${keyPassword}`);
  writeFileSync(gradleProperties, `${properties.join("\n")}\n`);

  const source = readFileSync(appGradle, "utf8");
  const signingConfig = `    signingConfigs {
        create("telecodeRelease") {
            storeFile = file(providers.gradleProperty("telecode.signing.storeFile").get())
            storePassword = providers.gradleProperty("telecode.signing.storePassword").get()
            keyAlias = providers.gradleProperty("telecode.signing.keyAlias").get()
            keyPassword = providers.gradleProperty("telecode.signing.keyPassword").get()
        }
    }
`;
  const withoutInjectedSigning = source
    .replace(/\s*signingConfigs\s*\{\s*create\("telecodeRelease"\)\s*\{[\s\S]*?\s*\}\s*\}\s*/g, "\n")
    .replace(/\n            signingConfig = signingConfigs\.getByName\("telecodeRelease"\)/g, "");
  const patched = withoutInjectedSigning
    .replace(/\n[ \t]*buildTypes \{/ , `\n${signingConfig}    buildTypes {`)
    .replace(
      '        getByName("release") {',
      '        getByName("release") {\n            signingConfig = signingConfigs.getByName("telecodeRelease")',
    );
  writeFileSync(appGradle, patched);
}

// Init Android project
run("npx", ["tauri", "android", "init"], tauriRoot);

// Patch RustWebView.kt if it exists (optional, don't fail if not found)
try {
  run("node", ["scripts/patch-android-webview.mjs"], projectRoot);
} catch (e) {
  console.warn(`[build-android] WARNING: patch-android-webview failed (non-fatal): ${e.message}`);
  // Continue without patching — cookie handling may fail on Android but build can proceed
}

run("npx", ["tauri", "icon", "assets/icon.png"], projectRoot);

// Patch icon background to transparent (AFTER tauri icon, which regenerates icon files)
try {
  run("node", ["scripts/patch-android-icon-background.mjs"], projectRoot);
} catch (e) {
  console.warn(`[build-android] WARNING: patch-android-icon-background failed (non-fatal): ${e.message}`);
}

const apkRoot = path.join(tauriRoot, "gen", "android", "app", "build", "outputs", "apk");
const apkFiles = [];

const distDir = path.join(projectRoot, "dist", "android");
rmSync(distDir, { recursive: true, force: true });
rmSync(apkRoot, { recursive: true, force: true });

configureReleaseSigning();
run("npx", ["tauri", "android", "build"], tauriRoot);

function collectApks(directory) {
  if (!existsSync(directory)) return;
  for (const entry of readdirSync(directory)) {
    const entryPath = path.join(directory, entry);
    if (statSync(entryPath).isDirectory()) {
      collectApks(entryPath);
    } else if (entry.endsWith(".apk")) {
      apkFiles.push(entryPath);
    }
  }
}

collectApks(apkRoot);
if (apkFiles.length === 0) {
  throw new Error(`Không tìm thấy APK sau khi build tại ${apkRoot}`);
}

mkdirSync(distDir, { recursive: true });
for (const apkFile of apkFiles) {
  if (apkFile.endsWith("-unsigned.apk")) {
    throw new Error(`APK release vẫn unsigned: ${apkFile}`);
  }
  const destination = path.join(distDir, `Telecode_${path.basename(apkFile)}`);
  copyFileSync(apkFile, destination);
  console.log(`[build:android] APK: ${destination}`);
}
