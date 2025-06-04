use crate::BUNDLE_ID;
use std::path::PathBuf;

/// Returns the user's home directory
///
/// e.g. `/Users/alice`
fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

/// Path for Tunnel service config that the Tunnel service can write
///
/// All writes should use `atomicwrites`.
///
/// On macOS, `/Library/Application Support/$BUNDLE_ID/config`
///
/// `/Library/Application Support` is the correct place for system-wide application
/// support files that persist across reboots and are not meant for users to touch directly.
/// This follows Apple's File System Programming Guide.
///
/// `BUNDLE_ID` because we need our own subdir
///
/// `config` to match how Windows has `config` and `data` both under `AppData/Local/$BUNDLE_ID`
#[expect(clippy::unnecessary_wraps)] // Signature must match Windows
pub fn tunnel_service_config() -> Option<PathBuf> {
    Some(
        PathBuf::from("/Library/Application Support")
            .join(BUNDLE_ID)
            .join("config"),
    )
}

/// Path for Tunnel service logs
///
/// On macOS, `/Library/Logs/$BUNDLE_ID`
///
/// `/Library/Logs` is the standard location for system-wide application logs
/// that are managed by the system or root processes.
#[expect(clippy::unnecessary_wraps)] // Signature must match Windows
pub fn tunnel_service_logs() -> Option<PathBuf> {
    Some(PathBuf::from("/Library/Logs").join(BUNDLE_ID))
}

/// User-specific logs directory
///
/// e.g. `/Users/alice/Library/Caches/$BUNDLE_ID/logs`
///
/// Logs are considered cache because they're not configs and it's technically okay
/// if the system / user deletes them to free up space. This follows macOS conventions
/// where `~/Library/Caches` is used for disposable cached data.
pub fn logs() -> Option<PathBuf> {
    Some(
        home_dir()?
            .join("Library/Caches")
            .join(BUNDLE_ID)
            .join("logs"),
    )
}

/// Runtime directory for temporary files
///
/// On macOS, we use `/tmp/$BUNDLE_ID-$USER` since macOS doesn't have a standard
/// per-user runtime directory like Linux's `/run/user/$UID`.
///
/// Crash handler socket and other temp files go here.
pub fn runtime() -> Option<PathBuf> {
    let user = std::env::var("USER").ok()?;
    Some(PathBuf::from("/tmp").join(format!("{}-{}", BUNDLE_ID, user)))
}

/// User session data directory
///
/// e.g. `/Users/alice/Library/Application Support/$BUNDLE_ID/data`
///
/// Things like actor name are stored here because they're kind of config,
/// the system / user should not delete them to free up space, but they're not
/// really config since the program will rewrite them automatically to persist sessions.
///
/// Uses `~/Library/Application Support` which is the standard location for
/// user-specific application support files on macOS.
pub fn session() -> Option<PathBuf> {
    Some(
        home_dir()?
            .join("Library/Application Support")
            .join(BUNDLE_ID)
            .join("data"),
    )
}

/// User settings/config directory
///
/// e.g. `/Users/alice/Library/Preferences/$BUNDLE_ID/config`
///
/// Uses `~/Library/Preferences` which is the standard location for user-specific
/// application preferences and configuration files on macOS.
///
/// See connlib docs for details
pub fn settings() -> Option<PathBuf> {
    Some(
        home_dir()?
            .join("Library/Preferences")
            .join(BUNDLE_ID)
            .join("config"),
    )
}
