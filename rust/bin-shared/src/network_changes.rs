#[cfg(target_os = "linux")]
#[path = "network_changes/linux.rs"]
#[allow(clippy::unnecessary_wraps)]
mod imp;

#[cfg(target_os = "macos")]
#[path = "network_changes/macos.rs"]
#[allow(clippy::unnecessary_wraps)]
mod imp;

#[cfg(target_os = "windows")]
#[path = "network_changes/windows.rs"]
#[allow(clippy::unnecessary_wraps)]
mod imp;

pub use imp::{new_dns_notifier, new_network_notifier};
