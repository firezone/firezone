//! The [`SocketPool`] for every non-Apple platform: just the catch-all socket.
//!
//! Connected per-destination sockets only buy us anything on Darwin (see the `apple` module),
//! so everywhere else all traffic uses a single unconnected socket.

use std::{
    io,
    net::{IpAddr, SocketAddr},
    sync::Arc,
    task::{Context, Poll},
};

use anyhow::Result;
use bufferpool::BufferPool;

use crate::DatagramSegmentIter;

use super::{OwnedSocket, Socket, poll_recv_ready};

pub(crate) struct SocketPool {
    wildcard: Arc<OwnedSocket>,
}

impl SocketPool {
    pub(crate) fn new(wildcard: OwnedSocket) -> Self {
        Self {
            wildcard: Arc::new(wildcard),
        }
    }

    pub(crate) fn get_send_socket(
        &self,
        _src: Option<IpAddr>,
        _dst: SocketAddr,
        _buffer_pool: &BufferPool<Vec<u8>>,
    ) -> Arc<OwnedSocket> {
        self.wildcard.clone()
    }

    pub(crate) fn poll_recv<F>(
        &self,
        cx: &mut Context<'_>,
        mut try_recv: F,
    ) -> Poll<Result<DatagramSegmentIter>>
    where
        F: FnMut(Socket<'_>) -> io::Result<DatagramSegmentIter>,
    {
        poll_recv_ready(cx, self.wildcard.as_socket(), &mut try_recv)
    }

    pub(crate) fn set_buffer_sizes(&self, send: usize, recv: usize, port: u16) {
        self.wildcard.apply_buffer_sizes(send, recv, port);
    }
}
