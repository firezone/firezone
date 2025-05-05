use crate::BUNDLE_ID;
use anyhow::{Context as _, Result};
use known_folders::{KnownFolder, get_known_folder_path};
use std::path::PathBuf;

/// Returns e.g. `C:/Users/User/AppData/Local/dev.firezone.client
///
/// This is where we can save config, logs, crash dumps, etc.
/// It's per-user and doesn't roam across different PCs in the same domain.
/// It's read-write for non-elevated processes.
pub fn app_local_data_dir() -> Result<PathBuf> {
    let path = get_known_folder_path(KnownFolder::LocalAppData)
        .context("Can't find %LOCALAPPDATA% dir")?
        .join(crate::BUNDLE_ID);
    Ok(path)
}

/// Path for IPC service config that the IPC service can write
///
/// All writes should use `atomicwrites`.
///
/// On Windows, `C:/ProgramData/$BUNDLE_ID/config`
pub fn ipc_service_config() -> Option<PathBuf> {
    Some(
        get_known_folder_path(KnownFolder::ProgramData)?
            .join(BUNDLE_ID)
            .join("config"),
    )
}

pub fn ipc_service_logs() -> Option<PathBuf> {
    Some(
        get_known_folder_path(KnownFolder::ProgramData)?
            .join(BUNDLE_ID)
            .join("data")
            .join("logs"),
    )
}

/// e.g. `C:\Users\Alice\AppData\Local\dev.firezone.client\data\logs`
///
/// See connlib docs for details
pub fn logs() -> Option<PathBuf> {
    Some(app_local_data_dir().ok()?.join("data").join("logs"))
}

/// e.g. `C:\Users\Alice\AppData\Local\dev.firezone.client\data`
///
/// Crash handler socket and other temp files go here
pub fn runtime() -> Option<PathBuf> {
    Some(app_local_data_dir().ok()?.join("data"))
}

/// e.g. `C:\Users\Alice\AppData\Local\dev.firezone.client\data`
///
/// Things like actor name go here
pub fn session() -> Option<PathBuf> {
    Some(app_local_data_dir().ok()?.join("data"))
}

/// e.g. `C:\Users\Alice\AppData\Local\dev.firezone.client\config`
///
/// See connlib docs for details
pub fn settings() -> Option<PathBuf> {
    Some(app_local_data_dir().ok()?.join("config"))
}
