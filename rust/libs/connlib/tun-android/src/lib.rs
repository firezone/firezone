#![cfg(target_os = "android")]

mod plain_ip;

use ip_packet::{IpPacket, IpPacketBuf};
use std::os::fd::{AsRawFd as _, OwnedFd};
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
    /// Starts IO on an owned TUN descriptor.
    pub fn new(fd: OwnedFd, runtime: &tokio::runtime::Handle) -> io::Result<Self> {
        let name = interface_name(&fd)?;
        let fd = Arc::new(fd);

        let send_fd = fd.clone();
        let workers = tun::Workers::spawn(
            runtime,
            move |outbound_rx| crate::plain_ip::tun_send(send_fd, outbound_rx, write),
            move |inbound_tx| crate::plain_ip::tun_recv(fd, inbound_tx, read),
        )?;

        Ok(Io { name, workers })
    }
}

/// Retrieves the name of the interface pointed to by the provided file descriptor.
fn interface_name(fd: &OwnedFd) -> io::Result<String> {
    let mut request = ioctl::Request::<ioctl::GetInterfaceNamePayload>::new();

    // SAFETY: The borrowed descriptor remains open during the ioctl.
    unsafe {
        ioctl::exec(
            fd.as_raw_fd(),
            libc::TUNGETIFF as libc::c_ulong,
            &mut request,
        )?
    };

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
