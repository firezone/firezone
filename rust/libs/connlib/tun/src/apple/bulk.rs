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
use crate::{InboundTx, OutboundRx};

/// How many packets we exchange with the kernel per syscall.
///
/// Mirrors the rationale of `MAX_INBOUND_PACKET_BATCH` in the `tunnel` crate: mobile
/// is memory-constrained, so we keep the batch (and the buffers we pull for it) small
/// there. The desktop value stays below the kernel's `kern.ipc.somaxrecvmsgx` clamp.
const BATCH_SIZE: usize = if cfg!(target_os = "ios") { 25 } else { 100 };

const EMPTY_IOVEC: iovec = iovec {
    iov_base: std::ptr::null_mut(),
    iov_len: 0,
};

/// Sends batches of packets from `outbound_rx` to the TUN device.
pub fn send(
    fd: RawFd,
    syscalls: &'static sys::BatchSyscalls,
    mut outbound_rx: OutboundRx,
) -> Result<()> {
    let batch_count = otel_instruments::network_packets_batch_count();
    let dropped_packets = otel_instruments::network_packet_dropped();

    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("Failed to create runtime")?
        .block_on(async move {
            let fd = AsyncFd::with_interest(fd, Interest::WRITABLE)?;
            let mut batch = Vec::with_capacity(BATCH_SIZE);

            loop {
                if outbound_rx.recv_many(&mut batch, BATCH_SIZE).await == 0 {
                    break; // Channel closed.
                }

                let mut offset = 0;
                while offset < batch.len() {
                    let result = fd
                        .async_io(Interest::WRITABLE, |fd| {
                            // Safety: The file descriptor is valid within this module.
                            unsafe { send_batch(syscalls, fd.as_raw_fd(), &batch[offset..]) }
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
                            let dropped = batch.len() - offset;
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

                batch.clear();
            }

            anyhow::Ok(())
        })?;

    anyhow::Ok(())
}

/// Receives batches of packets from the TUN device into `inbound_tx`.
pub fn recv(fd: RawFd, syscalls: &'static sys::BatchSyscalls, inbound_tx: InboundTx) -> Result<()> {
    let batch_count = otel_instruments::network_packets_batch_count();

    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("Failed to create runtime")?
        .block_on(async move {
            let fd = AsyncFd::with_interest(fd, Interest::READABLE)?;

            loop {
                let mut bufs: Vec<IpPacketBuf> =
                    (0..BATCH_SIZE).map(|_| IpPacketBuf::new()).collect();
                let mut lens = [0usize; BATCH_SIZE];

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

                let Ok(mut permits) = inbound_tx.reserve_many(n).await else {
                    tracing::debug!("Inbound packet receiver gone, shutting down task");
                    break;
                };

                for (buf, len) in bufs.into_iter().zip(lens).take(n) {
                    if len == 0 {
                        continue; // Empty or truncated datagram.
                    }

                    match IpPacket::new(buf, len).context("Failed to parse IP packet") {
                        Ok(packet) => {
                            #[cfg(debug_assertions)]
                            tracing::trace!(target: "wire::dev::recv", ?packet);

                            // We reserved `n` permits and send at most `n`, so this is always `Some`.
                            let Some(permit) = permits.next() else { break };
                            permit.send(packet);
                        }
                        Err(e) if e.any_is::<ip_packet::Fragmented>() => tracing::debug!("{e:#}"),
                        Err(e) => tracing::warn!("{e:#}"),
                    }
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
    let count = batch.len().min(BATCH_SIZE);

    // The first 4 bytes of each datagram carry the address family in network byte order.
    let mut afs = [[0u8; 4]; BATCH_SIZE];
    let mut iovs = [[EMPTY_IOVEC; 2]; BATCH_SIZE];
    let mut msgs = [sys::msghdr_x::ZEROED; BATCH_SIZE];

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
    let count = bufs.len().min(BATCH_SIZE);

    let mut afs = [[0u8; 4]; BATCH_SIZE];
    let mut iovs = [[EMPTY_IOVEC; 2]; BATCH_SIZE];
    let mut msgs = [sys::msghdr_x::ZEROED; BATCH_SIZE];

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
