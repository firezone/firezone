//! Platform-specific code to control the system's DNS resolution
//!
//! On Linux, we use `systemd-resolved` by default. We can also control
//! `/etc/resolv.conf` or explicitly not control DNS.
//!
//! On Windows, we use NRPT by default. We can also explicitly not control DNS.

use anyhow::Result;
use firezone_bin_shared::platform::DnsControlMethod;
use std::net::IpAddr;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
use linux as platform;

#[cfg(target_os = "windows")]
mod windows;
#[cfg(target_os = "windows")]
use windows as platform;

use platform::system_resolvers;

/// Controls system-wide DNS.
///
/// Always call `deactivate` when Firezone starts.
///
/// Only one of these should exist on the entire system at a time.
pub struct DnsController {
    pub dns_control_method: DnsControlMethod,
}

impl Drop for DnsController {
    fn drop(&mut self) {
        if let Err(error) = self.deactivate() {
            tracing::error!("Failed to deactivate DNS control: {error:#}");
        }
    }
}

impl DnsController {
    pub fn system_resolvers(&self) -> Vec<IpAddr> {
        system_resolvers(self.dns_control_method).unwrap_or_default()
    }
}

// TODO: Move DNS and network change listening to the IPC service, so this won't
// need to be public.
pub fn system_resolvers_for_gui() -> Result<Vec<IpAddr>> {
    system_resolvers(DnsControlMethod::default())
}
