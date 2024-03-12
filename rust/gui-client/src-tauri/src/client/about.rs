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

#[cfg(test)]
mod tests {
    #[test]
    fn version() {
        return;
        let cargo = super::get_cargo_version();
        let git = super::get_git_version();

        assert!(cargo != "Unknown", "{}", cargo);
        assert!(git != "Unknown", "{}", git);
        assert!(cargo.len() >= 2, "{}", cargo);
        assert!(git.len() >= 6, "{}", git);
    }
}
