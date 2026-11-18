//! The [`SocketPool`] for every non-Apple platform: just the catch-all socket.
//!
//! Connected per-destination sockets only buy us anything on Darwin (see the `apple` module),
//! so everywhere else all traffic uses a single unconnected socket.

use std::{
    net::{IpAddr, SocketAddr},
    sync::Arc,
    task::{Context, Poll},
};

use anyhow::Result;

use crate::DatagramBatch;

use super::{OwnedSocket, poll_recv_ready};

pub(crate) struct SocketPool {
    wildcard: Arc<OwnedSocket>,
    port: u16,
    recv_buf_size: usize,
}

impl SocketPool {
    pub(crate) fn new(wildcard: OwnedSocket, recv_buf_size: usize) -> Self {
        let port = wildcard
            .local_addr()
            .expect("a bound socket to have a local address")
            .port();

        Self {
            wildcard: Arc::new(wildcard),
            port,
            recv_buf_size,
        }
    }

    pub(crate) fn get_send_socket(
        &self,
        _src: Option<IpAddr>,
        _dst: SocketAddr,
        _datagrams: usize,
    ) -> Arc<OwnedSocket> {
        self.wildcard.clone()
    }

    pub(crate) fn poll_recv(&self, cx: &mut Context<'_>) -> Poll<Result<DatagramBatch>> {
        poll_recv_ready(cx, self.wildcard.as_socket(), self.recv_buf_size, self.port)
    }

    pub(crate) fn set_buffer_sizes(&self, send: usize, recv: usize, port: u16) {
        self.wildcard.apply_buffer_sizes(send, recv, port);
    }

    /// There are no flow sockets on non-Apple platforms; all traffic uses the catch-all.
    pub(crate) fn flow_socket_count(&self) -> usize {
        0
    }
}
