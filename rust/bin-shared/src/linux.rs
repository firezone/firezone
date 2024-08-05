use std::{io, net::SocketAddr};

use crate::FIREZONE_MARK;
use nix::sys::socket::{setsockopt, sockopt};
use socket_factory::{TcpSocket, UdpSocket};

const FIREZONE_DNS_CONTROL: &str = "FIREZONE_DNS_CONTROL";

#[derive(Clone, Copy, Debug)]
pub enum DnsControlMethod {
    /// Back up `/etc/resolv.conf` and replace it with our own
    ///
    /// Only suitable for the Alpine CI containers and maybe something like an
    /// embedded system
    EtcResolvConf,
    /// Cooperate with `systemd-resolved`
    ///
    /// Suitable for most Ubuntu systems, probably
    Systemd,
}

impl Default for DnsControlMethod {
    fn default() -> Self {
        Self::Systemd
    }
}

impl DnsControlMethod {
    /// Reads FIREZONE_DNS_CONTROL. Returns None if invalid or not set
    pub fn from_env() -> Option<DnsControlMethod> {
        match std::env::var(FIREZONE_DNS_CONTROL).as_deref() {
            Ok("etc-resolv-conf") => Some(DnsControlMethod::EtcResolvConf),
            Ok("systemd-resolved") => Some(DnsControlMethod::Systemd),
            _ => None,
        }
    }
}

pub fn tcp_socket_factory(socket_addr: &SocketAddr) -> io::Result<TcpSocket> {
    let socket = socket_factory::tcp(socket_addr)?;
    setsockopt(&socket, sockopt::Mark, &FIREZONE_MARK)?;
    Ok(socket)
}

pub fn udp_socket_factory(socket_addr: &SocketAddr) -> io::Result<UdpSocket> {
    let socket = socket_factory::udp(socket_addr)?;
    setsockopt(&socket, sockopt::Mark, &FIREZONE_MARK)?;
    Ok(socket)
}
