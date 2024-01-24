//! Everything related to the About window, including

use crate::client::{
    gui::{self, Managed},
    GIT_VERSION,
};

#[tauri::command]
pub(crate) async fn get_cargo_version(managed: tauri::State<'_, Managed>) -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[tauri::command]
pub(crate) async fn get_git_version(managed: tauri::State<'_, Managed>) -> String {
    GIT_VERSION.to_string()
}
