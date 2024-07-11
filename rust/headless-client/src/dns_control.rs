//! Platform-specific code to control the system's DNS resolution
//!
//! On Windows, we always use NRPT.
//!
//! On Linux, we can use `/etc/resolv.conf`, `systemd-resolved`, or we can explicitly
//! disable DNS control.

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
use linux as platform;

#[cfg(target_os = "windows")]
mod windows;
#[cfg(target_os = "windows")]
use windows as platform;

pub(crate) use platform::{deactivate, DnsController, Method};

// TODO: Move DNS and network change listening to the IPC service, so this won't
// need to be public.
pub fn system_resolvers_for_gui() -> anyhow::Result<Vec<std::net::IpAddr>> {
    Method::for_gui().system_resolvers()
}
