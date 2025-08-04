use super::NAMESPACE;
use std::path::PathBuf;

/// Path for Tunnel service config that the Tunnel service can write
///
/// All writes should use `atomicwrites`.
///
/// On Linux, `/var/lib/$NAMESPACE/config/firezone-id`
///
/// `/var/lib` because this is the correct place to put state data not meant for users
/// to touch, which is specific to one host and persists across reboots
/// <https://refspecs.linuxfoundation.org/FHS_3.0/fhs/ch05s08.html>
///
/// `NAMESPACE` because we need our own subdir
///
/// `config` to match how Windows has `config` and `data` both under `AppData/Local/$NAMESPACE`
#[expect(clippy::unnecessary_wraps)] // Signature must match Windows
pub fn tunnel_service_config() -> Option<PathBuf> {
    Some(PathBuf::from("/var/lib").join(NAMESPACE).join("config"))
}

#[expect(clippy::unnecessary_wraps)] // Signature must match Windows
pub fn headless_client_token_path() -> Option<PathBuf> {
    Some(PathBuf::from("/etc").join(NAMESPACE).join("token"))
}

#[expect(clippy::unnecessary_wraps)] // Signature must match Windows
pub fn tunnel_service_logs() -> Option<PathBuf> {
    // TODO: This is magic, it must match the systemd file
    Some(PathBuf::from("/var/log").join(NAMESPACE))
}

/// e.g. `/home/alice/.cache/dev.firezone.client/data/logs`
///
/// Logs are considered cache because they're not configs and it's technically okay
/// if the system / user deletes them to free up space
pub fn logs() -> Option<PathBuf> {
    Some(dirs::cache_dir()?.join(NAMESPACE).join("data").join("logs"))
}

/// e.g. `/run/user/1000/dev.firezone.client/data`
///
/// Crash handler socket and other temp files go here
pub fn runtime() -> Option<PathBuf> {
    Some(dirs::runtime_dir()?.join(NAMESPACE).join("data"))
}

/// e.g. `/run/dev.firezone.client`
///
/// Crash handler socket and other temp files go here
pub fn global_runtime() -> PathBuf {
    PathBuf::from("/run").join(NAMESPACE)
}

/// e.g. `/home/alice/.local/share/dev.firezone.client/data`
///
/// Things like actor name are stored here because they're kind of config,
/// the system / user should not delete them to free up space, but they're not
/// really config since the program will rewrite them automatically to persist sessions.
pub fn session() -> Option<PathBuf> {
    Some(dirs::data_local_dir()?.join(NAMESPACE).join("data"))
}

/// e.g. `/home/alice/.config/dev.firezone.client/config`
///
/// See connlib docs for details
pub fn settings() -> Option<PathBuf> {
    Some(dirs::config_local_dir()?.join(NAMESPACE).join("config"))
}
