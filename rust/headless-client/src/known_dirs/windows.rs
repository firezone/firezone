use firezone_bin_shared::{BUNDLE_ID, platform::app_local_data_dir};
use known_folders::{KnownFolder, get_known_folder_path};
use std::path::PathBuf;

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
