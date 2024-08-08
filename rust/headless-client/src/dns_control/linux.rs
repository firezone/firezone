use super::DnsController;
use anyhow::{bail, Context as _, Result};
use connlib_shared::DomainName;
use firezone_bin_shared::{DnsControlMethod, TunDeviceManager};
use itertools::Itertools as _;
use std::{net::IpAddr, process::Command, str::FromStr};

mod etc_resolv_conf;

impl DnsController {
    #[allow(clippy::unnecessary_wraps)]
    pub(crate) fn deactivate(&mut self) -> Result<()> {
        tracing::debug!("Deactivating DNS control...");
        if let DnsControlMethod::EtcResolvConf = self.dns_control_method {
            // TODO: Check that nobody else modified the file while we were running.
            etc_resolv_conf::revert()?;
        }
        Ok(())
    }

    /// Set the computer's system-wide DNS servers
    ///
    /// The `mut` in `&mut self` is not needed by Rust's rules, but
    /// it would be bad if this was called from 2 threads at once.
    ///
    /// Cancel safety: Try not to cancel this.
    pub async fn set_dns(
        &mut self,
        dns_servers: Vec<IpAddr>,
        search_domains: Vec<DomainName>,
    ) -> Result<()> {
        match self.dns_control_method {
            DnsControlMethod::Disabled => Ok(()),
            DnsControlMethod::EtcResolvConf => tokio::task::spawn_blocking(move || {
                etc_resolv_conf::configure(&dns_servers, &search_domains)
            })
            .await
            .context("Failed to `spawn_blocking` DNS control task")?,
            DnsControlMethod::SystemdResolved => {
                configure_systemd_resolved(&dns_servers, &search_domains).await
            }
        }
        .context("Failed to control DNS")
    }

    /// Flush systemd-resolved's system-wide DNS cache
    ///
    /// Does nothing if we're using other DNS control methods or none at all
    pub(crate) fn flush(&self) -> Result<()> {
        // Flushing is only implemented for systemd-resolved
        if matches!(self.dns_control_method, DnsControlMethod::SystemdResolved) {
            tracing::debug!("Flushing systemd-resolved DNS cache...");
            Command::new("resolvectl").arg("flush-caches").status()?;
            tracing::debug!("Flushed DNS.");
        }
        Ok(())
    }
}

/// Sets the system-wide resolvers by configuring `systemd-resolved`
///
/// Cancel safety: Cancelling the future may leave running subprocesses
/// which should eventually exit on their own.
async fn configure_systemd_resolved(
    dns_servers: &[IpAddr],
    search_domains: &[DomainName],
) -> Result<()> {
    let status = tokio::process::Command::new("resolvectl")
        .arg("dns")
        .arg(TunDeviceManager::IFACE_NAME)
        .args(dns_servers.iter().map(ToString::to_string))
        .status()
        .await
        .context("`resolvectl dns` didn't run")?;
    if !status.success() {
        bail!("`resolvectl dns` returned non-zero");
    }

    let status = tokio::process::Command::new("resolvectl")
        .arg("domain")
        .arg(TunDeviceManager::IFACE_NAME)
        .arg(search_domains.iter().join(" "))
        .status()
        .await
        .context("`resolvectl domain` didn't run")?;
    if !status.success() {
        bail!("`resolvectl domain` returned non-zero");
    }

    tracing::info!(?dns_servers, "Configured DNS sentinels with `resolvectl`");

    Ok(())
}

pub(crate) fn system_resolvers(dns_control_method: DnsControlMethod) -> Result<Vec<IpAddr>> {
    match dns_control_method {
        DnsControlMethod::Disabled | DnsControlMethod::EtcResolvConf => {
            get_system_default_resolvers_resolv_conf()
        }
        DnsControlMethod::SystemdResolved => get_system_default_resolvers_systemd_resolved(),
    }
}

fn get_system_default_resolvers_resolv_conf() -> Result<Vec<IpAddr>> {
    // Assume that `configure_resolv_conf` has run in `tun_linux.rs`

    let s = std::fs::read_to_string(etc_resolv_conf::ETC_RESOLV_CONF_BACKUP)
        .or_else(|_| std::fs::read_to_string(etc_resolv_conf::ETC_RESOLV_CONF))
        .context("`resolv.conf` should be readable")?;
    let parsed = resolv_conf::Config::parse(s).context("`resolv.conf` should be parsable")?;

    // Drop the scoping info for IPv6 since connlib doesn't take it
    let nameservers = parsed
        .nameservers
        .into_iter()
        .map(|addr| addr.into())
        .collect();
    Ok(nameservers)
}

/// Returns the DNS servers listed in `resolvectl dns`
fn get_system_default_resolvers_systemd_resolved() -> Result<Vec<IpAddr>> {
    // Unfortunately systemd-resolved does not have a machine-readable
    // text output for this command: <https://github.com/systemd/systemd/issues/29755>
    //
    // The officially supported way is probably to use D-Bus.
    let output = std::process::Command::new("resolvectl")
        .arg("dns")
        .output()
        .context("Failed to run `resolvectl dns` and read output")?;
    if !output.status.success() {
        anyhow::bail!("`resolvectl dns` returned non-zero exit code");
    }
    let output = String::from_utf8(output.stdout).context("`resolvectl` output was not UTF-8")?;
    Ok(parse_resolvectl_output(&output))
}

/// Parses the text output of `resolvectl dns`
///
/// Cannot fail. If the parsing code is wrong, the IP address vec will just be incomplete.
fn parse_resolvectl_output(s: &str) -> Vec<IpAddr> {
    s.lines()
        .flat_map(|line| line.split(' '))
        .filter_map(|word| IpAddr::from_str(word).ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use std::net::IpAddr;

    #[test]
    fn parse_resolvectl_output() {
        let cases = [
            // WSL
            (
                r"Global: 172.24.80.1
Link 2 (eth0):
Link 3 (docker0):
Link 24 (br-fc0b71997a3c):
Link 25 (br-0c129dafb204):
Link 26 (br-e67e83b19dce):
",
                [IpAddr::from([172, 24, 80, 1])],
            ),
            // Ubuntu 20.04
            (
                r"Global:
Link 2 (enp0s3): 192.168.1.1",
                [IpAddr::from([192, 168, 1, 1])],
            ),
        ];

        for (i, (input, expected)) in cases.iter().enumerate() {
            let actual = super::parse_resolvectl_output(input);
            assert_eq!(actual, expected, "Case {i} failed");
        }
    }
}
