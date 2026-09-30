//! The [`SocketPool`] for every non-Apple platform: just the catch-all socket.
//!
//! Connected per-destination sockets only buy us anything on Darwin (see the `apple` module),
//! so everywhere else all traffic uses a single unconnected socket.

use std::{
    io,
    net::{IpAddr, SocketAddr},
    task::{Context, Poll},
};

use anyhow::Result;
#[cfg(target_os = "linux")]
use std::rc::Rc as Shared;
#[cfg(not(target_os = "linux"))]
use std::sync::Arc as Shared;

use crate::DatagramBatch;

use super::{OwnedSocket, Socket, poll_recv_ready};

pub(crate) struct SocketPool {
    wildcard: Shared<OwnedSocket>,
}

impl SocketPool {
    pub(crate) fn new(wildcard: OwnedSocket) -> Self {
        Self {
            wildcard: Shared::new(wildcard),
        }
    }

    pub(crate) fn get_send_socket(
        &self,
        _src: Option<IpAddr>,
        _dst: SocketAddr,
        _datagrams: usize,
        _recv_buffers: &crate::RecvBuffers,
    ) -> Shared<OwnedSocket> {
        self.wildcard.clone()
    }

    pub(crate) fn poll_recv<F>(
        &self,
        cx: &mut Context<'_>,
        mut try_recv: F,
    ) -> Poll<Result<DatagramBatch>>
    where
        F: FnMut(Socket<'_>) -> io::Result<DatagramBatch>,
    {
        poll_recv_ready(cx, self.wildcard.as_socket(), &mut try_recv)
    }

    pub(crate) fn set_buffer_sizes(&self, send: usize, recv: usize, port: u16) {
        self.wildcard.apply_buffer_sizes(send, recv, port);
    }

    /// There are no flow sockets on non-Apple platforms; all traffic uses the catch-all.
    pub(crate) fn flow_socket_count(&self) -> usize {
        0
    }
}
