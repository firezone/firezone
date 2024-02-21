//! An abstraction over well-known dirs on Linux and Windows, like AppData/Local
//!
//! On Windows it uses `known_folders` which calls into Windows for forwards-compatibility
//! On Linux it uses `dirs` which is a convenience wrapper for getting XDG environment vars
//!
//! I wanted the ProgramData folder on Windows, which `dirs` alone doesn't provide.

use anyhow::Result;
use std::path::PathBuf;

/// `C:\ProgramData` on Windows, `/home/alice/.config
pub fn device_id_dir() -> Option<PathBuf> {
    program_data_dir()
}

/// e.g. `C:\Users\Alice\AppData\Local\dev.firezone.client`
///
/// See connlib docs for details
#[cfg(target_os = "windows")]
fn app_local_data_dir() -> Result<PathBuf, connlib_shared::Error> {
    connlib_shared::windows::app_local_data_dir()
}

/// e.g. `/home/alice/.config/dev.firezone.client`
#[cfg(not(target_os = "windows"))]
// TODO
fn app_local_data_dir() -> Result<PathBuf, connlib_shared::Error> {
    Ok(PathBuf::from(connlib_shared::BUNDLE_ID))
}

/// e.g. `C:\ProgramData\`
///
/// Device ID is stored here until <https://github.com/firezone/firezone/issues/3712> lands
#[cfg(target_os = "windows")]
pub fn program_data_dir() -> Option<PathBuf> {
    known_folders::get_known_folder_path(known_folders::KnownFolder::ProgramData)
}

/// e.g. `/home/alice/.config/`
///
/// Device ID is stored here until <https://github.com/firezone/firezone/issues/3713> lands
///
/// Linux has no direct equivalent to Window's `ProgramData` dir, `/var` doesn't seem
/// to be writable by normal users.
#[cfg(not(target_os = "windows"))]
// TODO
pub fn program_data_dir() -> Option<PathBuf> {
    Some(PathBuf::new())
}
