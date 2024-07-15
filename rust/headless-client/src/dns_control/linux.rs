use anyhow::{bail, Context as _, Result};
use firezone_bin_shared::TunDeviceManager;
use std::{net::IpAddr, process::Command, str::FromStr};

mod etc_resolv_conf;

/// Methods to control the system's DNS resolution
#[derive(clap::ValueEnum, Clone, Debug)]
pub(crate) enum Method {
    /// Explicitly disable DNS control.
    ///
    /// We don't use an `Option<Method>` because leaving out the CLI arg should
    /// use Systemd, not disable DNS control.
    Disabled,
    /// Back up `/etc/resolv.conf` and replace it with our own
    ///
    /// Only suitable for the Alpine CI containers and maybe something like an
    /// embedded system
    EtcResolvConf,
    /// Use `systemd-resolved`.
    ///
    /// Suitable for most Ubuntu systems.
    SystemdResolved,
}

impl Default for Method {
    fn default() -> Self {
        Self::SystemdResolved
    }
}

impl Method {
    pub(crate) fn system_resolvers(&self) -> Result<Vec<IpAddr>> {
        match self {
            // Even if DNS control is disabled, we still read `/etc/resolv.conf`
            // to learn the system's resolvers
            Method::Disabled => get_system_default_resolvers_resolv_conf(),
            Method::EtcResolvConf => get_system_default_resolvers_resolv_conf(),
            Method::SystemdResolved => get_system_default_resolvers_systemd_resolved(),
        }
    }
}

pub(crate) struct DnsController {
    pub(crate) method: Method,
}

impl Drop for DnsController {
    fn drop(&mut self) {
        tracing::debug!("Reverting DNS control...");
        if matches!(self.method, Method::EtcResolvConf) {
            // TODO: Check that nobody else modified the file while we were running.
            etc_resolv_conf::revert().ok();
        }
    }
}

impl DnsController {
    /// Set the computer's system-wide DNS servers
    ///
    /// The `mut` in `&mut self` is not needed by Rust's rules, but
    /// it would be bad if this was called from 2 threads at once.
    ///
    /// Cancel safety: Try not to cancel this.
    pub(crate) async fn set_dns(&mut self, dns_config: &[IpAddr]) -> Result<()> {
        match self.method {
            Method::Disabled => Ok(()),
            Method::EtcResolvConf => etc_resolv_conf::configure(dns_config).await,
            Method::SystemdResolved => configure_systemd_resolved(dns_config).await,
        }
        .context("Failed to control DNS")
    }

    /// Flush systemd-resolved's system-wide DNS cache
    ///
    /// Does nothing if we're using other DNS control methods or none at all
    pub(crate) fn flush(&self) -> Result<()> {
        // Flushing is only implemented for systemd-resolved
        match self.method {
            Method::Disabled | Method::EtcResolvConf => (),
            Method::SystemdResolved => {
                tracing::debug!("Flushing systemd-resolved DNS cache...");
                Command::new("resolvectl").arg("flush-caches").status()?;
                tracing::debug!("Flushed DNS.");
            }
        }
        Ok(())
    }
}

/// Sets the system-wide resolvers by configuring `systemd-resolved`
///
/// Cancel safety: Cancelling the future may leave running subprocesses
/// which should eventually exit on their own.
async fn configure_systemd_resolved(dns_config: &[IpAddr]) -> Result<()> {
    let status = tokio::process::Command::new("resolvectl")
        .arg("dns")
        .arg(TunDeviceManager::IFACE_NAME)
        .args(dns_config.iter().map(ToString::to_string))
        .status()
        .await
        .context("`resolvectl dns` didn't run")?;
    if !status.success() {
        bail!("`resolvectl dns` returned non-zero");
    }

    let status = tokio::process::Command::new("resolvectl")
        .arg("domain")
        .arg(TunDeviceManager::IFACE_NAME)
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
