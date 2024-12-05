use futures::task::AtomicWaker;
use ip_packet::{IpPacket, IpPacketBuf};
use std::sync::Arc;
use std::task::{Context, Poll};
use std::{io, os::fd::RawFd};
use tokio::io::unix::AsyncFd;
use tokio::sync::mpsc;
use tun::ioctl;
use tun::unix::TunFd;

#[derive(Debug)]
pub struct Tun {
    name: String,
    outbound_tx: flume::Sender<IpPacket>,
    outbound_capacity_waker: Arc<AtomicWaker>,
    inbound_rx: mpsc::Receiver<IpPacket>,
}

impl tun::Tun for Tun {
    fn name(&self) -> &str {
        self.name.as_str()
    }

    fn poll_send_ready(&mut self, cx: &mut Context) -> Poll<io::Result<()>> {
        if self.outbound_tx.is_full() {
            self.outbound_capacity_waker.register(cx.waker());
            return Poll::Pending;
        }

        Poll::Ready(Ok(()))
    }

    fn send(&mut self, packet: IpPacket) -> io::Result<()> {
        self.outbound_tx
            .try_send(packet)
            .map_err(io::Error::other)?;

        Ok(())
    }

    fn poll_recv_many(
        &mut self,
        cx: &mut Context,
        buf: &mut Vec<IpPacket>,
        max: usize,
    ) -> Poll<usize> {
        self.inbound_rx.poll_recv_many(cx, buf, max)
    }
}

impl Tun {
    /// Create a new [`Tun`] from a raw file descriptor.
    ///
    /// # Safety
    ///
    /// - The file descriptor must be open.
    /// - The file descriptor must not get closed by anyone else.
    pub unsafe fn from_fd(fd: RawFd) -> io::Result<Self> {
        let name = interface_name(fd)?;

        // Safety: We are forwarding the safety requirements to the caller.
        let fd = unsafe { TunFd::new(fd) };

        let fd = AsyncFd::new(fd)?;

        let (inbound_tx, inbound_rx) = mpsc::channel(1000);
        let (outbound_tx, outbound_rx) = flume::bounded(1000); // flume is an MPMC channel, therefore perfect for workstealing outbound packets.
        let outbound_capacity_waker = Arc::new(AtomicWaker::new());

        // TODO: Test whether we can set `IFF_MULTI_QUEUE` on Android devices.

        std::thread::Builder::new()
            .name("TUN send/recv".to_owned())
            .spawn({
                let outbound_capacity_waker = outbound_capacity_waker.clone();
                || {
                    tokio::runtime::Builder::new_current_thread()
                        .enable_all()
                        .build()?
                        .block_on(tun::unix::send_recv_tun(
                            fd,
                            inbound_tx,
                            outbound_rx.into_stream(),
                            outbound_capacity_waker,
                            read,
                            write,
                        ));

                    io::Result::Ok(())
                }
            })
            .map_err(io::Error::other)?;

        Ok(Tun {
            name,
            outbound_tx,
            inbound_rx,
            outbound_capacity_waker,
        })
    }
}

/// Retrieves the name of the interface pointed to by the provided file descriptor.
///
/// # Safety
///
/// The file descriptor must be open.
unsafe fn interface_name(fd: RawFd) -> io::Result<String> {
    const TUNGETIFF: libc::c_ulong = 0x800454d2;
    let mut request = tun::ioctl::Request::<tun::ioctl::GetInterfaceNamePayload>::new();

    ioctl::exec(fd, TUNGETIFF, &mut request)?;

    Ok(request.name().to_string())
}

/// Read from the given file descriptor in the buffer.
fn read(fd: RawFd, dst: &mut IpPacketBuf) -> io::Result<usize> {
    let dst = dst.buf();

    // Safety: Within this module, the file descriptor is always valid.
    match unsafe { libc::read(fd, dst.as_mut_ptr() as _, dst.len()) } {
        -1 => Err(io::Error::last_os_error()),
        n => Ok(n as usize),
    }
}

/// Write the packet to the given file descriptor.
fn write(fd: RawFd, packet: &IpPacket) -> io::Result<usize> {
    let buf = packet.packet();

    // Safety: Within this module, the file descriptor is always valid.
    match unsafe { libc::write(fd, buf.as_ptr() as _, buf.len() as _) } {
        -1 => Err(io::Error::last_os_error()),
        n => Ok(n as usize),
    }
}
