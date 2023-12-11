fn main() -> anyhow::Result<()> {
    let win = tauri_build::WindowsAttributes::new().app_manifest(WINDOWS_MANIFEST);
    let attr = tauri_build::Attributes::new().windows_attributes(win);
    tauri_build::try_build(attr)?;
    Ok(())
}

// If we ask for admin privilege in the manifest, we can't run in the CLI,
// which makes debugging hard.
// So always ask for it in Release, which is simpler for users, and in Release
// mode we run as a GUI so we lose stdout/stderr anyway.
// If you need admin privileges for debugging, you can right-click the debug
// exe anyway, it's not any worse.

#[cfg(debug_assertions)]
const WINDOWS_MANIFEST: &str = include_str!("firezone-windows-client-debug.manifest");

#[cfg(not(debug_assertions))]
const WINDOWS_MANIFEST: &str = include_str!("firezone-windows-client-release.manifest");
