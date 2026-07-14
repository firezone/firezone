//! Bulk TUN I/O using Apple's `recvmsg_x` / `sendmsg_x` (see [`super::sys`]).
//!
//! These mirror [`crate::unix::tun_send`] / [`crate::unix::tun_recv`] but exchange a
//! whole batch of packets with the `utun` socket per syscall. The read side is the
//! bigger win: the kernel dequeues the batch under a single lock and only runs its
//! flow-control hand-off once per batch instead of once per packet.

use anyhow::{Context as _, ErrorExt as _, Result, bail};
use ip_packet::{IpPacket, IpPacketBuf, IpVersion};
use libc::{AF_INET, AF_INET6, iovec};
use opentelemetry::KeyValue;
use std::ffi::c_void;
use std::io;
use std::os::fd::{AsRawFd as _, RawFd};
use tokio::io::{Interest, unix::AsyncFd};

use super::sys;
use crate::{MAX_BATCH_SIZE, PacketBatch};

const EMPTY_IOVEC: iovec = iovec {
    iov_base: std::ptr::null_mut(),
    iov_len: 0,
};

/// Sends batches of packets from `outbound_rx` to the TUN device.
pub fn send(
    fd: RawFd,
    syscalls: &'static sys::BatchSyscalls,
    mut outbound_rx: crate::OutboundRx,
) -> Result<()> {
    let batch_count = otel_instruments::network_packets_batch_count();
    let dropped_packets = otel_instruments::network_packet_dropped();

    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("Failed to create runtime")?
        .block_on(async move {
            let fd = AsyncFd::with_interest(fd, Interest::WRITABLE)?;

            while let Some(packets) = outbound_rx.recv().await {
                let mut offset = 0;
                while offset < packets.len() {
                    let result = fd
                        .async_io(Interest::WRITABLE, |fd| {
                            // Safety: The file descriptor is valid within this module.
                            unsafe { send_batch(syscalls, fd.as_raw_fd(), &packets[offset..]) }
                        })
                        .await;

                    match result {
                        // A genuine "can't send now" arrives as `Err(WouldBlock)` (the syscall
                        // returns -1/EWOULDBLOCK), which `async_io` parks on. `Ok(0)` means "sent
                        // nothing without erroring", which shouldn't happen; break rather than spin
                        // on `offset += 0`.
                        Ok(0) => break,
                        Ok(n) => {
                            batch_count.record(
                                n as u64,
                                &[
                                    KeyValue::new("system.device", "tun"),
                                    KeyValue::new("network.io.direction", "transmit"),
                                ],
                            );
                            offset += n;
                        }
                        Err(e) => {
                            // `sendmsg_x` does not report how many datagrams it sent before
                            // failing, so we cannot resubmit the tail without risking a
                            // re-injection of an already-sent prefix. Drop the rest of the batch.
                            let dropped = packets.len() - offset;
                            dropped_packets.add(dropped as u64, &drop_attributes(&e));

                            if e.raw_os_error() == Some(libc::ENOSPC) {
                                // The TUN queue is full; like any congested device, dropping is by design.
                                tracing::debug!(dropped, "TUN queue full while writing: {e}");
                            } else {
                                tracing::warn!(dropped, "Failed to write to TUN FD: {e}");
                            }

                            break;
                        }
                    }
                }
            }

            anyhow::Ok(())
        })?;

    anyhow::Ok(())
}

/// Receives batches of packets from the TUN device into `inbound_tx`.
pub fn recv(
    fd: RawFd,
    syscalls: &'static sys::BatchSyscalls,
    inbound_tx: crate::InboundTx,
) -> Result<()> {
    let batch_count = otel_instruments::network_packets_batch_count();

    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("Failed to create runtime")?
        .block_on(async move {
            let fd = AsyncFd::with_interest(fd, Interest::READABLE)?;

            // Long-lived receive slots: a syscall reading `n` packets consumes `n` buffers,
            // which are re-pulled from the pool in place; the remaining slots are reused
            // as-is, so the cost of preparing a read scales with the packets it returns
            // rather than with `MAX_BATCH_SIZE`.
            let mut bufs: Vec<IpPacketBuf> =
                (0..MAX_BATCH_SIZE).map(|_| IpPacketBuf::new()).collect();
            let mut lens = [0usize; MAX_BATCH_SIZE];

            'recv: loop {
                let n = fd
                    .async_io(Interest::READABLE, |fd| {
                        // Safety: The file descriptor is valid within this module.
                        unsafe { recv_batch(syscalls, fd.as_raw_fd(), &mut bufs, &mut lens) }
                    })
                    .await
                    .context("Failed to read from TUN FD")?;

                // `recvmsg_x` reports "nothing to read" as `-1`/`EWOULDBLOCK` (which `async_io`
                // parks on); `0` datagrams means EOF — the fd has been closed.
                if n == 0 {
                    bail!("TUN file descriptor is closed");
                }

                batch_count.record(
                    n as u64,
                    &[
                        KeyValue::new("system.device", "tun"),
                        KeyValue::new("network.io.direction", "receive"),
                    ],
                );

                let mut batch = PacketBatch::default();

                for (buf, &len) in bufs.iter_mut().zip(&lens).take(n) {
                    if len == 0 {
                        continue; // Empty or truncated datagram; the slot's buffer is reused.
                    }

                    // `Default` refills the slot with a fresh buffer from the pool.
                    let buf = std::mem::take(buf);

                    match IpPacket::new(buf, len).context("Failed to parse IP packet") {
                        Ok(packet) => {
                            #[cfg(debug_assertions)]
                            tracing::trace!(target: "wire::dev::recv", ?packet);

                            let Err(packet) = batch.try_push(packet) else {
                                continue;
                            };

                            // Unreachable in practice: we read at most `MAX_BATCH_SIZE`
                            // packets per syscall, but a full batch is handed off all the same.
                            if inbound_tx
                                .send(std::mem::replace(&mut batch, PacketBatch::new(packet)))
                                .await
                                .is_err()
                            {
                                tracing::debug!("Inbound packet receiver gone, shutting down task");
                                break 'recv;
                            }
                        }
                        Err(e) if e.any_is::<ip_packet::Fragmented>() => tracing::debug!("{e:#}"),
                        Err(e) => tracing::warn!("{e:#}"),
                    }
                }

                if batch.is_empty() {
                    continue;
                }

                if inbound_tx.send(batch).await.is_err() {
                    tracing::debug!("Inbound packet receiver gone, shutting down task");
                    break;
                }
            }

            anyhow::Ok(())
        })?;

    anyhow::Ok(())
}

