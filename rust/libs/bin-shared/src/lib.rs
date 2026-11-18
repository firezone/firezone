#![cfg_attr(test, allow(clippy::unwrap_used))]

pub mod http_health_check;

mod dns_control;
mod network_changes;
mod power;
mod tun_device_manager;

#[cfg(target_os = "linux")]
mod dbus;

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

/// Parses a duration in jiff's friendly format, e.g. "5m", "1h 30m" or "30d".
///
/// Days count as 24 hours.
pub fn parse_duration(s: &str) -> anyhow::Result<std::time::Duration> {
    let span = s.parse::<jiff::Span>()?;
    let duration = span.to_duration(jiff::SpanRelativeTo::days_are_24_hours())?;
    let duration = std::time::Duration::try_from(duration)?;

    Ok(duration)
}

pub use dns_control::{DnsControlMethod, DnsController};
pub use network_changes::{new_dns_notifier, new_network_notifier};
pub use power::{ResumeNotifier, new_resume_notifier};
pub use tun_device_manager::{TunDeviceManager, TunIpStack};

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[test]
    fn parse_duration_counts_days_as_24_hours() {
        assert_eq!(
            parse_duration("30d").unwrap(),
            Duration::from_secs(30 * 24 * 60 * 60)
        );
    }
}
