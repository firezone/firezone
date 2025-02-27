use anyhow::{Context, Result};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use tokio::net::{TcpListener, UdpSocket};

pub const PORT: u16 = 5353;

#[derive(Debug, Default)]
pub struct DnsSockets {
    udp_v4: Option<UdpSocket>,
    udp_v6: Option<UdpSocket>,

    tcp_v4: Option<TcpListener>,
    tcp_v6: Option<TcpListener>,
}

impl DnsSockets {
    pub fn rebind_ipv4(&mut self, ipv4: Ipv4Addr) -> Result<()> {
        let udp_socket = make_udp_socket(ipv4)?;
        let tcp_listener = make_tcp_listener(ipv4)?;

        self.udp_v4 = Some(udp_socket);
        self.tcp_v4 = Some(tcp_listener);

        Ok(())
    }

    pub fn rebind_ipv6(&mut self, ipv6: Ipv6Addr) -> Result<()> {
        let udp_socket = make_udp_socket(ipv6)?;
        let tcp_listener = make_tcp_listener(ipv6)?;

        self.udp_v6 = Some(udp_socket);
        self.tcp_v6 = Some(tcp_listener);

        Ok(())
    }
}

fn make_udp_socket(ip: impl Into<IpAddr>) -> Result<UdpSocket> {
    let ip = ip.into();

    let udp_socket = std::net::UdpSocket::bind((ip, PORT)).context("Failed to bind UDP socket")?;
    udp_socket
        .set_nonblocking(true)
        .context("Failed to set socket as non-blocking")?;

    let udp_socket =
        UdpSocket::from_std(udp_socket).context("Failed to convert std to tokio socket")?;

    Ok(udp_socket)
}

fn make_tcp_listener(ip: impl Into<IpAddr>) -> Result<TcpListener> {
    let ip = ip.into();

    let tcp_listener =
        std::net::TcpListener::bind((ip, PORT)).context("Failed to bind TCP listener")?;
    tcp_listener
        .set_nonblocking(true)
        .context("Failed to set listener to non-blocking")?;

    let tcp_listener =
        TcpListener::from_std(tcp_listener).context("Failed to convert std to tokio listener")?;

    Ok(tcp_listener)
}
