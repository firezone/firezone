use crate::BUNDLE_ID;
use std::path::PathBuf;

/// Returns the user's home directory
fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

/// Path for Tunnel service config that the Tunnel service can write
#[expect(clippy::unnecessary_wraps)] // Signature must match Windows
pub fn tunnel_service_config() -> Option<PathBuf> {
    Some(
        PathBuf::from("/Library/Application Support")
            .join(BUNDLE_ID)
            .join("config"),
    )
}

/// Path for Tunnel service logs
#[expect(clippy::unnecessary_wraps)] // Signature must match Windows
pub fn tunnel_service_logs() -> Option<PathBuf> {
    Some(PathBuf::from("/Library/Logs").join(BUNDLE_ID))
}

/// User-specific logs directory
pub fn logs() -> Option<PathBuf> {
    Some(
        home_dir()?
            .join("Library/Caches")
            .join(BUNDLE_ID)
            .join("logs"),
    )
}

/// System-wide runtime directory for temporary files.
///
/// On macOS, this is the same as [`user_runtime`] because the production
/// macOS client uses the native Swift IPC implementation.
pub fn root_runtime() -> Option<PathBuf> {
    user_runtime()
}

/// Per-user runtime directory for temporary files.
///
/// Uses the OS-assigned per-user temp directory (`TMPDIR` on macOS) rather than
/// hardcoding `/tmp` with the `USER` env var, which is unreliable and can be
/// influenced by the process environment.
#[expect(clippy::unnecessary_wraps)] // Signature must match other platforms
pub fn user_runtime() -> Option<PathBuf> {
    Some(std::env::temp_dir().join(BUNDLE_ID))
}

/// User session data directory
pub fn session() -> Option<PathBuf> {
    Some(
        home_dir()?
            .join("Library/Application Support")
            .join(BUNDLE_ID)
            .join("data"),
    )
}

/// User settings/config directory
pub fn settings() -> Option<PathBuf> {
    Some(
        home_dir()?
            .join("Library/Preferences")
            .join(BUNDLE_ID)
            .join("config"),
    )
}
