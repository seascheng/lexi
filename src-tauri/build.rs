fn main() {
    #[cfg(target_os = "macos")]
    build_native_selection_toolbar();

    tauri_build::build();
}

#[cfg(target_os = "macos")]
fn build_native_selection_toolbar() {
    use std::fs;
    use std::process::Command;

    // Ad-hoc signing for development. For production, use a stable identity via Keychain Access.
    const SIGNING_IDENTITY: &str = "Apple Development: chengweipeng123@163.com (D8YJ3P5B53)";

    let app_dir = "native/LexiSelectionHelper.app";
    let contents_dir = format!("{app_dir}/Contents");
    let macos_dir = format!("{contents_dir}/MacOS");
    fs::create_dir_all(&macos_dir).expect("failed to create native helper app bundle");
    fs::write(
        format!("{contents_dir}/Info.plist"),
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>LexiSelectionHelper</string>
  <key>CFBundleIdentifier</key>
  <string>com.lexi.selection-helper</string>
  <key>CFBundleName</key>
  <string>Lexi Selection Helper</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSDesktopFolderUsageDescription</key>
  <string>Lexi lists folders you tagged on your Desktop in the launcher panel.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>Lexi lists folders you tagged in your Documents folder in the launcher panel.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Lexi lists folders you tagged in your Downloads folder in the launcher panel.</string>
</dict>
</plist>
"#,
    )
    .expect("failed to write native helper Info.plist");

    let status = Command::new("xcrun")
        .args([
            "swiftc",
            "native/SelectionToolbarHelper.swift",
            "native/LauncherPanel.swift",
            "native/PanelDesign.swift",
            "native/ClipboardMonitor.swift",
            "native/ClipboardPanel.swift",
            "native/main.swift",
            "-o",
            "native/LexiSelectionHelper.app/Contents/MacOS/LexiSelectionHelper",
            "-framework",
            "AppKit",
            "-framework",
            "ApplicationServices",
            "-framework",
            "Foundation",
            "-framework",
            "Network",
            "-lsqlite3",
        ])
        .status()
        .expect("failed to start swiftc for native selection toolbar helper");

    if !status.success() {
        panic!("failed to compile native selection toolbar helper");
    }

    let status = Command::new("codesign")
        .args([
            "--force",
            "--sign",
            SIGNING_IDENTITY,
            "--options",
            "runtime",
            "--timestamp=none",
            app_dir,
        ])
        .status()
        .expect("failed to start codesign for native selection toolbar helper");

    if !status.success() {
        panic!("failed to codesign native selection toolbar helper");
    }

    println!("cargo:rerun-if-changed=native/SelectionToolbarHelper.swift");
    println!("cargo:rerun-if-changed=native/LauncherPanel.swift");
    println!("cargo:rerun-if-changed=native/PanelDesign.swift");
    println!("cargo:rerun-if-changed=native/ClipboardMonitor.swift");
    println!("cargo:rerun-if-changed=native/ClipboardPanel.swift");
    println!("cargo:rerun-if-changed=native/main.swift");
}
