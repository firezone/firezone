//! Linux-specific TUN I/O using segmentation offloads (`IFF_VNET_HDR` + `TUNSETOFFLOAD`).
//!
//! With offloads enabled, the kernel exchanges "super packets" of up to 64 KiB with us:
//!
//! - Reads may return a single TSO / USO packet that we split into MTU-sized [`IpPacket`](ip_packet::IpPacket)s
//!   before handing them to the main thread ([`split`]).
//! - Writes may combine multiple same-flow packets into one GSO write that traverses the
//!   kernel's network stack as a single skb ([`coalesce`]).
//!
//! Each item on the outbound channel is one batch of packets that arrived together
//! upstream; coalescing extends across exactly that batch.

mod checksum;
mod coalesce;
mod split;
mod virtio;

#[cfg(test)]
mod tests;

use anyhow::{Context as _, ErrorExt as _, Result, bail};
use coalesce::{Outgoing, TunGsoQueue};
use opentelemetry::KeyValue;
use std::collections::VecDeque;
use std::io;
use std::mem;
use std::os::fd::{AsRawFd, RawFd};
use tokio::io::Interest;
use tokio::io::unix::AsyncFd;
use virtio::VNET_HDR_LEN;

use crate::{InboundTx, OutboundRx, PacketBatch};

/// Size of the buffer for reading super packets: a `virtio_net_hdr` plus the largest
/// possible IP packet.
const READ_BUFFER_SIZE: usize = VNET_HDR_LEN + u16::MAX as usize;

/// A TUN device file descriptor together with whether segmentation offloads are enabled on it.
///
/// The device always has `IFF_VNET_HDR` set, so reads and writes carry a
/// `virtio_net_hdr` either way; without offloads it is simply always trivial
/// (`VIRTIO_NET_HDR_GSO_NONE`) and writes must not use GSO.
#[derive(Clone)]
pub struct TunFd<T> {
    fd: T,
    offloads: bool,
}

impl<T> TunFd<T> {
    pub fn new(fd: T, offloads: bool) -> Self {
        Self { fd, offloads }
    }
}

/// Sends packets from `outbound_rx` to the TUN device, coalescing where possible.
pub fn tun_send<T>(tun_fd: TunFd<T>, mut outbound_rx: OutboundRx) -> Result<()>
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
            let fd = AsyncFd::with_interest(tun_fd.fd, Interest::WRITABLE)?;

            let mut ready = Vec::new();
            let mut iov = Vec::new();
            // `None` when the kernel does not support GSO writes or rejected one at
            // runtime; packets then pass through 1:1.
            let mut queue = tun_fd.offloads.then(TunGsoQueue::new);

            while let Some(mut batch) = outbound_rx.recv().await {
                for packet in batch.drain() {
                    #[cfg(debug_assertions)]
                    tracing::trace!(target: "wire::dev::send", ?packet);

                    match &mut queue {
                        Some(queue) => queue.enqueue(packet),
                        None => ready.push(Outgoing::from(packet)),
                    }
                }

                if let Some(queue) = &mut queue {
                    ready.extend(queue.drain());
                }

                let gso_failed = write_all(
                    &fd,
                    &mut ready,
                    &mut iov,
                    &batch_size_histogram,
                    &dropped_packets_counter,
                )
                .await;

                if gso_failed {
                    // Some kernel versions carry a bug that makes them reject GSO writes
                    // with `EINVAL`. Stop coalescing for the remainder of the session;
                    // the dropped segments are re-sent by the endpoints.
                    tracing::info!("Kernel rejected GSO write; disabling TUN segmentation offload");

                    queue = None;
                }
            }

            tracing::debug!("Outbound packet sender gone, shutting down task");

            anyhow::Ok(())
        })?;

    Ok(())
}

/// Writes out all ready packets; returns `true` if the kernel rejected a GSO write.
async fn write_all<T>(
    fd: &AsyncFd<T>,
    ready: &mut Vec<Outgoing>,
    iov: &mut Vec<libc::iovec>,
    batch_size_histogram: &opentelemetry::metrics::Histogram<u64>,
    dropped_packets_counter: &opentelemetry::metrics::Counter<u64>,
) -> bool
where
    T: AsRawFd,
{
    let mut gso_failed = false;

    for outgoing in ready.drain(..) {
        let num_segments = outgoing.num_segments();

        match write(fd, &outgoing, iov).await {
            Ok(_) => {
                if num_segments > 1 {
                    batch_size_histogram.record(num_segments as u64, &send_metric_attributes());
                }
            }
            Err(e) if num_segments > 1 && e.raw_os_error() == Some(libc::EINVAL) => {
                dropped_packets_counter.add(num_segments as u64, &drop_attributes(&e));

                gso_failed = true;
            }
            Err(e) => {
                dropped_packets_counter.add(num_segments as u64, &drop_attributes(&e));
                tracing::warn!("Failed to write to TUN FD: {e}");
            }
        }
    }

    gso_failed
}

