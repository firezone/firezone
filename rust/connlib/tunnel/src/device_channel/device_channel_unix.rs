use std::io;
use std::sync::Arc;
use std::task::{ready, Context, Poll};

use tokio::io::{unix::AsyncFd, Ready};

use tun::IfaceStream;

use crate::device_channel::Packet;

pub(super) mod tun;

pub(crate) struct DeviceIo(pub(crate) Arc<AsyncFd<IfaceStream>>);

impl DeviceIo {
    pub fn poll_read(&self, out: &mut [u8], cx: &mut Context<'_>) -> Poll<io::Result<usize>> {
        loop {
            let mut guard = ready!(self.0.poll_read_ready(cx))?;

            match guard.get_inner().read(out) {
                Ok(n) => return Poll::Ready(Ok(n)),
                Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
                    // a read has blocked, but a write might still succeed.
                    // clear only the read readiness.
                    guard.clear_ready_matching(Ready::READABLE);
                    continue;
                }
                Err(e) => return Poll::Ready(Err(e)),
            }
        }
    }

    // Note: write is synchronous because it's non-blocking
    // and some losiness is acceptable and increseases performance
    // since we don't block the reading loops.
    pub fn write(&self, packet: Packet<'_>) -> io::Result<usize> {
        match packet {
            Packet::Ipv4(msg) => self.0.get_ref().write4(&msg),
            Packet::Ipv6(msg) => self.0.get_ref().write6(&msg),
        }
    }
}
