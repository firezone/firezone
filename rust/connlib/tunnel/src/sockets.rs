use std::{
    io,
    net::SocketAddr,
    task::{ready, Context, Poll, Waker},
};

use futures::FutureExt;
use tokio::{io::ReadBuf, net::UdpSocket};

struct Socket<const N: usize> {
    local: SocketAddr,
    socket: UdpSocket,
    buffer: Box<[u8; N]>,
}

#[derive(Default)]
pub struct UdpSockets<const N: usize> {
    sockets: Vec<Socket<N>>,
    empty_waker: Option<Waker>,
}

impl<const N: usize> UdpSockets<N> {
    pub fn bind(&mut self, addr: impl Into<SocketAddr>) -> io::Result<SocketAddr> {
        let socket = UdpSocket::bind(addr.into())
            .now_or_never()
            .expect("binding to `SocketAddr` is not actually async")?;

        let local = socket.local_addr()?;

        self.sockets.push(Socket {
            local,
            socket,
            buffer: Box::new([0u8; N]),
        });

        if let Some(waker) = self.empty_waker.take() {
            waker.wake();
        }

        Ok(local)
    }

    pub fn unbind(&mut self, addr: SocketAddr) {
        self.sockets.retain(|Socket { local, .. }| *local != addr);
    }

    pub fn try_send_to(
        &mut self,
        local: SocketAddr,
        dest: SocketAddr,
        buf: &[u8],
    ) -> io::Result<usize> {
        let udp_socket = self
            .sockets
            .iter()
            .find_map(
                |Socket {
                     local: sock_local,
                     socket,
                     ..
                 }| (*sock_local == local).then_some(socket),
            )
            .ok_or(io::ErrorKind::NotConnected)?;

        udp_socket.try_send_to(buf, dest)
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

        let Socket {
            local: addr,
            socket,
            buffer,
        } = self.sockets.last_mut().expect("not empty");

        let mut buf = ReadBuf::new(buffer.as_mut());

        let from = match ready!(socket.poll_recv_from(cx, &mut buf)) {
            Ok(from) => from,
            Err(e) => return Poll::Ready((*addr, Err(e))),
        };

        Poll::Ready((*addr, Ok((from, buf))))
    }
}
