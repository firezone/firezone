//! Linux-specific TUN I/O using segmentation offloads (`IFF_VNET_HDR` + `TUNSETOFFLOAD`).
//!
//! With offloads enabled, the kernel exchanges "super packets" of up to 64 KiB with us:
//!
//! - Reads may return a single TSO / USO packet that we split into MTU-sized [`IpPacket`]s
//!   before handing them to the main thread ([`split`]).
//! - Writes may combine multiple same-flow packets into one GSO write that traverses the
//!   kernel's network stack as a single skb ([`coalesce`]).
//!
//! Batch boundaries on the write path are signalled by the main thread via
//! [`OutboundItem::Flush`]: it marks the end of each batch of packets it hands us, so
//! coalescing extends across exactly the packets that arrived together upstream.

mod checksum;
mod coalesce;
mod split;
mod virtio;

#[cfg(test)]
mod tests;

use anyhow::{Context as _, ErrorExt as _, Result, bail};
use coalesce::{Outgoing, TunGsoQueue};
use ip_packet::IpPacket;
use opentelemetry::KeyValue;
use std::io;
use std::os::fd::{AsRawFd, RawFd};
use tokio::io::Interest;
use tokio::io::unix::AsyncFd;
use virtio::VNET_HDR_LEN;

use crate::{InboundTx, OutboundItem, OutboundRx};

/// How many packets we at most pull from the outbound channel in one batch.
const MAX_TUN_BATCH: usize = 100;

/// Size of the buffer for reading super packets: a `virtio_net_hdr` plus the largest
/// possible IP packet.
const READ_BUFFER_SIZE: usize = VNET_HDR_LEN + u16::MAX as usize;

/// Sends packets from `outbound_rx` to the TUN device, coalescing where possible.
pub fn tun_send<T>(fd: T, mut outbound_rx: OutboundRx) -> Result<()>
where
    T: AsRawFd,
{
    let batch_size_histogram = otel_instruments::network_packets_batch_count();
    let dropped_packets_counter = otel_instruments::network_packet_dropped();

    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("Failed to create runtime")?
        .block_on(async move {
            let fd = AsyncFd::with_interest(fd, Interest::WRITABLE)?;

            let mut items = Vec::with_capacity(MAX_TUN_BATCH);
            let mut ready = Vec::new();
            // `None` once the kernel rejected a GSO write; packets then pass through 1:1.
            let mut queue = Some(TunGsoQueue::new());

            while outbound_rx.recv_many(&mut items, MAX_TUN_BATCH).await > 0 {
                for item in items.drain(..) {
                    match (item, &mut queue) {
                        (OutboundItem::Packet(packet), Some(queue)) => queue.enqueue(packet),
                        (OutboundItem::Packet(packet), None) => {
                            ready.push(Outgoing::Packet(packet))
                        }
                        (OutboundItem::Flush, Some(queue)) => ready.extend(queue.drain()),
                        (OutboundItem::Flush, None) => {}
                    }
                }

                let gso_failed = write_all(
                    &fd,
                    &mut ready,
                    &batch_size_histogram,
                    &dropped_packets_counter,
                )
                .await;

                if gso_failed {
                    // Some kernels (e.g. those with e269d79c7d35 but not 89add40066f9)
                    // reject GSO writes with `EINVAL`. Stop coalescing for the remainder
                    // of the session; the dropped segments are re-sent by the endpoints.
                    tracing::info!("Kernel rejected GSO write; disabling TUN segmentation offload");

                    queue = None;
                }
            }

            // The channel is closed, i.e. we are shutting down. Packets that are still
            // buffered (their `Flush` never arrived) are dropped; endpoints re-send them.
            anyhow::Ok(())
        })?;

    Ok(())
}

/// Writes out all ready packets; returns `true` if the kernel rejected a GSO write.
async fn write_all<T>(
    fd: &AsyncFd<T>,
    ready: &mut Vec<Outgoing>,
    batch_size_histogram: &opentelemetry::metrics::Histogram<u64>,
    dropped_packets_counter: &opentelemetry::metrics::Counter<u64>,
) -> bool
where
    T: AsRawFd,
{
    let mut gso_failed = false;

    for outgoing in ready.drain(..) {
        match outgoing {
            Outgoing::Packet(packet) => match write_packet(fd, &packet).await {
                Ok(_) => {}
                Err(e) => {
                    dropped_packets_counter.add(1, &drop_attributes(&e));
                    tracing::warn!("Failed to write to TUN FD: {e}");
                }
            },
            Outgoing::Batch { buf, num_segments } => match write_batch(fd, &buf).await {
                Ok(()) => {
                    batch_size_histogram.record(num_segments as u64, &metric_attributes());
                }
                Err(e) if e.raw_os_error() == Some(libc::EINVAL) => {
                    dropped_packets_counter.add(num_segments as u64, &drop_attributes(&e));

                    gso_failed = true;
                }
                Err(e) => {
                    dropped_packets_counter.add(num_segments as u64, &drop_attributes(&e));
                    tracing::warn!("Failed to write GSO packet to TUN FD: {e}");
                }
            },
        }
    }

    gso_failed
}

