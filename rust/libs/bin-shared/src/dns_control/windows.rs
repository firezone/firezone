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

use crate::DnsController;
use crate::windows::{CREATE_NO_WINDOW, TUNNEL_UUID, error::EPT_S_NOT_REGISTERED};
use anyhow::{Context as _, ErrorExt as _, Result};
use dns_types::DomainName;
use std::{io, net::IpAddr, os::windows::process::CommandExt, path::Path, process::Command};
use windows::Win32::System::GroupPolicy::{RP_FORCE, RefreshPolicyEx};

// Unique magic number that we can use to delete our well-known NRPT rule.
// Copied from the deep link schema
const FZ_MAGIC: &str = "firezone-fd0020211111";

#[derive(clap::ValueEnum, Clone, Copy, Debug, Default)]
pub enum DnsControlMethod {
    /// Explicitly disable DNS control.
    ///
    /// We don't use an `Option<Method>` because leaving out the CLI arg should
    /// use NRPT, not disable DNS control.
    Disabled,
    /// NRPT, the only DNS control method we use on Windows.
    #[default]
    Nrpt,
}

impl DnsController {
    /// Deactivate any control Firezone has over the computer's DNS
    ///
    /// Must be `sync` so we can call it from `Drop`
    #[expect(clippy::unnecessary_wraps, reason = "Linux version is fallible")]
    pub fn deactivate(&mut self) -> Result<()> {
        let hklm = winreg::RegKey::predef(winreg::enums::HKEY_LOCAL_MACHINE);

        if let Err(error) = delete_subkey(&hklm, local_nrpt_path().join(NRPT_REG_KEY)) {
            tracing::warn!("Failed to delete local NRPT: {error:#}");
        }
        if let Err(error) = delete_subkey(&hklm, group_nrpt_path().join(NRPT_REG_KEY)) {
            tracing::warn!("Failed to delete group NRPT: {error:#}");
        }

        match refresh_group_policy() {
            Ok(()) => {}
            Err(e)
                if e.any_downcast_ref::<windows::core::Error>()
                    .is_some_and(|e| e.code() == EPT_S_NOT_REGISTERED) =>
            {
                // This may happen if we make this syscall multiple times in a row (which we do as we shut down).
                // It isn't very concerning and deactivation of DNS control is on a best-effort basis anyway.
            }
            Err(e) => {
                tracing::warn!("{e:#}");
            }
        }

        tracing::info!("Deactivated DNS control");

        Ok(())
    }

    /// Set the computer's system-wide DNS servers
    ///
    /// The `mut` in `&mut self` is not needed by Rust's rules, but
    /// it would be bad if this was called from 2 threads at once.
    ///
    /// Must be async and an owned `Vec` to match the Linux signature
    #[expect(clippy::unused_async)]
    pub async fn set_dns(
        &mut self,
        dns_config: Vec<IpAddr>,
        search_domain: Option<DomainName>,
    ) -> Result<()> {
        match self.dns_control_method {
            DnsControlMethod::Disabled => {}
            DnsControlMethod::Nrpt => {
                activate(&dns_config, search_domain).context("Failed to activate DNS control")?
            }
        }
        Ok(())
    }

    /// Flush Windows' system-wide DNS cache
    ///
    /// `&self` is needed to match the Linux signature
    pub fn flush(&self) -> Result<()> {
        tracing::debug!("Flushing Windows DNS cache...");
        Command::new("ipconfig")
            .creation_flags(CREATE_NO_WINDOW)
            .args(["/flushdns"])
            .status()?;
        tracing::debug!("Flushed DNS.");
        Ok(())
    }
}

fn delete_subkey(key: &winreg::RegKey, subkey: impl AsRef<Path>) -> io::Result<()> {
    let path = subkey.as_ref();

    if let Err(error) = key.delete_subkey(path) {
        if error.kind() == io::ErrorKind::NotFound {
            return Ok(());
        }

        return Err(error);
    }

    tracing::debug!(path = %path.display(), "Deleted registry key");

    Ok(())
}

