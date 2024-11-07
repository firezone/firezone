//! Everything related to the About window

#[tauri::command]
pub(crate) fn get_cargo_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[tauri::command]
pub(crate) fn get_git_version() -> String {
    option_env!("GITHUB_SHA").unwrap_or("unknown").to_owned()
}

#[cfg(test)]
mod tests {
    #[test]
    fn version() {
        let cargo = super::get_cargo_version();
        let git = super::get_git_version();

        assert!(cargo != "Unknown", "{}", cargo);
        assert!(cargo.starts_with("1."));
        assert!(cargo.len() >= 2, "{}", cargo);
    }
}
