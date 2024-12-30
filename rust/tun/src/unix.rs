use futures::future::Either;
use futures::task::AtomicWaker;
use futures::StreamExt as _;
use ip_packet::{IpPacket, IpPacketBuf};
use std::io;
use std::os::fd::{AsRawFd, RawFd};
use std::pin::pin;
use std::sync::Arc;
use tokio::io::unix::AsyncFd;
use tokio::sync::mpsc;

pub struct TunFd {
    inner: RawFd,
}

impl TunFd {
    /// # Safety
    ///
    /// You must not close this FD yourself.
    /// [`TunFd`] will close it for you.
    pub unsafe fn new(fd: RawFd) -> Self {
        Self { inner: fd }
    }
}

impl AsRawFd for TunFd {
    fn as_raw_fd(&self) -> RawFd {
        self.inner
    }
}

impl Drop for TunFd {
    fn drop(&mut self) {
        // Safety: We are the only ones closing the FD.
        unsafe { libc::close(self.inner) };
    }
}

/// Concurrently reads and writes packets to the given TUN file-descriptor using the provided function pointers for the actual syscall.
///
/// - Every packet received on `outbound_rx` channel will be written to the file descriptor using the `write` syscall.
/// - Every packet read using the `read` syscall will be sent into the `inbound_tx` channel.
/// - Every time we read a packet from `outbound_rx`, we notify `outbound_capacity_waker` about the newly gained capacity.
/// - In case any of the channels close, we exit the task.
/// - IO errors are not fallible.
pub async fn send_recv_tun<T>(
    fd: AsyncFd<T>,
    inbound_tx: mpsc::Sender<IpPacket>,
    mut outbound_rx: flume::r#async::RecvStream<'static, IpPacket>,
    outbound_capacity_waker: Arc<AtomicWaker>,
    read: impl Fn(RawFd, &mut IpPacketBuf) -> io::Result<usize>,
    write: impl Fn(RawFd, &IpPacket) -> io::Result<usize>,
) where
    T: AsRawFd,
{
    loop {
        let next_inbound_packet = pin!(fd.async_io(tokio::io::Interest::READABLE, |fd| {
            let mut ip_packet_buf = IpPacketBuf::new();

            let len = read(fd.as_raw_fd(), &mut ip_packet_buf)?;

            if len == 0 {
                return Ok(None);
            }

            let packet = IpPacket::new(ip_packet_buf, len)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;

            Ok(Some(packet))
        }));
        let next_outbound_packet = pin!(outbound_rx.next());

        match futures::future::select(next_outbound_packet, next_inbound_packet).await {
            Either::Right((Ok(None), _)) => {
                tracing::error!("TUN FD is closed");
                return;
            }
            Either::Right((Ok(Some(packet)), _)) => {
                if inbound_tx.send(packet).await.is_err() {
                    tracing::debug!("Inbound packet receiver gone, shutting down task");

                    return;
                };
            }
            Either::Right((Err(e), _)) => {
                if is_rt_shutdown_err(&e) {
                    tracing::debug!("Runtime is shutting down; exiting TUN read/write task");
                    return;
                }

                tracing::warn!("Failed to read from TUN FD: {e}");
                continue;
            }
            Either::Left((Some(packet), _)) => {
                if let Err(e) = fd
                    .async_io(tokio::io::Interest::WRITABLE, |fd| {
                        write(fd.as_raw_fd(), &packet)
                    })
                    .await
                {
                    tracing::warn!("Failed to write to TUN FD: {e}");
                };

                outbound_capacity_waker.wake(); // We wrote a packet, notify about the new capacity.
            }
            Either::Left((None, _)) => {
                tracing::debug!("Outbound packet sender gone, shutting down task");
                return;
            }
        }
    }
}

/// Checks if the cause of an IO error is due to the tokio runtime shutting down.
///
/// Inspired from <https://github.com/tokio-rs/tokio/blob/9d42b977df149363c11257c77c465efe4ce288ee/tokio/src/process/unix/pidfd_reaper.rs#L98-L109>.
#[allow(deprecated)]
fn is_rt_shutdown_err(err: &io::Error) -> bool {
    let Some(inner) = err.get_ref() else {
        return false;
    };

    // Using `Error::description()` is more efficient than `format!("{inner}")`,
    // so we use it here even if it is deprecated.
    err.kind() == io::ErrorKind::Other
        && inner.source().is_none()
        && inner.description() == "A Tokio 1.x context was found, but it is being shutdown."
}