pub(crate) fn system_resolvers(_method: DnsControlMethod) -> Result<Vec<IpAddr>> {
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

/// A UUID for the Firezone Client NRPT rule, chosen randomly at dev time.
///
/// Our NRPT rule should always live in the registry at
/// `Computer\HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters\DnsPolicyConfig\$NRPT_REG_KEY`
///
/// We can use this UUID as a handle to enable, disable, or modify the rule.
const NRPT_REG_KEY: &str = "{6C0507CB-C884-4A78-BC55-0ACEE21227F6}";

/// Tells Windows to send all DNS queries to our sentinels
fn activate(dns_config: &[IpAddr], search_domain: Option<DomainName>) -> Result<()> {
    // TODO: Known issue where web browsers will keep a connection open to a site,
    // using QUIC, HTTP/2, or even HTTP/1.1, and so they won't resolve the DNS
    // again unless you let that connection time out:
    // <https://github.com/firezone/firezone/issues/3113#issuecomment-1882096111>
    tracing::info!(nameservers = ?dns_config, ?search_domain, "Activating DNS control");

    let hklm = winreg::RegKey::predef(winreg::enums::HKEY_LOCAL_MACHINE);

    if let Err(e) = set_nameservers_on_interface(dns_config) {
        tracing::warn!(
            "Failed to explicitly set nameservers on tunnel interface; DNS resources in WSL may not work: {e:#}"
        );
    }

    set_search_domain_on_interface(search_domain)
        .context("Failed to set search domain on interface")?;

    // e.g. [100.100.111.1, 100.100.111.2] -> "100.100.111.1;100.100.111.2"
    let dns_config_string = itertools::join(dns_config, ";");

    // It's safe to always set the local rule.
    let (key, _) = hklm
        .create_subkey(local_nrpt_path().join(NRPT_REG_KEY))
        .context("Failed to create local NRPT registry key")?;
    set_nrpt_rule(&key, &dns_config_string).context("Failed to set local NRPT rule")?;

    // If this key exists, our local NRPT rules are ignored and we have to stick
    // them in with group policies for some reason.
    let group_policy_key_exists = hklm.open_subkey(group_nrpt_path()).is_ok();
    tracing::debug!(?group_policy_key_exists);

    if group_policy_key_exists {
        // TODO: Possible TOCTOU problem - We check whether the key exists, then create a subkey if it does. If Group Policy is disabled between those two steps, and something else removes that parent key, we'll re-create it, which might be bad. We can set up unit tests to see if it's possible to avoid this in the registry, but for now it's not a huge deal.
        let (key, _) = hklm
            .create_subkey(group_nrpt_path().join(NRPT_REG_KEY))
            .context("Failed to create group NRPT registry key")?;
        set_nrpt_rule(&key, &dns_config_string).context("Failed to set group NRPT rule")?;
        refresh_group_policy()?;
    }

    tracing::info!("DNS control active.");

    Ok(())
}

/// Sets our DNS servers in the registry so `ipconfig` and WSL will notice them
/// Fixes #6777
fn set_nameservers_on_interface(dns_config: &[IpAddr]) -> Result<()> {
    let hklm = winreg::RegKey::predef(winreg::enums::HKEY_LOCAL_MACHINE);
    let ipv4_nameservers = itertools::join(dns_config.iter().filter(|addr| addr.is_ipv4()), ";");
    let ipv6_nameservers = itertools::join(dns_config.iter().filter(|addr| addr.is_ipv6()), ";");

    tracing::debug!(ipv4_nameservers);

    let key = hklm.open_subkey_with_flags(
        Path::new(&format!(
            r"SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{{{TUNNEL_UUID}}}"
        )),
        winreg::enums::KEY_WRITE,
    )?;
    key.set_value("NameServer", &ipv4_nameservers)?;

    tracing::debug!(ipv6_nameservers);

    let key = hklm.open_subkey_with_flags(
        Path::new(&format!(
            r"SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\{{{TUNNEL_UUID}}}"
        )),
        winreg::enums::KEY_WRITE,
    )?;
    key.set_value("NameServer", &ipv6_nameservers)?;

    Ok(())
}

/// Sets (or unsets) the search domain on the tunnel interface.
///
/// If `search_domain` is `None`, the search domain is unset.
/// If we cannot open any of the keys, we no-op.
/// Some systems might have IPv4 or IPv6 disabled and we don't want to fail in that case.
fn set_search_domain_on_interface(search_domain: Option<DomainName>) -> Result<()> {
    let hklm = winreg::RegKey::predef(winreg::enums::HKEY_LOCAL_MACHINE);
    let search_list = search_domain.map(|d| d.to_string()).unwrap_or_default(); // Default to empty string in order to "unset" the search domain.

    if let Ok(key) = hklm
        .open_subkey_with_flags(
            Path::new(&format!(
                r"SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{{{TUNNEL_UUID}}}"
            )),
            winreg::enums::KEY_WRITE,
        )
        .context("Failed to open IPv4 tunnel interface registry key")
        .inspect_err(|e| tracing::debug!("{e:#}"))
    {
        key.set_value("SearchList", &search_list)?;
    }

    if let Ok(key) = hklm
        .open_subkey_with_flags(
            Path::new(&format!(
                r"SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\{{{TUNNEL_UUID}}}"
            )),
            winreg::enums::KEY_WRITE,
        )
        .context("Failed to open IPv6 tunnel interface registry key")
        .inspect_err(|e| tracing::debug!("{e:#}"))
    {
        key.set_value("SearchList", &search_list)?;
    }

    Ok(())
}

/// Returns the registry path we can use to set NRPT rules when Group Policy is not in effect.
fn local_nrpt_path() -> &'static Path {
    // Must be backslashes.
    Path::new(r"SYSTEM\CurrentControlSet\Services\Dnscache\Parameters\DnsPolicyConfig")
}

/// Returns the registry path we can use to set NRPT rules when Group Policy is in effect.
fn group_nrpt_path() -> &'static Path {
    // Must be backslashes.
    Path::new(r"SOFTWARE\Policies\Microsoft\Windows NT\DNSClient\DnsPolicyConfig")
}

fn refresh_group_policy() -> Result<()> {
    // SAFETY: No pointers involved, and the docs say nothing about threads.
    unsafe { RefreshPolicyEx(true, RP_FORCE) }.context("Failed to refresh group policy")?;

    Ok(())
}

/// Given the path of a registry key, sets the parameters of an NRPT rule on it.
fn set_nrpt_rule(key: &winreg::RegKey, dns_config_string: &str) -> Result<()> {
    key.set_value("Comment", &FZ_MAGIC)?;
    key.set_value("ConfigOptions", &0x8u32)?;
    key.set_value("DisplayName", &"Firezone SplitDNS")?;
    key.set_value("GenericDNSServers", &dns_config_string)?;
    key.set_value("IPSECCARestriction", &"")?;
    key.set_value("Name", &vec!["."])?;
    key.set_value("Version", &0x2u32)?;
    Ok(())
}
