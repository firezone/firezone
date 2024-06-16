use connlib_shared::BUNDLE_ID;
use known_folders::{get_known_folder_path, KnownFolder};
use std::path::PathBuf;

/// Path for IPC service config that either the IPC service or GUI can write
///
/// e.g. the device ID should only be written by the IPC service, and
/// the log filter should only be written by the GUI. No file should be written
/// by both programs. All writes should use `atomicwrites`.
///
/// On Windows, `C:/ProgramData/$BUNDLE_ID/config`
#[allow(clippy::unnecessary_wraps)]
pub fn ipc_service_config() -> Option<PathBuf> {
    Some(
        get_known_folder_path(KnownFolder::ProgramData)?
            .join(connlib_shared::BUNDLE_ID)
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
    Some(
        connlib_shared::windows::app_local_data_dir()
            .ok()?
            .join("data")
            .join("logs"),
    )
}

/// e.g. `C:\Users\Alice\AppData\Local\dev.firezone.client\data`
///
/// Crash handler socket and other temp files go here
pub fn runtime() -> Option<PathBuf> {
    Some(
        connlib_shared::windows::app_local_data_dir()
            .ok()?
            .join("data"),
    )
}

/// e.g. `C:\Users\Alice\AppData\Local\dev.firezone.client\data`
///
/// Things like actor name go here
pub fn session() -> Option<PathBuf> {
    Some(
        connlib_shared::windows::app_local_data_dir()
            .ok()?
            .join("data"),
    )
}

/// e.g. `C:\Users\Alice\AppData\Local\dev.firezone.client\config`
///
/// See connlib docs for details
pub fn settings() -> Option<PathBuf> {
    Some(
        connlib_shared::windows::app_local_data_dir()
            .ok()?
            .join("config"),
    )
}
