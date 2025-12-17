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
pub mod known_dirs;
pub mod signals;
pub mod uptime;

pub const TOKEN_ENV_KEY: &str = "FIREZONE_TOKEN";

// wintun automatically append " Tunnel" to this
pub const TUNNEL_NAME: &str = "Firezone";

/// Bundle ID / App ID that the client uses to distinguish itself from other programs on the system
///
/// e.g. In ProgramData and AppData we use this to name our subdirectories for configs and data,
/// and Windows may use it to track things like the MSI installer, notification titles,
/// deep link registration, etc.
///
/// This should be identical to the `tauri.bundle.identifier` over in `tauri.conf.json`,
/// but sometimes I need to use this before Tauri has booted up, or in a place where
/// getting the Tauri app handle would be awkward.
///
/// Luckily this is also the AppUserModelId that Windows uses to label notifications,
/// so if your dev system has Firezone installed by MSI, the notifications will look right.
/// <https://learn.microsoft.com/en-us/windows/configuration/find-the-application-user-model-id-of-an-installed-app>
pub const BUNDLE_ID: &str = "dev.firezone.client";

/// Mark for Firezone sockets to prevent routing loops on Linux.
pub const FIREZONE_MARK: u32 = 0xfd002021;

pub use dns_control::{DnsControlMethod, DnsController};
pub use network_changes::{new_dns_notifier, new_network_notifier};
pub use tun_device_manager::{TunDeviceManager, TunIpStack};
