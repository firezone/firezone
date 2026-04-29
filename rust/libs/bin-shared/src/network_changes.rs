#[cfg(target_os = "linux")]
#[path = "network_changes/linux.rs"]
mod imp;

#[cfg(target_os = "windows")]
#[path = "network_changes/windows.rs"]
mod imp;

#[cfg(target_os = "macos")]
#[path = "network_changes/macos.rs"]
mod imp;

pub use imp::{NetworkNotifier, new_dns_notifier, new_network_notifier};
