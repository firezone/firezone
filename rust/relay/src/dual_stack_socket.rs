use anyhow::{Context, Result};
use local_ip_address::{local_ip, local_ipv6};
use std::net::{IpAddr, SocketAddr, SocketAddrV4, SocketAddrV6};
use std::pin::pin;
use tokio::net::UdpSocket;

const MAX_UDP_SIZE: usize = 65536;

/// A thin abstraction over [`UdpSocket`] that always listens on IPv4 as well as IPv6.
pub struct DualStackSocket {
    ip4_socket: UdpSocket,
    ip6_socket: UdpSocket,

    ip4_addr: SocketAddrV4,
    ip6_addr: SocketAddrV6,

    ip4_receive_buffer: [u8; MAX_UDP_SIZE],
    ip6_receive_buffer: [u8; MAX_UDP_SIZE],
}

impl DualStackSocket {
    pub async fn listen_on(port: u16) -> Result<Self> {
        let ip4_addr = local_ip().context("failed to retrieve local IPv4 address")?;
        let ip6_addr = local_ipv6().context("failed to retrieve local IPv4 address")?;

        let IpAddr::V4(ip4_addr) = ip4_addr else {
            unreachable!() // TODO: Ask upstream if we can change the `local_ip` API
        };
        let IpAddr::V6(ip6_addr) = ip6_addr else {
            unreachable!() // TODO: Ask upstream if we can change the `local_ipv6` API
        };

        let ip4_socket = UdpSocket::bind((ip4_addr, port)).await?;
        let ip6_socket = UdpSocket::bind((ip6_addr, port)).await?;

        Ok(Self {
            ip4_socket,
            ip6_socket,
            ip4_addr: SocketAddrV4::new(ip4_addr, port),
            ip6_addr: SocketAddrV6::new(ip6_addr, port, 0, 0),
            ip4_receive_buffer: [0u8; MAX_UDP_SIZE],
            ip6_receive_buffer: [0u8; MAX_UDP_SIZE],
        })
    }

    pub fn local_addr(&self) -> (SocketAddrV4, SocketAddrV6) {
        (self.ip4_addr, self.ip6_addr)
    }

    pub async fn receive(&mut self) -> Result<(SocketAddr, Vec<u8>)> {
        let ((data, sender), _) = futures::future::try_select(
            pin!(async {
                let (size, sender) = self
                    .ip4_socket
                    .recv_from(&mut self.ip4_receive_buffer)
                    .await?;

                anyhow::Ok((self.ip4_receive_buffer[..size].to_vec(), sender))
            }),
            pin!(async {
                let (size, sender) = self
                    .ip6_socket
                    .recv_from(&mut self.ip6_receive_buffer)
                    .await?;

                anyhow::Ok((self.ip6_receive_buffer[..size].to_vec(), sender))
            }),
        )
        .await
        .map_err(|err| err.factor_first().0)?
        .factor_first();

        Ok((sender, data))
    }

    pub async fn send_to(&mut self, data: &[u8], recipient: SocketAddr) -> Result<()> {
        match recipient {
            SocketAddr::V4(addr) => self.ip4_socket.send_to(data, addr).await?,
            SocketAddr::V6(addr) => self.ip6_socket.send_to(data, addr).await?,
        };

        Ok(())
    }
}
