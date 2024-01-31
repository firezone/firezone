//! Windows-specific things like the well-known appdata path, bundle ID, etc.

use std::path::PathBuf;

/// Bundle ID / App ID that we use to distinguish ourself from other programs on the system
///
/// e.g. In ProgramData and AppData we use this to name our subdirectories for configs and data,
/// and Windows may use it to track things like the MSI installer, notification titles,
/// deep link registration, etc.
///
/// This should be identical to the `tauri.bundle.identifier` over in `tauri.conf.json`,
/// but sometimes I need to use this before Tauri has booted up, or in a place where
/// getting the Tauri app handle would be awkward.
pub const BUNDLE_ID: &str = "dev.firezone.client";

/// Returns e.g. `C:/Users/User/AppData/Local/dev.firezone.client
///
/// This is where we can save config, logs, crash dumps, etc.
/// It's per-user and doesn't roam across different PCs in the same domain.
/// It's read-write for non-elevated processes.
pub fn app_local_data_dir() -> Option<PathBuf> {
    let path = known_folders::get_known_folder_path(known_folders::KnownFolder::LocalAppData)?
        .join(BUNDLE_ID);
    Some(path)
}

/// Returns the absolute path for installing and loading `wintun.dll`
///
/// e.g. `C:\Users\User\AppData\Local\dev.firezone.client\data\wintun.dll`
pub fn wintun_dll_path() -> Option<PathBuf> {
    let path = app_local_data_dir()?.join("data").join("wintun.dll");
    Some(path)
}
