use futures::SinkExt as _;
use ip_packet::{IpPacket, IpPacketBuf};
use std::os::fd::{FromRawFd, OwnedFd};
use std::task::{Context, Poll};
use std::{io, os::fd::RawFd};
use telemetry::otel;
use tokio::sync::mpsc;
use tokio_util::sync::PollSender;
use tun::ioctl;

const QUEUE_SIZE: usize = 1000;

#[derive(Debug)]
pub struct Tun {
    name: String,
    outbound_tx: PollSender<IpPacket>,
    inbound_rx: mpsc::Receiver<IpPacket>,
    _fd: OwnedFd,
}

impl tun::Tun for Tun {
    fn name(&self) -> &str {
        self.name.as_str()
    }

    fn poll_send_ready(&mut self, cx: &mut Context) -> Poll<io::Result<()>> {
        self.outbound_tx
            .poll_ready_unpin(cx)
            .map_err(io::Error::other)
    }

    fn send(&mut self, packet: IpPacket) -> io::Result<()> {
        self.outbound_tx
            .start_send_unpin(packet)
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
    pub unsafe fn from_fd(fd: RawFd, runtime: &tokio::runtime::Handle) -> io::Result<Self> {
        let name = unsafe { interface_name(fd)? };

        let (inbound_tx, inbound_rx) = mpsc::channel(QUEUE_SIZE);
        let (outbound_tx, outbound_rx) = mpsc::channel(QUEUE_SIZE);

        runtime.spawn(otel::metrics::periodic_system_queue_length(
            outbound_tx.downgrade(),
            [
                otel::attr::queue_item_ip_packet(),
                otel::attr::network_io_direction_transmit(),
            ],
        ));
        runtime.spawn(otel::metrics::periodic_system_queue_length(
            inbound_tx.downgrade(),
            [
                otel::attr::queue_item_ip_packet(),
                otel::attr::network_io_direction_receive(),
            ],
        ));

        std::thread::Builder::new()
            .name("TUN send".to_owned())
            .spawn(move || {
                logging::unwrap_or_warn!(
                    tun::unix::tun_send(fd, outbound_rx, write),
                    "Failed to send to TUN device: {}"
                )
            })
            .map_err(io::Error::other)?;
        std::thread::Builder::new()
            .name("TUN recv".to_owned())
            .spawn(move || {
                logging::unwrap_or_warn!(
                    tun::unix::tun_recv(fd, inbound_tx, read),
                    "Failed to recv from TUN device: {}"
                )
            })
            .map_err(io::Error::other)?;

        Ok(Tun {
            name,
            outbound_tx: PollSender::new(outbound_tx),
            inbound_rx,
            _fd: unsafe { OwnedFd::from_raw_fd(fd) }, // `OwnedFd` will close the fd on drop.
        })
    }
}

/// Retrieves the name of the interface pointed to by the provided file descriptor.
///
/// # Safety
///
/// The file descriptor must be open.
unsafe fn interface_name(fd: RawFd) -> io::Result<String> {
    let mut request = tun::ioctl::Request::<tun::ioctl::GetInterfaceNamePayload>::new();

    unsafe { ioctl::exec(fd, libc::TUNGETIFF as libc::c_ulong, &mut request)? };

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
