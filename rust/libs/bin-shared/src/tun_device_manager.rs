//! DNS and route control  for the virtual network interface in `tunnel`

#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(target_os = "linux")]
pub use linux as platform;

#[cfg(target_os = "windows")]
pub mod windows;
#[cfg(target_os = "windows")]
pub use windows as platform;

#[cfg(target_os = "macos")]
pub mod macos;
#[cfg(target_os = "macos")]
pub use macos as platform;

pub use platform::TunDeviceManager;

/// The supported IP stack of the TUN device
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TunIpStack {
    V4Only,
    V6Only,
    Dual,
}
