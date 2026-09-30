#![cfg(target_os = "linux")]
#![cfg_attr(test, allow(clippy::unwrap_used))]

//! Linux-specific TUN I/O using segmentation offloads (`IFF_VNET_HDR` + `TUNSETOFFLOAD`).
//!
//! With offloads enabled, the kernel exchanges "super packets" of up to 64 KiB with us:
//!
//! - Reads may return a single TSO / USO packet that we split into MTU-sized [`IpPacket`](ip_packet::IpPacket)s
//!   before passing them to the crypto state ([`split`]).
//! - Writes may combine multiple same-flow packets into one GSO write that traverses the
//!   kernel's network stack as a single skb ([`packet_coalescer`]).
//!
//! Coalescing extends across exactly one batch of packets received by the event-loop.

mod split;
mod virtio;

#[cfg(test)]
mod tests;

use anyhow::{ErrorExt as _, Result, bail};
use opentelemetry::KeyValue;
use std::collections::VecDeque;
use std::io;
use std::os::fd::{AsRawFd, RawFd};
use tokio::io::Interest;
use tokio::io::unix::AsyncFd;
use virtio::VNET_HDR_LEN;

use packet_coalescer::{ChecksumMode, CoalescedPacket, PacketCoalescer, Protocol};
use tun::PacketBatch;

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

pub struct Io<T: AsRawFd> {
    fd: std::rc::Rc<AsyncFd<T>>,
    coalescer: std::rc::Rc<std::cell::RefCell<Option<PacketCoalescer>>>,
    reader: futures::stream::LocalBoxStream<'static, Result<PacketBatch>>,
    ready: std::rc::Rc<std::cell::RefCell<Vec<CoalescedPacket>>>,
    batch_histogram: opentelemetry::metrics::Histogram<u64>,
    dropped_packets: opentelemetry::metrics::Counter<u64>,
}

impl<T: AsRawFd + 'static> Io<T> {
    /// Creates TUN IO on the calling packet-processing thread.
    pub fn new(tun_fd: TunFd<T>) -> Result<Self> {
        use futures::StreamExt as _;
        use std::{cell::RefCell, rc::Rc};
        let fd = Rc::new(AsyncFd::new(tun_fd.fd)?);
        let coalescer = Rc::new(RefCell::new(tun_fd.offloads.then(|| {
            PacketCoalescer::new([Protocol::Tcp, Protocol::Udp], ChecksumMode::Offloaded)
        })));
        let read_fd = fd.clone();
        let reader = futures::stream::try_unfold(
            (
                read_fd,
                vec![0; READ_BUFFER_SIZE],
                VecDeque::new(),
                otel_instruments::network_packets_batch_count(),
            ),
            |(fd, mut buffer, mut overflow, histogram)| async move {
                let batch = receive_batch(&fd, &mut buffer, &mut overflow, &histogram).await?;
                anyhow::Ok(Some((batch, (fd, buffer, overflow, histogram))))
            },
        )
        .boxed_local();
        Ok(Self {
            fd,
            coalescer,
            reader,
            ready: Rc::new(RefCell::new(Vec::new())),
            batch_histogram: otel_instruments::network_packets_batch_count(),
            dropped_packets: otel_instruments::network_packet_dropped(),
        })
    }
}

impl<T: AsRawFd + 'static> tun::TunIo for Io<T> {
    fn poll_read(
        &mut self,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Result<PacketBatch>> {
        use futures::StreamExt as _;
        let batch = std::task::ready!(self.reader.poll_next_unpin(cx));
        std::task::Poll::Ready(batch.unwrap_or_else(|| Err(anyhow::anyhow!("TUN reader stopped"))))
    }

    fn send(&self, mut batch: PacketBatch) -> futures::future::LocalBoxFuture<'static, Result<()>> {
        use futures::FutureExt as _;
        let fd = self.fd.clone();
        let coalescer = self.coalescer.clone();
        let ready_storage = self.ready.clone();
        let histogram = self.batch_histogram.clone();
        let dropped = self.dropped_packets.clone();
        async move {
            let mut ready = std::mem::take(&mut *ready_storage.borrow_mut());
            {
                let mut coalescer = coalescer.borrow_mut();
                for packet in batch.drain() {
                    match coalescer.as_mut() {
                        Some(coalescer) => coalescer.enqueue(packet),
                        None => ready.push(CoalescedPacket::from(packet)),
                    }
                }
                if let Some(coalescer) = coalescer.as_mut() {
                    ready.extend(coalescer.drain());
                }
            }
            let rejected = write_all(&fd, &mut ready, &histogram, &dropped).await;
            if rejected {
                tracing::info!("Kernel rejected GSO write; disabling TUN segmentation offload");
                *coalescer.borrow_mut() = None;
            }
            *ready_storage.borrow_mut() = ready;
            Ok(())
        }
        .boxed_local()
    }
}

/// Writes out all ready packets; returns `true` if the kernel rejected a GSO write.
async fn write_all<T>(
    fd: &AsyncFd<T>,
    ready: &mut Vec<CoalescedPacket>,
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

/// Writes a single packet and its `virtio_net_hdr` to the TUN device.
async fn write<T>(fd: &AsyncFd<T>, outgoing: &CoalescedPacket) -> io::Result<usize>
where
    T: AsRawFd,
{
    let hdr = virtio::header_for(outgoing);
    let packet = outgoing.packet();

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

async fn receive_batch<T: AsRawFd>(
    fd: &AsyncFd<T>,
    buffer: &mut [u8],
    overflow: &mut VecDeque<ip_packet::IpPacket>,
    histogram: &opentelemetry::metrics::Histogram<u64>,
) -> Result<PacketBatch> {
    loop {
        let mut batch = PacketBatch::default();
        while let Some(packet) = overflow.pop_front() {
            if let Err(packet) = batch.try_push(packet) {
                overflow.push_front(packet);
                break;
            }
        }
        if !batch.is_empty() {
            return Ok(batch);
        }

        let mut guard = fd.readable().await?;
        for _ in 0..tun::MAX_BATCH_SIZE {
            let len = match guard.try_io(|fd| read(fd.get_ref().as_raw_fd(), buffer)) {
                Ok(Ok(0)) => bail!("TUN file descriptor is closed"),
                Ok(Ok(len)) => len,
                Ok(Err(error)) => return Err(error.into()),
                Err(_) => break,
            };
            match split::split(&buffer[..len]) {
                Ok(segments) => {
                    histogram.record(segments.len() as u64, &recv_metric_attributes());
                    for packet in segments {
                        if let Err(packet) = batch.try_push(packet) {
                            overflow.push_back(packet);
                        }
                    }
                }
                Err(error) if error.any_is::<ip_packet::Fragmented>() => {
                    tracing::debug!("{error:#}")
                }
                Err(error) => tracing::warn!("{error:#}"),
            }
            if batch.len() == tun::MAX_BATCH_SIZE {
                break;
            }
        }
        if !batch.is_empty() {
            return Ok(batch);
        }
        tokio::task::yield_now().await;
    }
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
