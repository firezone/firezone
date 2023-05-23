use anyhow::Result;
use std::net::SocketAddr;
use std::task::{ready, Context, Poll};
use tokio::io::ReadBuf;

const MAX_UDP_SIZE: usize = 65536;

/// A thin wrapper around [`tokio::net::UdpSocket`] that provides a slightly more convenient API.
pub struct UdpSocket {
    inner: tokio::net::UdpSocket,
    recv_buf: [u8; MAX_UDP_SIZE],
}

impl UdpSocket {
    pub async fn bind(addr: impl Into<SocketAddr>) -> Result<Self> {
        Ok(Self {
            inner: tokio::net::UdpSocket::bind(addr.into()).await?,
            recv_buf: [0u8; MAX_UDP_SIZE],
        })
    }

    pub async fn recv(&mut self) -> Result<(&[u8], SocketAddr)> {
        let (length, sender) = self.inner.recv_from(&mut self.recv_buf).await?;

        Ok((&self.recv_buf[..length], sender))
    }

    pub async fn send_to(&mut self, buf: &[u8], target: SocketAddr) -> Result<()> {
        self.inner.send_to(buf, target).await?;

        Ok(())
    }

    pub fn poll_recv(&mut self, cx: &mut Context<'_>) -> Poll<Result<(ReadBuf<'_>, SocketAddr)>> {
        let mut buffer = ReadBuf::new(&mut self.recv_buf);
        let sender = ready!(self.inner.poll_recv_from(cx, &mut buffer))?;

        Poll::Ready(Ok((buffer, sender)))
    }

    pub fn try_send_to(
        &mut self,
        buf: &[u8],
        target: SocketAddr,
        cx: &mut Context<'_>,
    ) -> Poll<Result<()>> {
        ready!(self.inner.poll_send_ready(cx)?);

        let sent_bytes = self.inner.try_send_to(buf, target)?;
        debug_assert_eq!(sent_bytes, buf.len());

        Poll::Ready(Ok(()))
    }
}
