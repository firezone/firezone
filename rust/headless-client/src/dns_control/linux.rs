use anyhow::{bail, Context as _, Result};
use connlib_shared::tun_device_manager::linux::IFACE_NAME;
use std::{net::IpAddr, str::FromStr};

mod etc_resolv_conf;

const FIREZONE_DNS_CONTROL: &str = "FIREZONE_DNS_CONTROL";

pub fn system_resolvers_for_gui() -> Result<Vec<IpAddr>> {
    get_system_default_resolvers_systemd_resolved()
}

#[derive(Clone, Debug)]
enum DnsControlMethod {
    /// Back up `/etc/resolv.conf` and replace it with our own
    ///
    /// Only suitable for the Alpine CI containers and maybe something like an
    /// embedded system
    EtcResolvConf,
    /// Cooperate with NetworkManager (TODO)
    NetworkManager,
    /// Cooperate with `systemd-resolved`
    ///
    /// Suitable for most Ubuntu systems, probably
    Systemd,
}

pub(crate) struct DnsController {
    dns_control_method: Option<DnsControlMethod>,
}

impl Drop for DnsController {
    fn drop(&mut self) {
        tracing::debug!("Reverting DNS control...");
        if let Some(DnsControlMethod::EtcResolvConf) = self.dns_control_method {
            // TODO: Check that nobody else modified the file while we were running.
            etc_resolv_conf::revert().ok();
        }
    }
}

impl DnsController {
    pub(crate) fn new() -> Self {
        // We'll remove `get_dns_control_from_env` in #5068
        let dns_control_method = get_dns_control_from_env();
        tracing::info!(?dns_control_method);

        Self { dns_control_method }
    }

    /// Set the computer's system-wide DNS servers
    ///
    /// The `mut` in `&mut self` is not needed by Rust's rules, but
    /// it would be bad if this was called from 2 threads at once.
    pub(crate) async fn set_dns(&mut self, dns_config: &[IpAddr]) -> Result<()> {
        match self.dns_control_method {
            None => Ok(()),
            Some(DnsControlMethod::EtcResolvConf) => etc_resolv_conf::configure(dns_config).await,
            Some(DnsControlMethod::NetworkManager) => configure_network_manager(dns_config),
            Some(DnsControlMethod::Systemd) => configure_systemd_resolved(dns_config).await,
        }
        .context("Failed to control DNS")
    }
}

/// Reads FIREZONE_DNS_CONTROL. Returns None if invalid or not set
fn get_dns_control_from_env() -> Option<DnsControlMethod> {
    match std::env::var(FIREZONE_DNS_CONTROL).as_deref() {
        Ok("etc-resolv-conf") => Some(DnsControlMethod::EtcResolvConf),
        Ok("network-manager") => Some(DnsControlMethod::NetworkManager),
        Ok("systemd-resolved") => Some(DnsControlMethod::Systemd),
        _ => None,
    }
}

fn configure_network_manager(_dns_config: &[IpAddr]) -> Result<()> {
    anyhow::bail!("DNS control with NetworkManager is not implemented yet",)
}

async fn configure_systemd_resolved(dns_config: &[IpAddr]) -> Result<()> {
    let status = tokio::process::Command::new("resolvectl")
        .arg("dns")
        .arg(IFACE_NAME)
        .args(dns_config.iter().map(ToString::to_string))
        .status()
        .await
        .context("`resolvectl dns` didn't run")?;
    if !status.success() {
        bail!("`resolvectl dns` returned non-zero");
    }

    let status = tokio::process::Command::new("resolvectl")
        .arg("domain")
        .arg(IFACE_NAME)
        .arg("~.")
        .status()
        .await
        .context("`resolvectl domain` didn't run")?;
    if !status.success() {
        bail!("`resolvectl domain` returned non-zero");
    }

    tracing::info!(?dns_config, "Configured DNS sentinels with `resolvectl`");

    Ok(())
}

pub(crate) fn system_resolvers() -> Result<Vec<IpAddr>> {
    match crate::dns_control::platform::get_dns_control_from_env() {
        None => get_system_default_resolvers_resolv_conf(),
        Some(DnsControlMethod::EtcResolvConf) => get_system_default_resolvers_resolv_conf(),
        Some(DnsControlMethod::NetworkManager) => get_system_default_resolvers_network_manager(),
        Some(DnsControlMethod::Systemd) => get_system_default_resolvers_systemd_resolved(),
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

#[allow(clippy::unnecessary_wraps)]
fn get_system_default_resolvers_network_manager() -> Result<Vec<IpAddr>> {
    tracing::error!("get_system_default_resolvers_network_manager not implemented yet");
    Ok(vec![])
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

// Does nothing on Linux, needed to match the Windows interface
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn deactivate() -> Result<()> {
    Ok(())
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
