//! Platform-specific code to control the system's DNS resolution
//!
//! On Linux, we use `systemd-resolved` by default. We can also control
//! `/etc/resolv.conf` or explicitly not control DNS.
//!
//! On Windows, we use NRPT by default. We can also explicitly not control DNS.

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
use linux as platform;

#[cfg(target_os = "windows")]
mod windows;
#[cfg(target_os = "windows")]
use windows as platform;

pub(crate) use platform::{deactivate, Method};

// TODO: Move DNS and network change listening to the IPC service, so this won't
// need to be public.
//
/// On all platforms, the GUI always uses the default method.
pub fn system_resolvers_for_gui() -> anyhow::Result<Vec<std::net::IpAddr>> {
    Method::default().system_resolvers()
}

#[derive(Default)]
pub(crate) struct DnsController {
    pub(crate) method: Method,
}
