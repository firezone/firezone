//! An abstraction over well-known dirs like AppData/Local on Windows and $HOME/.config on Linux
//!
//! On Linux it uses `dirs` which is a convenience wrapper for getting XDG environment vars
//!
//! On Windows it uses `known_folders` which calls into Windows for forwards-compatibility
//! We can't use `dirs` on Windows because we need to match connlib for when it opens wintun.dll.
//!
//! I wanted the ProgramData folder on Windows, which `dirs` alone doesn't provide.

use anyhow::{Context as _, Result};
use std::path::PathBuf;

pub use platform::{
    logs, root_runtime, session, settings, tunnel_service_config, tunnel_service_logs, user_runtime,
};

#[cfg(target_os = "linux")]
#[path = "platform/linux.rs"]
pub mod platform;

#[cfg(target_os = "macos")]
#[path = "platform/macos.rs"]
pub mod platform;

#[cfg(target_os = "windows")]
#[path = "platform/windows.rs"]
pub mod platform;

/// Bundle ID / App ID that the client uses to distinguish itself from other programs on the system
///
/// e.g. In ProgramData and AppData we use this to name our subdirectories for configs and data,
/// and Windows may use it to track things like the MSI installer, notification titles,
/// deep link registration, etc.
const BUNDLE_ID: &str = "dev.firezone.client";

pub fn tunnel_log_filter() -> Result<PathBuf> {
    Ok(tunnel_service_config()
        .context("Failed to compute `tunnel_service_config` directory")?
        .join("log-filter"))
}

/// Returns the default path for storing the authentication token
///
/// This is used by the headless client to store tokens persistently on disk.
/// The path varies by platform:
/// - Linux/macOS: `/etc/dev.firezone.client/token`
/// - Windows: `C:\ProgramData\dev.firezone.client\token.txt`
pub fn default_token_path() -> PathBuf {
    platform::default_token_path()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn smoke() {
        for dir in [
            tunnel_service_config(),
            tunnel_service_logs(),
            logs(),
            root_runtime(),
            user_runtime(),
            session(),
            settings(),
        ] {
            let dir = dir.expect("should have gotten Some(path)");
            assert!(
                dir.components()
                    .any(|x| x == std::path::Component::Normal("dev.firezone.client".as_ref()))
            );
        }
    }
}
