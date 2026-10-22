//! DNS and route control  for the virtual network interface in `tunnel`

#[cfg(target_os = "linux")]
pub mod linux;
use std::fmt;

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

impl TunIpStack {
    pub fn supports_ipv4(&self) -> bool {
        match self {
            TunIpStack::V4Only | TunIpStack::Dual => true,
            TunIpStack::V6Only => false,
        }
    }

    pub fn supports_ipv6(&self) -> bool {
        match self {
            TunIpStack::V6Only | TunIpStack::Dual => true,
            TunIpStack::V4Only => false,
        }
    }
}

impl fmt::Display for TunIpStack {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TunIpStack::V4Only => write!(f, "V4Only"),
            TunIpStack::V6Only => write!(f, "V6Only"),
            TunIpStack::Dual => write!(f, "Dual"),
        }
    }
}
