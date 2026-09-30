//! Batched, nonblocking I/O on the NetworkExtension's utun descriptor.

mod bulk;
mod per_packet;
mod sys;

use crate::{MAX_BATCH_SIZE, PacketBatch};
use ip_packet::{IpPacket, IpPacketBuf};
use std::{
    cell::RefCell,
    io,
    os::fd::{AsRawFd as _, OwnedFd},
};
use tokio::io::{Interest, unix::AsyncFd};

pub struct Tun {
    fd: AsyncFd<OwnedFd>,
    buffers: RefCell<Vec<IpPacketBuf>>,
    syscalls: Option<&'static sys::BatchSyscalls>,
}

impl Tun {
    pub fn from_fd(fd: OwnedFd) -> io::Result<Self> {
        Ok(Self {
            fd: AsyncFd::new(fd)?,
            buffers: RefCell::new((0..MAX_BATCH_SIZE).map(|_| IpPacketBuf::new()).collect()),
            syscalls: sys::batch_syscalls(),
        })
    }

    pub async fn read(&self) -> io::Result<PacketBatch> {
        let batch = self
            .fd
            .async_io(Interest::READABLE, |fd| {
                let mut buffers = self.buffers.borrow_mut();
                let mut lengths = [0; MAX_BATCH_SIZE];
                let count = match self.syscalls {
                    // SAFETY: The descriptor and all scatter buffers outlive this syscall.
                    Some(syscalls) => unsafe {
                        bulk::recv_batch(syscalls, fd.as_raw_fd(), &mut buffers, &mut lengths)?
                    },
                    None => {
                        lengths[0] = per_packet::read(fd.as_raw_fd(), &mut buffers[0])?;
                        1
                    }
                };
                if count == 0 {
                    return Err(io::ErrorKind::UnexpectedEof.into());
                }
                let mut batch = PacketBatch::default();
                for (buffer, length) in buffers.iter_mut().zip(lengths).take(count) {
                    if length == 0 {
                        continue;
                    }
                    match IpPacket::new(std::mem::take(buffer), length) {
                        Ok(packet) => {
                            // The syscall fills at most MAX_BATCH_SIZE slots.
                            let _ = batch.try_push(packet);
                        }
                        Err(error) => tracing::trace!(%error, "Discarding invalid TUN packet"),
                    }
                }
                Ok(batch)
            })
            .await?;
        Ok(batch)
    }

    pub async fn write(&self, batch: PacketBatch) -> io::Result<()> {
        let mut offset = 0;
        while offset < batch.len() {
            let result = self
                .fd
                .async_io(Interest::WRITABLE, |fd| {
                    let sent = match self.syscalls {
                        // SAFETY: The descriptor and all packet slices outlive this syscall.
                        Some(syscalls) => unsafe {
                            bulk::send_batch(syscalls, fd.as_raw_fd(), &batch[offset..])?
                        },
                        None => {
                            let packet = &batch[offset];
                            let bytes = per_packet::write(fd.as_raw_fd(), packet)?;
                            if bytes != packet.packet().len() + 4 {
                                return Err(io::ErrorKind::WriteZero.into());
                            }
                            1
                        }
                    };
                    if sent == 0 {
                        return Err(io::ErrorKind::WriteZero.into());
                    }
                    Ok(sent)
                })
                .await;
            match result {
                Ok(sent) => offset += sent,
                Err(error) if error.raw_os_error() == Some(libc::ENOBUFS) => {
                    tracing::trace!(%error, dropped = batch.len() - offset, "TUN queue full");
                    return Ok(());
                }
                Err(error) if error.raw_os_error() == Some(libc::ENOSPC) => {
                    tracing::trace!(%error, dropped = batch.len() - offset, "TUN queue full");
                    return Ok(());
                }
                Err(error) => return Err(error),
            }
        }
        Ok(())
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests;
