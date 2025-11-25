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

/// Runtime directory for temporary files
pub fn runtime() -> Option<PathBuf> {
    let user = std::env::var("USER").ok()?;
    Some(PathBuf::from("/tmp").join(format!("{BUNDLE_ID}-{user}")))
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
