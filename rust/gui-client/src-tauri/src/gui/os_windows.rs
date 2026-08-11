use anyhow::{Context, Result};
use std::env;
use winreg::RegKey;
use winreg::enums::*;

pub async fn set_autostart(enabled: bool) -> Result<()> {
    // Get path to the current executable
    let exec_path = env::current_exe().context("Failed to get current executable path")?;
    let exec_path_str = format!("\"{}\"", exec_path.to_string_lossy());

    // Open the registry key for autostart configuration
    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let run_key = hkcu
        .open_subkey_with_flags(
            r"Software\Microsoft\Windows\CurrentVersion\Run",
            KEY_READ | KEY_WRITE,
        )
        .context("Failed to open registry key for autostart")?;

    if enabled {
        // Add the application to autostart
        run_key
            .set_value("Firezone", &exec_path_str)
            .context("Failed to add application to autostart registry")?;

        tracing::debug!("Added application to autostart: {}", exec_path_str);
    } else {
        // Remove the application from autostart
        match run_key.delete_value("Firezone") {
            Ok(_) => tracing::debug!("Removed application from autostart"),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                return Err(e).context("Failed to remove application from autostart registry");
            }
        }
    }

    Ok(())
}

/// The AppUserModelID Windows attributes our notifications to
///
/// Windows silently drops a toast whose AUMID doesn't match the calling
/// process's identity. Packaged builds run under the sparse MSIX identity, so
/// we register under the package AUMID (`Firezone` is the
/// `<Application Id="Firezone">` from `win_files/AppxManifest.xml`; together
/// with the package family name it forms the AUMID) and the title and icon
/// come from the manifest's `VisualElements`. Un-packaged dev builds (no
/// package identity) fall back to [`crate::BUNDLE_ID`].
/// <https://github.com/tauri-apps/winrt-notification/issues/17#issuecomment-1988715694>
pub(crate) fn notification_app_id() -> String {
    if crate::package_identity::has_package_identity() {
        format!("{}!Firezone", crate::PACKAGE_FAMILY_NAME)
    } else {
        crate::BUNDLE_ID.to_owned()
    }
}
