use socket2::{SockAddr, Type};
use std::{
    io,
    net::{IpAddr, SocketAddr},
    task::{ready, Context, Poll, Waker},
};
use tokio::{io::ReadBuf, net::UdpSocket};

use crate::FIREZONE_MARK;

pub struct Socket<const N: usize> {
    local: SocketAddr,
    socket: UdpSocket,
    buffer: Box<[u8; N]>,
}

fn make_socket(addr: impl Into<SocketAddr>) -> io::Result<std::net::UdpSocket> {
    let addr: SockAddr = addr.into().into();
    let socket = socket2::Socket::new(addr.domain(), Type::DGRAM, None)?;
    socket.set_nonblocking(true)?;
    socket.bind(&addr)?;
    socket.set_mark(FIREZONE_MARK)?;

    // Note: for AF_INET sockets IPV6_V6ONLY is not a valid flag
    if addr.is_ipv6() {
        socket.set_only_v6(true)?;
    }

    Ok(socket.into())
}

impl<const N: usize> Socket<N> {
    pub fn bind(addr: impl Into<SocketAddr>) -> io::Result<Socket<N>> {
        let socket = make_socket(addr)?;

        let local = socket.local_addr()?;

        Ok(Socket {
            local,
            socket: tokio::net::UdpSocket::from_std(socket)?,
            buffer: Box::new([0u8; N]),
        })
    }

    pub fn poll_recv_from<'b>(
        &'b mut self,
        cx: &mut Context<'_>,
    ) -> Poll<(SocketAddr, io::Result<(SocketAddr, ReadBuf<'b>)>)> {
        let Socket {
            local: addr,
            socket,
            buffer,
        } = self;

        let mut buf = ReadBuf::new(buffer.as_mut());

        let from = match ready!(socket.poll_recv_from(cx, &mut buf)) {
            Ok(from) => from,
            Err(e) => return Poll::Ready((*addr, Err(e))),
        };

        Poll::Ready((*addr, Ok((from, buf))))
    }

    pub fn try_send_to(&self, dest: SocketAddr, buf: &[u8]) -> io::Result<usize> {
        self.socket.try_send_to(buf, dest)
    }

    pub fn local_addr(&self) -> SocketAddr {
        self.local
    }
}

#[derive(Default)]
pub struct UdpSockets<const N: usize> {
    sockets: Vec<Socket<N>>,
    empty_waker: Option<Waker>,
}

impl<const N: usize> UdpSockets<N> {
    pub fn bind(&mut self, addr: impl Into<SocketAddr>) -> io::Result<SocketAddr> {
        let socket = Socket::bind(addr.into())?;
        let local = socket.local_addr();

        self.sockets.push(socket);

        if let Some(waker) = self.empty_waker.take() {
            waker.wake();
        }

        Ok(local)
    }

    pub fn unbind(&mut self, addr: IpAddr) {
        self.sockets
            .retain(|Socket { local, .. }| local.ip() != addr);
    }

    pub fn try_send_to(
        &mut self,
        local: SocketAddr,
        dest: SocketAddr,
        buf: &[u8],
    ) -> io::Result<usize> {
        self.sockets
            .iter()
            .find(
                |Socket {
                     local: sock_local, ..
                 }| *sock_local == local,
            )
            .ok_or(io::ErrorKind::NotConnected)?
            .try_send_to(dest, buf)
    }

    pub fn poll_recv_from<'b>(
        &'b mut self,
        cx: &mut Context<'_>,
    ) -> Poll<(SocketAddr, io::Result<(SocketAddr, ReadBuf<'b>)>)> {
        if self.sockets.is_empty() {
            self.empty_waker = Some(cx.waker().clone());
            return Poll::Pending;
        }

        let last_index = self.sockets.len() - 1;
        let ready_index = match self.sockets.iter().enumerate().find_map(
            |(i, Socket { socket, .. })| match socket.poll_recv_ready(cx) {
                Poll::Pending => None,
                Poll::Ready(Ok(())) => Some((i, Ok(()))),
                Poll::Ready(Err(e)) => Some((i, Err(e))),
            },
        ) {
            Some((ready_index, Ok(()))) => ready_index,
            Some((ready_index, Err(e))) => {
                return Poll::Ready((self.sockets[ready_index].local, Err(e)))
            }
            None => return Poll::Pending,
        };

        self.sockets.swap(ready_index, last_index); // Swap with last element to ensure "fair" polling.

        self.sockets
            .last_mut()
            .expect("not empty")
            .poll_recv_from(cx)
    }
}
