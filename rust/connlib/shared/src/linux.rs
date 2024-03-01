//! Linux-specific things like DNS control methods

const FIREZONE_DNS_CONTROL: &str = "FIREZONE_DNS_CONTROL";

pub mod etc_resolv_conf;

#[derive(Clone, Debug)]
pub enum DnsControlMethod {
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

/// Reads FIREZONE_DNS_CONTROL. Returns None if invalid or not set
pub fn get_dns_control_from_env() -> Option<DnsControlMethod> {
    match std::env::var(FIREZONE_DNS_CONTROL).as_deref() {
        Ok("etc-resolv-conf") => Some(DnsControlMethod::EtcResolvConf),
        Ok("network-manager") => Some(DnsControlMethod::NetworkManager),
        Ok("systemd-resolved") => Some(DnsControlMethod::Systemd),
        _ => None,
    }
}