/// Writes a single packet, prefixed with a zeroed `virtio_net_hdr`.
async fn write_packet<T>(fd: &AsyncFd<T>, packet: &IpPacket) -> io::Result<usize>
where
    T: AsRawFd,
{
    #[cfg(debug_assertions)]
    tracing::trace!(target: "wire::dev::send", ?packet);

    let hdr = [0u8; VNET_HDR_LEN];
    let bytes = packet.packet();

    let iov = [
        libc::iovec {
            iov_base: hdr.as_ptr() as *mut _,
            iov_len: hdr.len(),
        },
        libc::iovec {
            iov_base: bytes.as_ptr() as *mut _,
            iov_len: bytes.len(),
        },
    ];

    fd.async_io(Interest::WRITABLE, |fd| {
        // Safety: Both iovecs point at valid memory of the given lengths.
        match unsafe { libc::writev(fd.as_raw_fd(), iov.as_ptr(), iov.len() as _) } {
            -1 => Err(io::Error::last_os_error()),
            n => Ok(n as usize),
        }
    })
    .await
}

/// Writes a coalesced super packet (including its `virtio_net_hdr`).
async fn write_batch<T>(fd: &AsyncFd<T>, buf: &[u8]) -> io::Result<()>
where
    T: AsRawFd,
{
    fd.async_io(Interest::WRITABLE, |fd| {
        // Safety: The buffer is valid for the given length.
        match unsafe { libc::write(fd.as_raw_fd(), buf.as_ptr() as *const _, buf.len()) } {
            -1 => Err(io::Error::last_os_error()),
            n => Ok(n as usize),
        }
    })
    .await?;

    Ok(())
}

/// Receives packets from the TUN device, splitting super packets into individual [`IpPacket`]s.
pub fn tun_recv<T>(fd: T, inbound_tx: InboundTx) -> Result<()>
where
    T: AsRawFd,
{
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("Failed to create runtime")?
        .block_on(async move {
            let fd = AsyncFd::with_interest(fd, Interest::READABLE)?;
            let mut buf = vec![0u8; READ_BUFFER_SIZE];
            let mut packets = Vec::<IpPacket>::with_capacity(MAX_TUN_BATCH);

            loop {
                let mut guard = fd.readable().await?;

                while packets.len() < MAX_TUN_BATCH {
                    let len = match guard.try_io(|fd| read(fd.get_ref().as_raw_fd(), &mut buf)) {
                        Ok(Ok(0)) => bail!("TUN file descriptor is closed"),
                        Ok(Ok(len)) => len,
                        Ok(Err(e)) => {
                            return Err(anyhow::Error::new(e))
                                .context("Failed to read from TUN FD");
                        }
                        Err(_would_block) => break, // FD is drained; hand off what we have.
                    };

                    if let Err(e) = split::split(&buf[..len], &mut packets) {
                        if e.any_is::<ip_packet::Fragmented>() {
                            tracing::debug!("{e:#}"); // Log on debug to be less noisy.
                        } else {
                            tracing::warn!("{e:#}");
                        }
                    }
                }

                if packets.is_empty() {
                    continue;
                }

                let Ok(permits) = inbound_tx.reserve_many(packets.len()).await else {
                    tracing::debug!("Inbound packet receiver gone, shutting down task");

                    return anyhow::Ok(());
                };

                for (permit, packet) in permits.zip(packets.drain(..)) {
                    #[cfg(debug_assertions)]
                    tracing::trace!(target: "wire::dev::recv", ?packet);

                    permit.send(packet);
                }
            }
        })?;

    Ok(())
}

fn read(fd: RawFd, dst: &mut [u8]) -> io::Result<usize> {
    // Safety: The buffer is valid for the given length.
    match unsafe { libc::read(fd, dst.as_mut_ptr() as _, dst.len()) } {
        -1 => Err(io::Error::last_os_error()),
        n => Ok(n as usize),
    }
}

fn metric_attributes() -> [KeyValue; 2] {
    [
        KeyValue::new("system.device", "tun"),
        KeyValue::new("network.io.direction", "transmit"),
    ]
}

fn drop_attributes(e: &io::Error) -> [KeyValue; 3] {
    [
        KeyValue::new("system.device", "tun"),
        KeyValue::new("network.io.direction", "transmit"),
        KeyValue::new("error.code", e.raw_os_error().unwrap_or_default() as i64),
    ]
}
