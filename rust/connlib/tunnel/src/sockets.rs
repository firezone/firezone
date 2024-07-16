use core::slice;
use quinn_udp::{RecvMeta, UdpSockRef, UdpSocketState};
use socket_factory::SocketFactory;
use std::{
    collections::VecDeque,
    io::{self, IoSliceMut},
    net::{Ipv4Addr, Ipv6Addr, SocketAddr},
    task::{ready, Context, Poll},
};
use tokio::{io::Interest, net::UdpSocket};

use crate::Result;

#[derive(Default)]
pub(crate) struct Sockets {
    socket_v4: Option<Socket>,
    socket_v6: Option<Socket>,
}

impl Sockets {
    pub fn rebind(
        &mut self,
        socket_factory: &dyn SocketFactory<tokio::net::UdpSocket>,
    ) -> io::Result<()> {
        let socket_v4 = Socket::ip4(socket_factory);
        let socket_v6 = Socket::ip6(socket_factory);

        match (socket_v4.as_ref(), socket_v6.as_ref()) {
            (Err(e), Ok(_)) => {
                tracing::warn!("Failed to bind IPv4 socket: {e}");
            }
            (Ok(_), Err(e)) => {
                tracing::warn!("Failed to bind IPv6 socket: {e}");
            }
            (Err(e4), Err(e6)) => {
                tracing::error!("Failed to bind IPv4 socket: {e4}");
                tracing::error!("Failed to bind IPv6 socket: {e6}");

                return Err(io::Error::new(
                    io::ErrorKind::AddrNotAvailable,
                    "Unable to bind to interfaces",
                ));
            }
            _ => (),
        }

        self.socket_v4 = socket_v4.ok();
        self.socket_v6 = socket_v6.ok();

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

    pub fn try_send(&mut self, transmit: snownet::Transmit) -> io::Result<()> {
        match transmit.dst {
            SocketAddr::V4(dst) => {
                let socket = self.socket_v4.as_mut().ok_or(io::Error::new(
                    io::ErrorKind::NotConnected,
                    format!("failed send packet to {dst}: no IPv4 socket"),
                ))?;
                socket.send(transmit)?;
            }
            SocketAddr::V6(dst) => {
                let socket = self.socket_v6.as_mut().ok_or(io::Error::new(
                    io::ErrorKind::NotConnected,
                    format!("failed send packet to {dst}: no IPv6 socket"),
                ))?;
                socket.send(transmit)?;
            }
        }

        Ok(())
    }

    pub fn poll_recv_from<'b>(
        &self,
        ip4_buffer: &'b mut [u8],
        ip6_buffer: &'b mut [u8],
        cx: &mut Context<'_>,
    ) -> Poll<io::Result<impl Iterator<Item = Received<'b>>>> {
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
    T4: Iterator<Item = Received<'a>>,
    T6: Iterator<Item = Received<'a>>,
{
    type Item = Received<'a>;

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

pub struct Received<'a> {
    pub local: SocketAddr,
    pub from: SocketAddr,
    pub packet: &'a [u8],
}

struct Socket {
    state: UdpSocketState,
    port: u16,
    socket: UdpSocket,

    buffered_transmits: VecDeque<snownet::Transmit<'static>>,
}

impl Socket {
    fn ip(
        socket_factory: &dyn SocketFactory<tokio::net::UdpSocket>,
        addr: &SocketAddr,
    ) -> Result<Socket> {
        let socket = socket_factory(addr)?;
        let port = socket.local_addr()?.port();

        Ok(Socket {
            state: UdpSocketState::new(UdpSockRef::from(&socket))?,
            port,
            socket,
            buffered_transmits: VecDeque::new(),
        })
    }

    fn ip4(socket_factory: &dyn SocketFactory<tokio::net::UdpSocket>) -> Result<Socket> {
        Self::ip(
            socket_factory,
            &SocketAddr::from((Ipv4Addr::UNSPECIFIED, 0)),
        )
    }

    fn ip6(socket_factory: &dyn SocketFactory<tokio::net::UdpSocket>) -> Result<Socket> {
        Self::ip(
            socket_factory,
            &SocketAddr::from((Ipv6Addr::UNSPECIFIED, 0)),
        )
    }

    #[allow(clippy::type_complexity)]
    fn poll_recv_from<'b>(
        &self,
        buffer: &'b mut [u8],
        cx: &mut Context<'_>,
    ) -> Poll<io::Result<impl Iterator<Item = Received<'b>>>> {
        let Socket {
            port,
            socket,
            state,
            ..
        } = self;

        let bufs = &mut [IoSliceMut::new(buffer)];
        let mut meta = RecvMeta::default();

        loop {
            ready!(socket.poll_recv_ready(cx))?;

            if let Ok(len) = socket.try_io(Interest::READABLE, || {
                state.recv((&socket).into(), bufs, slice::from_mut(&mut meta))
            }) {
                debug_assert_eq!(len, 1);

                if meta.len == 0 {
                    continue;
                }

                let Some(local_ip) = meta.dst_ip else {
                    tracing::warn!("Skipping packet without local IP");
                    continue;
                };

                let local = SocketAddr::new(local_ip, *port);

                let iter = buffer[..meta.len]
                    .chunks(meta.stride)
                    .map(move |packet| Received {
                        local,
                        from: meta.addr,
                        packet,
                    })
                    .inspect(|r| {
                        tracing::trace!(target: "wire::net::recv", src = %r.from, dst = %r.local, num_bytes = %r.packet.len());
                    });

                return Poll::Ready(Ok(iter));
            }
        }
    }

    fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        // Only pop if we successfully send it
        while let Some(transmit) = self.buffered_transmits.front() {
            ready!(self.socket.poll_send_ready(cx))?;

            match self.try_send(transmit) {
                Ok(()) => {
                    self.buffered_transmits.pop_front();
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => continue, // False positive wake-up: Loop to `poll_send_ready` and return `Pending`.
                Err(e) => return Poll::Ready(Err(e)),
            }
        }

        assert!(self.buffered_transmits.is_empty());

        Poll::Ready(Ok(()))
    }

    fn send(&mut self, transmit: snownet::Transmit) -> io::Result<()> {
        tracing::trace!(target: "wire::net::send", src = ?transmit.src, dst = %transmit.dst, num_bytes = %transmit.payload.len());

        debug_assert!(
            self.buffered_transmits.len() < 10_000,
            "We are not flushing the packets for some reason"
        );

        match self.try_send(&transmit) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                tracing::trace!("Buffering packet because socket is busy");

                self.buffered_transmits.push_back(transmit.into_owned());
                Ok(())
            }
            Err(e) => Err(e),
        }
    }

    fn try_send(&self, transmit: &snownet::Transmit) -> io::Result<()> {
        let transmit = quinn_udp::Transmit {
            destination: transmit.dst,
            ecn: None,
            contents: &transmit.payload,
            segment_size: None,
            src_ip: transmit.src.map(|s| s.ip()),
        };

        self.socket.try_io(Interest::WRITABLE, || {
            self.state.send((&self.socket).into(), &transmit)
        })
    }
}
