use anyhow::Result;
use std::path::PathBuf;

#[cfg(target_os = "windows")]
pub fn app_local_data_dir() -> Result<PathBuf, connlib_shared::Error> {
    connlib_shared::windows::app_local_data_dir()
}

#[cfg(not(target_os = "windows"))]
// TODO
pub fn app_local_data_dir() -> Result<PathBuf, connlib_shared::Error> {
    Ok(PathBuf::new())
}

#[cfg(target_os = "windows")]
pub fn program_data_dir() -> Option<PathBuf> {
    known_folders::get_known_folder_path(known_folders::KnownFolder::ProgramData)
}

#[cfg(not(target_os = "windows"))]
// TODO
pub fn program_data_dir() -> Option<PathBuf> {
    Some(PathBuf::new())
}
