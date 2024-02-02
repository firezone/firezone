//! Windows-specific things like the well-known appdata path, bundle ID, etc.

use crate::Error;
use known_folders::{get_known_folder_path, KnownFolder};
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
///
/// Luckily this is also the AppUserModelId that Windows uses to label notifications,
/// so if your dev system has Firezone installed by MSI, the notifications will look right.
/// <https://learn.microsoft.com/en-us/windows/configuration/find-the-application-user-model-id-of-an-installed-app>
pub const BUNDLE_ID: &str = "dev.firezone.client";

/// Returns e.g. `C:/Users/User/AppData/Local/dev.firezone.client
///
/// This is where we can save config, logs, crash dumps, etc.
/// It's per-user and doesn't roam across different PCs in the same domain.
/// It's read-write for non-elevated processes.
pub fn app_local_data_dir() -> Result<PathBuf, Error> {
    let path = get_known_folder_path(KnownFolder::LocalAppData)
        .ok_or(Error::CantFindLocalAppDataFolder)?
        .join(BUNDLE_ID);
    Ok(path)
}

/// Returns the absolute path for installing and loading `wintun.dll`
///
/// e.g. `C:\Users\User\AppData\Local\dev.firezone.client\data\wintun.dll`
pub fn wintun_dll_path() -> Result<PathBuf, Error> {
    let path = app_local_data_dir()?.join("data").join("wintun.dll");
    Ok(path)
}
