//! Everything related to the About window
use crate::client::GIT_VERSION;

#[tauri::command]
pub(crate) fn get_cargo_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[tauri::command]
pub(crate) fn get_git_version() -> String {
    GIT_VERSION.to_string()
}
