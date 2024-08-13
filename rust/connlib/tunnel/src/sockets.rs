use socket_factory::{DatagramIn, DatagramOut, SocketFactory, UdpSocket};
use std::{
    io,
    net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
    task::{ready, Context, Poll},
};

const UNSPECIFIED_V4_SOCKET: SocketAddrV4 = SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0);
const UNSPECIFIED_V6_SOCKET: SocketAddrV6 = SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, 0, 0, 0);

#[derive(Default)]
pub(crate) struct Sockets {
    socket_v4: Option<UdpSocket>,
    socket_v6: Option<UdpSocket>,
}

impl Sockets {
    pub fn rebind(
        &mut self,
        socket_factory: &dyn SocketFactory<UdpSocket>,
    ) -> Result<(), NoInterfaces> {
        let socket_v4 = socket_factory(&SocketAddr::V4(UNSPECIFIED_V4_SOCKET));
        let socket_v6 = socket_factory(&SocketAddr::V6(UNSPECIFIED_V6_SOCKET));

        let (socket_v4, socket_v6) = match (socket_v4, socket_v6) {
            (Err(e), Ok(socket)) => {
                tracing::warn!("Failed to bind IPv4 socket: {e}");

                (None, Some(socket))
            }
            (Ok(socket), Err(e)) => {
                tracing::warn!("Failed to bind IPv6 socket: {e}");

                (Some(socket), None)
            }
            (Err(e4), Err(e6)) => {
                return Err(NoInterfaces { e4, e6 });
            }
            (Ok(v4), Ok(v6)) => (Some(v4), Some(v6)),
        };

        self.socket_v4 = socket_v4;
        self.socket_v6 = socket_v6;

        Ok(())
    }

    /// Flushes all buffered data on the sockets.
    ///
    /// Returns `Ready` if the socket is able to accept more data.
    pub fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        if let Some(socket) = self.socket_v4.as_mut() {
            ready!(socket.poll_flush(cx))?;
        }

        if let Some(socket) = self.socket_v6.as_mut() {
            ready!(socket.poll_flush(cx))?;
        }

        Poll::Ready(Ok(()))
    }

    pub fn send(&mut self, datagram: DatagramOut) -> io::Result<()> {
        let socket = match datagram.dst {
            SocketAddr::V4(dst) => self.socket_v4.as_mut().ok_or(io::Error::new(
                io::ErrorKind::NotConnected,
                format!("failed send packet to {dst}: no IPv4 socket"),
            ))?,
            SocketAddr::V6(dst) => self.socket_v6.as_mut().ok_or(io::Error::new(
                io::ErrorKind::NotConnected,
                format!("failed send packet to {dst}: no IPv6 socket"),
            ))?,
        };
        socket.send(datagram)?;

        Ok(())
    }

    pub fn poll_recv_from<'b>(
        &self,
        ip4_buffer: &'b mut [u8],
        ip6_buffer: &'b mut [u8],
        cx: &mut Context<'_>,
    ) -> Poll<io::Result<impl Iterator<Item = DatagramIn<'b>>>> {
        let mut iter = PacketIter::new();

        if let Some(Poll::Ready(packets)) = self
            .socket_v4
            .as_ref()
            .map(|s| s.poll_recv_from(ip4_buffer, cx))
        {
            iter.ip4 = Some(packets?);
        }

        if let Some(Poll::Ready(packets)) = self
            .socket_v6
            .as_ref()
            .map(|s| s.poll_recv_from(ip6_buffer, cx))
        {
            iter.ip6 = Some(packets?);
        }

        if iter.is_empty() {
            return Poll::Pending;
        }

        Poll::Ready(Ok(iter))
    }
}

#[derive(thiserror::Error, Debug)]
#[error("Failed to bind to interfaces: {e4} | {e6}")]
pub struct NoInterfaces {
    e4: io::Error,
    e6: io::Error,
}

struct PacketIter<T4, T6> {
    ip4: Option<T4>,
    ip6: Option<T6>,
}

impl<T4, T6> PacketIter<T4, T6> {
    fn new() -> Self {
        Self {
            ip4: None,
            ip6: None,
        }
    }

    fn is_empty(&self) -> bool {
        self.ip4.is_none() && self.ip6.is_none()
    }
}

impl<'a, T4, T6> Iterator for PacketIter<T4, T6>
where
    T4: Iterator<Item = DatagramIn<'a>>,
    T6: Iterator<Item = DatagramIn<'a>>,
{
    type Item = DatagramIn<'a>;

    fn next(&mut self) -> Option<Self::Item> {
        if let Some(packet) = self.ip4.as_mut().and_then(|i| i.next()) {
            return Some(packet);
        }

        if let Some(packet) = self.ip6.as_mut().and_then(|i| i.next()) {
            return Some(packet);
        }

        None
    }
}
