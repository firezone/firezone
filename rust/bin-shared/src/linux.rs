use std::{io, net::SocketAddr};

use crate::FIREZONE_MARK;
use nix::sys::socket::{setsockopt, sockopt};
use socket_factory::{TcpSocket, UdpSocket};

#[derive(clap::ValueEnum, Clone, Copy, Debug)]
pub enum DnsControlMethod {
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
    /// Cooperate with `systemd-resolved`
    ///
    /// Suitable for most Ubuntu systems, probably
    SystemdResolved,
}

impl Default for DnsControlMethod {
    fn default() -> Self {
        Self::SystemdResolved
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

#[cfg(test)]
mod tests {
    use super::*;
    use clap::ValueEnum;

    #[test]
    fn cli() {
        assert!(matches!(
            DnsControlMethod::from_str("etc-resolv-conf", false),
            Ok(DnsControlMethod::EtcResolvConf)
        ));
    }
}
