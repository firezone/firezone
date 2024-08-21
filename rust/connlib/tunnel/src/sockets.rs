use socket_factory::{DatagramIn, DatagramOut, SocketFactory, UdpSocket};
use std::{
    io,
    net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
    task::{ready, Context, Poll, Waker},
};

const UNSPECIFIED_V4_SOCKET: SocketAddrV4 = SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0);
const UNSPECIFIED_V6_SOCKET: SocketAddrV6 = SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, 0, 0, 0);

#[derive(Default)]
pub(crate) struct Sockets {
    waker: Option<Waker>,

    socket_v4: Option<UdpSocket>,
    socket_v6: Option<UdpSocket>,
}

impl Sockets {
    pub fn rebind(&mut self, socket_factory: &dyn SocketFactory<UdpSocket>) {
        self.socket_v4 = socket_factory(&SocketAddr::V4(UNSPECIFIED_V4_SOCKET))
            .inspect_err(|e| tracing::warn!("Failed to bind IPv4 socket: {e}"))
            .ok();
        self.socket_v6 = socket_factory(&SocketAddr::V6(UNSPECIFIED_V6_SOCKET))
            .inspect_err(|e| tracing::warn!("Failed to bind IPv6 socket: {e}"))
            .ok();

        if let Some(waker) = self.waker.take() {
            waker.wake();
        }
    }

    pub fn poll_has_sockets(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        if self.socket_v4.is_none() && self.socket_v6.is_none() {
            let previous = self.waker.replace(cx.waker().clone());

            if previous.is_none() {
                // If we didn't have a waker yet, it means we just lost our sockets. Let the user know everything will be suspended.
                tracing::error!("No available UDP sockets")
            }

            return Poll::Pending;
        }

        Poll::Ready(())
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

    #[tracing::instrument(level = "debug", skip_all, fields(dst = %datagram.dst))]
    pub fn send(&mut self, datagram: DatagramOut) -> io::Result<()> {
        let dst = datagram.dst;
        let socket = match (dst, self.socket_v4.as_mut(), self.socket_v6.as_mut()) {
            (SocketAddr::V4(_), Some(v4), _) => v4,
            (SocketAddr::V6(_), _, Some(v6)) => v6,
            (SocketAddr::V4(_), None, _) | (SocketAddr::V6(_), _, None) => {
                tracing::trace!("Dropping packet: No socket");
                return Ok(());
            }
        };

        match socket.send(datagram) {
            Ok(()) => Ok(()),
            Err(e) if is_network_unreachable(&e) => {
                match dst {
                    SocketAddr::V4(_) => {
                        tracing::info!("{e}: Discarding IPv4 socket");
                        self.socket_v4 = None;
                    }
                    SocketAddr::V6(_) => {
                        tracing::info!("{e}: Discarding IPv6 socket");

                        self.socket_v6 = None;
                    }
                };

                Ok(())
            }
            Err(e) => Err(e),
        }
    }

    pub fn poll_recv_from<'b>(
        &mut self,
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

/// Hacky way of detecting `NetworkUnreachable` until <https://github.com/rust-lang/rust/issues/86442> stabilizes.
fn is_network_unreachable(e: &io::Error) -> bool {
    format!("{:?}", e.kind()) == "NetworkUnreachable"
}

#[cfg(test)]
mod tests {
    #[cfg(target_os = "linux")]
    #[test]
    fn network_unreachable_works() {
        let err = std::io::Error::from_raw_os_error(libc::ENETUNREACH); // This is what `std` uses internally to map it.

        assert!(super::is_network_unreachable(&err))
    }
}
