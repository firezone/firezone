#[cfg(target_os = "linux")]
#[path = "network_changes/linux.rs"]
#[expect(
    clippy::unnecessary_wraps,
    reason = "Signatures must match other platforms"
)]
mod imp;

#[cfg(target_os = "windows")]
#[path = "network_changes/windows.rs"]
mod imp;

#[cfg(any(target_os = "windows", target_os = "linux"))]
pub use imp::{new_dns_notifier, new_network_notifier, Worker};
