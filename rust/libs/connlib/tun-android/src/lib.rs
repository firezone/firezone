#![cfg(target_os = "android")]

mod plain_ip;

use ip_packet::{IpPacket, IpPacketBuf};
use std::os::fd::{AsRawFd as _, FromRawFd, OwnedFd};
use std::sync::Arc;
use std::{io, os::fd::RawFd};
use tun_ioctl as ioctl;

pub struct Io {
    name: String,
    workers: tun::Workers,
}

impl tun::Tun for Io {
    fn sender(&self) -> &tun::OutboundTx {
        self.workers.sender()
    }

    fn receiver(&mut self) -> &mut tun::InboundRx {
        self.workers.receiver()
    }

    fn name(&self) -> &str {
        self.name.as_str()
    }
}

impl Io {
    /// Create a new [`Io`] from a raw file descriptor.
    ///
    /// # Safety
    ///
    /// - The file descriptor must be open.
    /// - The file descriptor must not get closed by anyone else.
    pub unsafe fn from_fd(fd: RawFd, runtime: &tokio::runtime::Handle) -> io::Result<Self> {
        let fd = Arc::new(unsafe { OwnedFd::from_raw_fd(fd) });
        let name = unsafe { interface_name(fd.as_raw_fd())? };

        let (inbound_tx, inbound_rx) = tun::inbound_channel();
        let (outbound_tx, outbound_rx) = tun::outbound_channel();

        runtime.spawn(otel_instruments::periodic_queue_length(
            outbound_tx.downgrade(),
            [
                otel_attributes::queue_item_ip_packet_batch(),
                otel_attributes::network_io_direction_transmit(),
            ],
        ));
        runtime.spawn(otel_instruments::periodic_queue_length(
            inbound_tx.downgrade(),
            [
                otel_attributes::queue_item_ip_packet_batch(),
                otel_attributes::network_io_direction_receive(),
            ],
        ));

        let workers = tun::Workers::spawn(
            outbound_tx,
            inbound_rx,
            {
                let fd = fd.clone();
                move || {
                    logging::unwrap_or_warn!(
                        crate::plain_ip::tun_send(fd, outbound_rx, write),
                        "Failed to send to TUN device: {}"
                    )
                }
            },
            move || {
                logging::unwrap_or_warn!(
                    crate::plain_ip::tun_recv(fd, inbound_tx, read),
                    "Failed to recv from TUN device: {}"
                )
            },
        )?;

        Ok(Io { name, workers })
    }
}

/// Retrieves the name of the interface pointed to by the provided file descriptor.
///
/// # Safety
///
/// The file descriptor must be open.
unsafe fn interface_name(fd: RawFd) -> io::Result<String> {
    let mut request = ioctl::Request::<ioctl::GetInterfaceNamePayload>::new();

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
    #[cfg(debug_assertions)]
    tracing::trace!(target: "wire::dev::send", ?packet);

    let buf = packet.packet();

    // Safety: Within this module, the file descriptor is always valid.
    match unsafe { libc::write(fd, buf.as_ptr() as _, buf.len() as _) } {
        -1 => Err(io::Error::last_os_error()),
        n => Ok(n as usize),
    }
}
