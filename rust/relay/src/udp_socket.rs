use crate::AddressFamily;
use anyhow::{Context as _, Result};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::task::{ready, Context, Poll};
use tokio::io::ReadBuf;

const MAX_UDP_SIZE: usize = 65536;

/// A thin wrapper around [`tokio::net::UdpSocket`] that provides a slightly more convenient API.
pub struct UdpSocket {
    inner: tokio::net::UdpSocket,
    recv_buf: [u8; MAX_UDP_SIZE],
}

impl UdpSocket {
    pub fn bind(family: AddressFamily, port: u16) -> Result<Self> {
        let std_socket = make_wildcard_socket(family, port)
            .with_context(|| format!("Failed to bind UDP socket for {family}"))?;

        Ok(Self {
            inner: tokio::net::UdpSocket::from_std(std_socket)?,
            recv_buf: [0u8; MAX_UDP_SIZE],
        })
    }

    pub async fn recv(&mut self) -> Result<(&[u8], SocketAddr)> {
        let (length, sender) = self.inner.recv_from(&mut self.recv_buf).await?;

        Ok((&self.recv_buf[..length], sender))
    }

    pub async fn send_to(&mut self, buf: &[u8], target: SocketAddr) -> Result<()> {
        self.inner.send_to(buf, target).await?;

        Ok(())
    }

    pub fn poll_recv(&mut self, cx: &mut Context<'_>) -> Poll<Result<(ReadBuf<'_>, SocketAddr)>> {
        let mut buffer = ReadBuf::new(&mut self.recv_buf);
        let sender = ready!(self.inner.poll_recv_from(cx, &mut buffer))?;

        Poll::Ready(Ok((buffer, sender)))
    }

    pub fn try_send_to(
        &mut self,
        buf: &[u8],
        target: SocketAddr,
        cx: &mut Context<'_>,
    ) -> Poll<Result<()>> {
        ready!(self.inner.poll_send_ready(cx)?);

        let sent_bytes = self.inner.try_send_to(buf, target)?;
        debug_assert_eq!(sent_bytes, buf.len());

        Poll::Ready(Ok(()))
    }
}

/// Creates an [std::net::UdpSocket] via the [socket2] library that is configured for our needs.
///
/// Most importantly, this sets the `IPV6_V6ONLY` flag to ensure we disallow IP4-mapped IPv6 addresses and can bind to IP4 and IP6 addresses on the same port.
fn make_wildcard_socket(family: AddressFamily, port: u16) -> Result<std::net::UdpSocket> {
    use socket2::*;

    let domain = match family {
        AddressFamily::V4 => Domain::IPV4,
        AddressFamily::V6 => Domain::IPV6,
    };
    let address = match family {
        AddressFamily::V4 => IpAddr::from(Ipv4Addr::UNSPECIFIED),
        AddressFamily::V6 => IpAddr::from(Ipv6Addr::UNSPECIFIED),
    };

    let socket = Socket::new(domain, Type::DGRAM, Some(Protocol::UDP))?;
    if family == AddressFamily::V6 {
        socket.set_only_v6(true)?;
    }

    socket.set_nonblocking(true)?;
    socket.bind(&SockAddr::from(SocketAddr::new(address, port)))?;

    Ok(socket.into())
}
