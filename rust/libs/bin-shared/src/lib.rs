#![cfg_attr(test, allow(clippy::unwrap_used))]

pub mod http_health_check;

mod dns_control;
mod network_changes;
mod tun_device_manager;

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

pub mod device_id;
pub mod device_info;
pub mod signals;
pub mod uptime;

pub const TOKEN_ENV_KEY: &str = "FIREZONE_TOKEN";

// wintun automatically append " Tunnel" to this
pub const TUNNEL_NAME: &str = "Firezone";

/// Mark for Firezone sockets to prevent routing loops on Linux.
pub const FIREZONE_MARK: u32 = 0xfd002021;

pub use dns_control::{DnsControlMethod, DnsController};
pub use network_changes::{new_dns_notifier, new_network_notifier};
pub use tun_device_manager::{TunDeviceManager, TunIpStack};
