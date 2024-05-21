//! Linux-specific things

use super::DnsControlMethod;

const FIREZONE_DNS_CONTROL: &str = "FIREZONE_DNS_CONTROL";

pub mod etc_resolv_conf;

/// Reads FIREZONE_DNS_CONTROL. Returns None if invalid or not set
pub fn get_dns_control_from_env() -> Option<DnsControlMethod> {
    match std::env::var(FIREZONE_DNS_CONTROL).as_deref() {
        Ok("etc-resolv-conf") => Some(DnsControlMethod::EtcResolvConf),
        Ok("network-manager") => Some(DnsControlMethod::NetworkManager),
        Ok("systemd-resolved") => Some(DnsControlMethod::Systemd),
        _ => None,
    }
}