/// Writes a single [`Outgoing`] to the TUN device, gathering its buffers with `writev`.
async fn write<T>(
    fd: &AsyncFd<T>,
    outgoing: &Outgoing,
    iov: &mut Vec<libc::iovec>,
) -> io::Result<usize>
where
    T: AsRawFd,
{
    iov.clear();
    iov.extend(outgoing.bufs().map(|buf| libc::iovec {
        iov_base: buf.as_ptr() as *mut _,
        iov_len: buf.len(),
    }));

    fd.async_io(Interest::WRITABLE, |fd| {
        // Safety: All iovecs point at valid memory of the given lengths.
        match unsafe { libc::writev(fd.as_raw_fd(), iov.as_ptr(), iov.len() as _) } {
            -1 => Err(io::Error::last_os_error()),
            n => Ok(n as usize),
        }
    })
    .await
}

/// Receives packets from the TUN device, splitting super packets into individual [`IpPacket`](ip_packet::IpPacket)s.
pub fn tun_recv<T>(tun_fd: TunFd<T>, inbound_tx: InboundTx) -> Result<()>
where
    T: AsRawFd,
{
    let batch_size_histogram = otel_instruments::network_packets_batch_count();

    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("Failed to create runtime")?
        .block_on(async move {
            let fd = AsyncFd::with_interest(tun_fd.fd, Interest::READABLE)?;
            let mut buf = vec![0u8; READ_BUFFER_SIZE];
            let mut batch = PacketBatch::default();
            let mut overflow = VecDeque::new();

            loop {
                let mut guard = fd.readable().await?;

                loop {
                    // A full batch spills the rest of its super packet into `overflow`:
                    // hand off the batch and continue the drain with the spilled packets.
                    while !overflow.is_empty() {
                        if inbound_tx.send(mem::take(&mut batch)).await.is_err() {
                            tracing::debug!("Inbound packet receiver gone, shutting down task");

                            return anyhow::Ok(());
                        }

                        while let Some(packet) = overflow.pop_front() {
                            if let Err(packet) = batch.try_push(packet) {
                                overflow.push_front(packet);
                                break;
                            }
                        }
                    }

                    let len = match guard.try_io(|fd| read(fd.get_ref().as_raw_fd(), &mut buf)) {
                        Ok(Ok(0)) => bail!("TUN file descriptor is closed"),
                        Ok(Ok(len)) => len,
                        Ok(Err(e)) => {
                            return Err(anyhow::Error::new(e))
                                .context("Failed to read from TUN FD");
                        }
                        Err(_would_block) => break, // FD is drained; hand off what we have.
                    };

                    match split::split(&buf[..len]) {
                        Ok(mut segments) => {
                            batch_size_histogram
                                .record(segments.len() as u64, &recv_metric_attributes());

                            for packet in segments.drain(..) {
                                #[cfg(debug_assertions)]
                                tracing::trace!(target: "wire::dev::recv", ?packet);

                                if let Err(packet) = batch.try_push(packet) {
                                    overflow.push_back(packet);
                                }
                            }
                        }
                        Err(e) if e.any_is::<ip_packet::Fragmented>() => {
                            tracing::debug!("{e:#}"); // Log on debug to be less noisy.
                        }
                        Err(e) => tracing::warn!("{e:#}"),
                    }
                }

                if batch.is_empty() {
                    continue;
                }

                if inbound_tx.send(mem::take(&mut batch)).await.is_err() {
                    tracing::debug!("Inbound packet receiver gone, shutting down task");

                    return anyhow::Ok(());
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

fn send_metric_attributes() -> [KeyValue; 2] {
    [
        KeyValue::new("system.device", "tun"),
        KeyValue::new("network.io.direction", "transmit"),
    ]
}

fn recv_metric_attributes() -> [KeyValue; 2] {
    [
        KeyValue::new("system.device", "tun"),
        KeyValue::new("network.io.direction", "receive"),
    ]
}

fn drop_attributes(e: &io::Error) -> [KeyValue; 3] {
    [
        KeyValue::new("system.device", "tun"),
        KeyValue::new("network.io.direction", "transmit"),
        KeyValue::new("error.code", e.raw_os_error().unwrap_or_default() as i64),
    ]
}
