//! Platform-specific code to control the system's DNS resolution
//!
//! On Linux, we use `systemd-resolved` by default. We can also control
//! `/etc/resolv.conf` or explicitly not control DNS.
//!
//! On Windows, we use NRPT by default. We can also explicitly not control DNS.

use std::{collections::HashSet, net::IpAddr};

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
use linux as platform;

#[cfg(target_os = "windows")]
mod windows;
#[cfg(target_os = "windows")]
use windows as platform;

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
use macos as platform;

use platform::system_resolvers;

pub use platform::DnsControlMethod;

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
        dedup(system_resolvers(self.dns_control_method).unwrap_or_default())
    }
}

/// Removes duplicate resolvers while preserving order.
///
/// Multiple NICs on the same network can report the same upstream resolvers.
/// We keep the first occurrence of each because the downstream sentinel mapping
/// relies on the resolver order.
fn dedup(resolvers: Vec<IpAddr>) -> Vec<IpAddr> {
    let mut seen = HashSet::new();
    resolvers
        .into_iter()
        .filter(|ip| seen.insert(*ip))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dedup_removes_duplicates_and_preserves_order() {
        let resolvers = vec![
            ip("192.168.1.254"),
            ip("2600:1700:3ecb:2410::1"),
            ip("192.168.1.254"),
            ip("2600:1700:3ecb:2410::1"),
            ip("1.1.1.1"),
        ];

        assert_eq!(
            dedup(resolvers),
            vec![
                ip("192.168.1.254"),
                ip("2600:1700:3ecb:2410::1"),
                ip("1.1.1.1"),
            ]
        );
    }

    fn ip(address: &str) -> IpAddr {
        address.parse().unwrap()
    }
}
