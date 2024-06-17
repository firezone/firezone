//! Gives Firezone DNS privilege over other DNS resolvers on the system
//!
//! This uses NRPT and claims all domains, similar to the `systemd-resolved` control method
//! on Linux.
//! This allows us to "shadow" DNS resolvers that are configured by the user or DHCP on
//! physical interfaces, as long as they don't have any NRPT rules that outrank us.
//!
//! If Firezone crashes, restarting Firezone and closing it gracefully will resume
//! normal DNS operation. The Powershell command to remove the NRPT rule can also be run
//! by hand.
//!
//! The system default resolvers don't need to be reverted because they're never deleted.
//!
//! <https://superuser.com/a/1752670>

use anyhow::{Context as _, Result};
use connlib_shared::windows::{CREATE_NO_WINDOW, TUNNEL_NAME};
use std::{net::IpAddr, os::windows::process::CommandExt, process::Command};

pub fn system_resolvers_for_gui() -> Result<Vec<IpAddr>> {
    system_resolvers()
}

#[derive(Default)]
pub(crate) struct DnsController {}

// Unique magic number that we can use to delete our well-known NRPT rule.
// Copied from the deep link schema
const FZ_MAGIC: &str = "firezone-fd0020211111";

impl Drop for DnsController {
    fn drop(&mut self) {
        if let Err(error) = deactivate() {
            tracing::error!(?error, "Failed to deactivate DNS control");
        }
    }
}

impl DnsController {
    /// Set the computer's system-wide DNS servers
    ///
    /// There's a gap in this because on Windows we deactivate and re-activate control.
    ///
    /// The `mut` in `&mut self` is not needed by Rust's rules, but
    /// it would be bad if this was called from 2 threads at once.
    ///
    /// Must be async to match the Linux signature
    #[allow(clippy::unused_async)]
    pub(crate) async fn set_dns(&mut self, dns_config: &[IpAddr]) -> Result<()> {
        deactivate().context("Failed to deactivate DNS control")?;
        activate(dns_config).context("Failed to activate DNS control")?;
        Ok(())
    }
}

pub(crate) fn system_resolvers() -> Result<Vec<IpAddr>> {
    let resolvers = ipconfig::get_adapters()?
        .iter()
        .flat_map(|adapter| adapter.dns_servers())
        .filter(|ip| match ip {
            IpAddr::V4(_) => true,
            // Filter out bogus DNS resolvers on my dev laptop that start with fec0:
            IpAddr::V6(ip) => !ip.octets().starts_with(&[0xfe, 0xc0]),
        })
        .copied()
        .collect();
    // This is private, so keep it at `debug` or `trace`
    tracing::debug!(?resolvers);
    Ok(resolvers)
}

/// Tells Windows to send all DNS queries to our sentinels
///
/// Parameters:
/// - `dns_config_string`: Comma-separated IP addresses of DNS servers, e.g. "1.1.1.1,8.8.8.8"
pub(crate) fn activate(dns_config: &[IpAddr]) -> Result<()> {
    let dns_config_string = dns_config
        .iter()
        .map(|ip| format!("\"{ip}\""))
        .collect::<Vec<_>>()
        .join(",");

    // Set our DNS IP as the DNS server for our interface
    // TODO: Known issue where web browsers will keep a connection open to a site,
    // using QUIC, HTTP/2, or even HTTP/1.1, and so they won't resolve the DNS
    // again unless you let that connection time out:
    // <https://github.com/firezone/firezone/issues/3113#issuecomment-1882096111>
    Command::new("powershell")
        .creation_flags(CREATE_NO_WINDOW)
        .arg("-Command")
        .arg(format!(
            "Set-DnsClientServerAddress {TUNNEL_NAME} -ServerAddresses({dns_config_string})"
        ))
        .status()?;

    tracing::info!("Activating DNS control");
    Command::new("powershell")
        .creation_flags(CREATE_NO_WINDOW)
        .args([
            "-Command",
            "Add-DnsClientNrptRule",
            "-Namespace",
            ".",
            "-Comment",
            FZ_MAGIC,
            "-NameServers",
            &dns_config_string,
        ])
        .status()?;
    Ok(())
}

// Must be `sync` so we can call it from `Drop`
pub(crate) fn deactivate() -> Result<()> {
    Command::new("powershell")
        .creation_flags(CREATE_NO_WINDOW)
        .args(["-Command", "Get-DnsClientNrptRule", "|"])
        .args(["where", "Comment", "-eq", FZ_MAGIC, "|"])
        .args(["foreach", "{"])
        .args(["Remove-DnsClientNrptRule", "-Name", "$_.Name", "-Force"])
        .args(["}"])
        .status()?;
    tracing::info!("Deactivated DNS control");
    Ok(())
}
