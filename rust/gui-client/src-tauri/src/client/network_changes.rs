#[cfg(target_os = "linux")]
#[path = "network_changes/linux.rs"]
mod imp;

#[cfg(target_os = "macos")]
#[path = "network_changes/macos.rs"]
mod imp;

#[cfg(target_os = "windows")]
#[path = "network_changes/windows.rs"]
mod imp;

pub(crate) use imp::{check_internet, run_debug, run_dns_debug, Worker};
