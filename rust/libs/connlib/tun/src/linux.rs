//! Linux-specific TUN I/O using segmentation offloads (`IFF_VNET_HDR` + `TUNSETOFFLOAD`).
//!
//! With offloads enabled, the kernel exchanges "super packets" of up to 64 KiB with us:
//!
//! - Reads may return a single TSO / USO packet that we split into MTU-sized [`IpPacket`]s
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
use ip_packet::IpPacket;
use opentelemetry::KeyValue;
use std::io;
use std::mem;
use std::os::fd::{AsRawFd, RawFd};
use tokio::io::Interest;
use tokio::io::unix::AsyncFd;
use virtio::VNET_HDR_LEN;

use crate::{InboundTx, MAX_BATCH_SIZE, OutboundRx};

/// Size of the buffer for reading super packets: a `virtio_net_hdr` plus the largest
/// possible IP packet.
const READ_BUFFER_SIZE: usize = VNET_HDR_LEN + u16::MAX as usize;

/// Whether the running kernel supports the segmentation offloads we rely on.
///
/// UDP segmentation offload (`TUN_F_USO4` / `TUN_F_USO6`) requires Linux 6.2.
/// Offloads are all-or-nothing: on older kernels, callers should fall back to
/// per-packet TUN I/O via [`crate::unix`].
pub fn offloads_supported() -> bool {
    match kernel_version() {
        Some((major, minor)) => (major, minor) >= (6, 2),
        None => {
            tracing::warn!("Failed to determine kernel version; disabling TUN offloads");

            false
        }
    }
}

fn kernel_version() -> Option<(u64, u64)> {
    // Safety: An all-zeroes `utsname` is valid.
    let mut utsname = unsafe { std::mem::zeroed::<libc::utsname>() };

    // Safety: `utsname` is a valid struct for the kernel to write into.
    if unsafe { libc::uname(&mut utsname) } != 0 {
        return None;
    }

    // Safety: The kernel null-terminates `release`.
    let release = unsafe { std::ffi::CStr::from_ptr(utsname.release.as_ptr()) };

    parse_kernel_version(release.to_str().ok()?)
}

fn parse_kernel_version(release: &str) -> Option<(u64, u64)> {
    let mut parts = release.split(['.', '-', '+']);

    let major = parts.next()?.parse().ok()?;
    let minor = parts.next()?.parse().ok()?;

    Some((major, minor))
}

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

            let mut ready = Vec::new();
            // `None` once the kernel rejected a GSO write; packets then pass through 1:1.
            let mut queue = Some(TunGsoQueue::new());

            while let Some(batch) = outbound_rx.recv().await {
                for packet in batch {
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
    batch_size_histogram: &opentelemetry::metrics::Histogram<u64>,
    dropped_packets_counter: &opentelemetry::metrics::Counter<u64>,
) -> bool
where
    T: AsRawFd,
{
    let mut gso_failed = false;

    for outgoing in ready.drain(..) {
        let num_segments = outgoing.num_segments();

        match write(fd, &outgoing).await {
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

/// Writes a single [`Outgoing`] (its `virtio_net_hdr` plus packet bytes) to the TUN device.
async fn write<T>(fd: &AsyncFd<T>, outgoing: &Outgoing) -> io::Result<usize>
where
    T: AsRawFd,
{
    let [hdr, packet] = outgoing.bufs();

    let iov = [
        libc::iovec {
            iov_base: hdr.as_ptr() as *mut _,
            iov_len: hdr.len(),
        },
        libc::iovec {
            iov_base: packet.as_ptr() as *mut _,
            iov_len: packet.len(),
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

/// Receives packets from the TUN device, splitting super packets into individual [`IpPacket`]s.
pub fn tun_recv<T>(fd: T, inbound_tx: InboundTx) -> Result<()>
where
    T: AsRawFd,
{
    let batch_size_histogram = otel_instruments::network_packets_batch_count();

    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("Failed to create runtime")?
        .block_on(async move {
            let fd = AsyncFd::with_interest(fd, Interest::READABLE)?;
            let mut buf = vec![0u8; READ_BUFFER_SIZE];
            let mut batch = Vec::<IpPacket>::new();

            loop {
                let mut guard = fd.readable().await?;

                while batch.len() < MAX_BATCH_SIZE {
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
                        Ok(segments) => {
                            batch_size_histogram
                                .record(segments.len() as u64, &recv_metric_attributes());

                            #[cfg(debug_assertions)]
                            for packet in &segments {
                                tracing::trace!(target: "wire::dev::recv", ?packet);
                            }

                            batch.extend(segments);
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

                // The last split may have overshot `MAX_BATCH_SIZE`; hand off in bounded chunks.
                while batch.len() > MAX_BATCH_SIZE {
                    let rest = batch.split_off(MAX_BATCH_SIZE);

                    if inbound_tx
                        .send(mem::replace(&mut batch, rest))
                        .await
                        .is_err()
                    {
                        tracing::debug!("Inbound packet receiver gone, shutting down task");

                        return anyhow::Ok(());
                    }
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

#[cfg(test)]
mod kernel_version_tests {
    use super::*;

    #[test]
    fn parses_common_release_strings() {
        assert_eq!(parse_kernel_version("6.2.0"), Some((6, 2)));
        assert_eq!(parse_kernel_version("6.8.0-45-generic"), Some((6, 8)));
        assert_eq!(parse_kernel_version("5.15.0-1051-aws"), Some((5, 15)));
        assert_eq!(parse_kernel_version("4.19.0-25-amd64"), Some((4, 19)));
        assert_eq!(parse_kernel_version("6.18.5"), Some((6, 18)));
        assert_eq!(parse_kernel_version("garbage"), None);
    }
}
