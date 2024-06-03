//! Windows-specific things like the well-known appdata path, bundle ID, etc.

use crate::Error;
use known_folders::{get_known_folder_path, KnownFolder};
use std::path::PathBuf;

/// Hides Powershell's console on Windows
///
/// <https://stackoverflow.com/questions/59692146/is-it-possible-to-use-the-standard-library-to-spawn-a-process-without-showing-th#60958956>
/// Also used for self-elevation
pub const CREATE_NO_WINDOW: u32 = 0x08000000;

// wintun automatically append " Tunnel" to this
pub const TUNNEL_NAME: &str = "Firezone";

/// Returns e.g. `C:/Users/User/AppData/Local/dev.firezone.client
///
/// This is where we can save config, logs, crash dumps, etc.
/// It's per-user and doesn't roam across different PCs in the same domain.
/// It's read-write for non-elevated processes.
pub fn app_local_data_dir() -> Result<PathBuf, Error> {
    let path = get_known_folder_path(KnownFolder::LocalAppData)
        .ok_or(Error::CantFindLocalAppDataFolder)?
        .join(crate::BUNDLE_ID);
    Ok(path)
}

/// Returns the absolute path for installing and loading `wintun.dll`
///
/// e.g. `C:\Users\User\AppData\Local\dev.firezone.client\data\wintun.dll`
pub fn wintun_dll_path() -> Result<PathBuf, Error> {
    let path = app_local_data_dir()?.join("data").join("wintun.dll");
    Ok(path)
}
