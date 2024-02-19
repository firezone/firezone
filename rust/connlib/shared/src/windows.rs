//! Windows-specific things like the well-known appdata path, bundle ID, etc.

use crate::Error;
use known_folders::{get_known_folder_path, KnownFolder};
use std::path::PathBuf;

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
