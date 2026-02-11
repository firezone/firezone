use crate::BUNDLE_ID;
use std::path::PathBuf;

/// Path for Tunnel service config that the Tunnel service can write
///
/// All writes should use `atomicwrites`.
///
/// On Linux, `/var/lib/$BUNDLE_ID/config/firezone-id`
///
/// `/var/lib` because this is the correct place to put state data not meant for users
/// to touch, which is specific to one host and persists across reboots
/// <https://refspecs.linuxfoundation.org/FHS_3.0/fhs/ch05s08.html>
///
/// `BUNDLE_ID` because we need our own subdir
///
/// `config` to match how Windows has `config` and `data` both under `AppData/Local/$BUNDLE_ID`
#[expect(clippy::unnecessary_wraps)] // Signature must match Windows
pub fn tunnel_service_config() -> Option<PathBuf> {
    Some(PathBuf::from("/var/lib").join(BUNDLE_ID).join("config"))
}

#[expect(clippy::unnecessary_wraps)] // Signature must match Windows
pub fn tunnel_service_logs() -> Option<PathBuf> {
    // TODO: This is magic, it must match the systemd file
    Some(PathBuf::from("/var/log").join(BUNDLE_ID))
}

/// e.g. `/home/alice/.cache/dev.firezone.client/data/logs`
///
/// Logs are considered cache because they're not configs and it's technically okay
/// if the system / user deletes them to free up space
pub fn logs() -> Option<PathBuf> {
    Some(dirs::cache_dir()?.join(BUNDLE_ID).join("data").join("logs"))
}

/// e.g. `/run/dev.firezone.client`
///
/// System-wide runtime directory, typically root-owned.
/// Used for the tunnel service IPC socket.
#[expect(clippy::unnecessary_wraps)] // Signature must match other platforms
pub fn root_runtime() -> Option<PathBuf> {
    Some(PathBuf::from("/run").join(BUNDLE_ID))
}

/// e.g. `/run/user/1000/dev.firezone.client/data`
///
/// Per-user runtime directory. Crash handler socket and other temp files go here.
pub fn user_runtime() -> Option<PathBuf> {
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
