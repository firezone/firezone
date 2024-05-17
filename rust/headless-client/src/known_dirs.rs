//! An abstraction over well-known dirs like AppData/Local on Windows and $HOME/.config on Linux
//!
//! On Linux it uses `dirs` which is a convenience wrapper for getting XDG environment vars
//!
//! On Windows it uses `known_folders` which calls into Windows for forwards-compatibility
//! We can't use `dirs` on Windows because we need to match connlib for when it opens wintun.dll.
//!
//! I wanted the ProgramData folder on Windows, which `dirs` alone doesn't provide.

pub use platform::{ipc_service_logs, logs, runtime, session, settings};

#[cfg(target_os = "linux")]
pub mod platform {
    use connlib_shared::BUNDLE_ID;
    use std::path::PathBuf;

    #[allow(clippy::unnecessary_wraps)]
    pub fn ipc_service_logs() -> Option<PathBuf> {
        // TODO: This is magic, it must match the systemd file
        Some(PathBuf::from("/var/log").join(connlib_shared::BUNDLE_ID))
    }

    /// e.g. `/home/alice/.cache/dev.firezone.client/data/logs`
    ///
    /// Logs are considered cache because they're not configs and it's technically okay
    /// if the system / user deletes them to free up space
    pub fn logs() -> Option<PathBuf> {
        Some(dirs::cache_dir()?.join(BUNDLE_ID).join("data").join("logs"))
    }

    /// e.g. `/run/user/1000/dev.firezone.client/data`
    ///
    /// Crash handler socket and other temp files go here
    pub fn runtime() -> Option<PathBuf> {
        Some(dirs::runtime_dir()?.join(BUNDLE_ID).join("data"))
    }

    /// e.g. `/home/alice/.local/share/dev.firezone.client/data`
    ///
    /// Things like actor name are stored here because they're kind of config,
    /// the system / user should not delete them to free up space, but they're not
    /// really config since the program will rewrite them automatically to persist sessions.
    pub fn session() -> Option<PathBuf> {
        Some(dirs::data_local_dir()?.join(BUNDLE_ID).join("data"))
    }

    /// e.g. `/home/alice/.config/dev.firezone.client/config`
    ///
    /// See connlib docs for details
    pub fn settings() -> Option<PathBuf> {
        Some(dirs::config_local_dir()?.join(BUNDLE_ID).join("config"))
    }
}

#[cfg(target_os = "macos")]
pub mod platform {
    pub fn ipc_service_logs() -> Option<PathBuf> {
        unimplemented!()
    }

    pub fn logs() -> Option<PathBuf> {
        unimplemented!()
    }

    pub fn runtime() -> Option<PathBuf> {
        unimplemented!()
    }

    pub fn session() -> Option<PathBuf> {
        unimplemented!()
    }

    pub fn settings() -> Option<PathBuf> {
        unimplemented!()
    }
}

#[cfg(target_os = "windows")]
pub mod platform {
    use connlib_shared::BUNDLE_ID;
    use known_folders::{get_known_folder_path, KnownFolder};
    use std::path::PathBuf;

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
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn smoke() {
        for dir in [ipc_service_logs(), logs(), runtime(), session(), settings()] {
            let dir = dir.expect("should have gotten Some(path)");
            assert!(dir
                .components()
                .any(|x| x == std::path::Component::Normal("dev.firezone.client".as_ref())));
        }
    }
}