/// Writes `batch` to `fd` in one `sendmsg_x`, returning the number of packets sent.
///
/// # Safety
///
/// `fd` must be a valid, open `utun` file descriptor.
unsafe fn send_batch(
    syscalls: &sys::BatchSyscalls,
    fd: RawFd,
    batch: &[IpPacket],
) -> io::Result<usize> {
    let count = batch.len().min(MAX_BATCH_SIZE);

    // The first 4 bytes of each datagram carry the address family in network byte order.
    let mut afs = [[0u8; 4]; MAX_BATCH_SIZE];
    let mut iovs = [[EMPTY_IOVEC; 2]; MAX_BATCH_SIZE];
    let mut msgs = [sys::msghdr_x::ZEROED; MAX_BATCH_SIZE];

    for i in 0..count {
        #[cfg(debug_assertions)]
        tracing::trace!(target: "wire::dev::send", packet = ?batch[i]);

        let af = match batch[i].version() {
            IpVersion::V4 => AF_INET,
            IpVersion::V6 => AF_INET6,
        };
        afs[i] = (af as u32).to_be_bytes();

        let payload = batch[i].packet();
        iovs[i] = [
            iovec {
                iov_base: afs[i].as_ptr() as *mut c_void,
                iov_len: afs[i].len(),
            },
            iovec {
                iov_base: payload.as_ptr() as *mut c_void,
                iov_len: payload.len(),
            },
        ];
        msgs[i] = sys::msghdr_x {
            msg_iov: iovs[i].as_mut_ptr(),
            msg_iovlen: 2,
            ..sys::msghdr_x::ZEROED
        };
    }

    // Safety: `msgs[..count]` point at `iovs` / `afs` / packet payloads, all of which
    // outlive this call.
    unsafe { syscalls.sendmsg_x(fd, &msgs[..count]) }
}

/// Reads up to `bufs.len()` packets from `fd` in one `recvmsg_x`.
///
/// Writes each packet's length (with the 4-byte address-family header stripped) into
/// `lens` and returns the number of packets read. A length of `0` marks a slot that
/// should be skipped.
///
/// # Safety
///
/// `fd` must be a valid, open `utun` file descriptor.
unsafe fn recv_batch(
    syscalls: &sys::BatchSyscalls,
    fd: RawFd,
    bufs: &mut [IpPacketBuf],
    lens: &mut [usize],
) -> io::Result<usize> {
    let count = bufs.len().min(MAX_BATCH_SIZE);

    let mut afs = [[0u8; 4]; MAX_BATCH_SIZE];
    let mut iovs = [[EMPTY_IOVEC; 2]; MAX_BATCH_SIZE];
    let mut msgs = [sys::msghdr_x::ZEROED; MAX_BATCH_SIZE];

    for i in 0..count {
        let dst = bufs[i].buf();
        iovs[i] = [
            iovec {
                iov_base: afs[i].as_mut_ptr() as *mut c_void,
                iov_len: afs[i].len(),
            },
            iovec {
                iov_base: dst.as_mut_ptr() as *mut c_void,
                iov_len: dst.len(),
            },
        ];
        msgs[i] = sys::msghdr_x {
            msg_iov: iovs[i].as_mut_ptr(),
            msg_iovlen: 2,
            ..sys::msghdr_x::ZEROED
        };
    }

    // Safety: `msgs[..count]` point at `iovs` / `afs` / the buffers in `bufs`, all of
    // which outlive this call.
    let n = unsafe { syscalls.recvmsg_x(fd, &mut msgs[..count])? };

    for i in 0..n {
        // A truncated datagram cannot happen at our MTU (each buffer holds 4 + `MAX_IP_SIZE`
        // bytes), but guard against it anyway by skipping the slot.
        lens[i] = if msgs[i].msg_flags & libc::MSG_TRUNC != 0 {
            0
        } else {
            // `msg_datalen` includes the 4-byte address-family header.
            msgs[i].msg_datalen.saturating_sub(4)
        };
    }

    Ok(n)
}

/// Attributes for a dropped packet, mirroring `tun::unix`'s so the metric is uniform
/// across platforms.
fn drop_attributes(e: &io::Error) -> [opentelemetry::KeyValue; 3] {
    [
        KeyValue::new("system.device", "tun"),
        KeyValue::new("network.io.direction", "transmit"),
        KeyValue::new("error.code", e.raw_os_error().unwrap_or_default() as i64),
    ]
}
