use std::sync::Arc;

use tokio::io::{unix::AsyncFd, Interest};

use super::tun::IfaceStream;

#[derive(Clone)]
pub(crate) struct DeviceIo(Arc<AsyncFd<IfaceStream>>);

impl DeviceIo {
    pub async fn read(&self, out: &mut [u8]) -> std::io::Result<usize> {
        self.0
            .async_io(Interest::READABLE, |inner| inner.read(out))
            .await
    }

    // Note: write is synchronous because it's non-blocking
    // and some losiness is acceptable and increseases performance
    // since we don't block the reading loops.
    pub fn write4(&self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.get_ref().write4(buf)
    }

    pub fn write6(&self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.get_ref().write6(buf)
    }
}

impl DeviceIo {
    pub fn new(stream: Arc<AsyncFd<IfaceStream>>) -> DeviceIo {
        DeviceIo(stream)
    }
}
