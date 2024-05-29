//! Linux-specific things like DNS control methods

const FIREZONE_DNS_CONTROL: &str = "FIREZONE_DNS_CONTROL";

pub mod etc_resolv_conf;

pub const IPC_SERVICE_DNS_CONTROL: DnsControlMethod = DnsControlMethod::Systemd;

#[derive(Clone, Copy, Debug)]
pub enum DnsControlMethod {
    /// The user explicitly doesn't want DNS Resources
    ///
    /// This is not implemented with `Option<DnsControlMethod>` because `None` might read as
    /// "Use the default control method", not "Don't control DNS".
    DontControl,
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

/// Reads FIREZONE_DNS_CONTROL. Returns Err if invalid or not set
pub fn get_dns_control_from_env() -> anyhow::Result<DnsControlMethod> {
    match std::env::var(FIREZONE_DNS_CONTROL).as_deref() {
        Ok("etc-resolv-conf") => Ok(DnsControlMethod::EtcResolvConf),
        Ok("network-manager") => Ok(DnsControlMethod::NetworkManager),
        Ok("systemd-resolved") => Ok(DnsControlMethod::Systemd),
        _ => anyhow::bail!("No DNS control method provided in env var `{FIREZONE_DNS_CONTROL}`"),
    }
}
