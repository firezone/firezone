//! An abstraction over well-known dirs like AppData/Local on Windows and $HOME/.config on Linux
//!
//! On Linux it uses `dirs` which is a convenience wrapper for getting XDG environment vars
//!
//! On Windows it uses `known_folders` which calls into Windows for forwards-compatibility
//! We can't use `dirs` on Windows because we need to match connlib for when it opens wintun.dll.
//!
//! I wanted the ProgramData folder on Windows, which `dirs` alone doesn't provide.

pub(crate) use imp::{device_id, logs, session, settings};

#[cfg(target_os = "linux")]
mod imp {
    use connlib_shared::BUNDLE_ID;
    use std::path::PathBuf;

    /// e.g. `/home/alice/.config/dev.firezone.client/config`
    ///
    /// Device ID is stored here until <https://github.com/firezone/firezone/issues/3713> lands
    ///
    /// Linux has no direct equivalent to Window's `ProgramData` dir, `/var` doesn't seem
    /// to be writable by normal users.
    pub(crate) fn device_id() -> Option<PathBuf> {
        Some(dirs::config_local_dir()?.join(BUNDLE_ID).join("config"))
    }

    /// e.g. `/home/alice/.cache/dev.firezone.client/data/logs`
    ///
    /// Logs are considered cache because they're not configs and it's technically okay
    /// if the system / user deletes them to free up space
    pub(crate) fn logs() -> Option<PathBuf> {
        Some(dirs::cache_dir()?.join(BUNDLE_ID).join("data").join("logs"))
    }

    /// e.g. `/home/alice/.local/share/dev.firezone.client/data`
    ///
    /// Things like actor name are stored here because they're kind of config,
    /// the system / user should not delete them to free up space, but they're not
    /// really config since the program will rewrite them automatically to persist sessions.
    pub(crate) fn session() -> Option<PathBuf> {
        Some(dirs::data_local_dir()?.join(BUNDLE_ID).join("data"))
    }

    /// e.g. `/home/alice/.config/dev.firezone.client/config`
    ///
    /// See connlib docs for details
    pub(crate) fn settings() -> Option<PathBuf> {
        Some(dirs::config_local_dir()?.join(BUNDLE_ID).join("config"))
    }
}

#[cfg(target_os = "windows")]
mod imp {
    use connlib_shared::BUNDLE_ID;
    use known_folders::{get_known_folder_path, KnownFolder};
    use std::path::PathBuf;

    /// e.g. `C:\ProgramData\dev.firezone.client\config`
    ///
    /// Device ID is stored here until <https://github.com/firezone/firezone/issues/3712> lands
    pub(crate) fn device_id() -> Option<PathBuf> {
        Some(
            get_known_folder_path(KnownFolder::ProgramData)?
                .join(BUNDLE_ID)
                .join("config"),
        )
    }

    /// e.g. `C:\Users\Alice\AppData\Local\dev.firezone.client\data\logs`
    ///
    /// See connlib docs for details
    pub(crate) fn logs() -> Option<PathBuf> {
        Some(
            connlib_shared::windows::app_local_data_dir()
                .ok()?
                .join("data")
                .join("logs"),
        )
    }

    /// e.g. `C:\Users\Alice\AppData\Local\dev.firezone.client\data`
    ///
    /// Things like actor name go here
    pub(crate) fn session() -> Option<PathBuf> {
        Some(
            connlib_shared::windows::app_local_data_dir()
                .ok()?
                .join("data"),
        )
    }

    /// e.g. `C:\Users\Alice\AppData\Local\dev.firezone.client\config`
    ///
    /// See connlib docs for details
    pub(crate) fn settings() -> Option<PathBuf> {
        Some(
            connlib_shared::windows::app_local_data_dir()
                .ok()?
                .join("config"),
        )
    }
}
