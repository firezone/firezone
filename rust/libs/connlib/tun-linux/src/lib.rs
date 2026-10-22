#![cfg(target_os = "linux")]
#![cfg_attr(test, allow(clippy::unwrap_used))]

//! Linux-specific TUN I/O using segmentation offloads (`IFF_VNET_HDR` + `TUNSETOFFLOAD`).
//!
//! With offloads enabled, the kernel exchanges "super packets" of up to 64 KiB with us:
//!
//! - Reads may return a single TSO / USO packet that we split into MTU-sized [`IpPacket`](ip_packet::IpPacket)s
//!   before handing them to the main thread ([`tun_offload::virtio::split()`]).
//! - Writes may combine multiple same-flow packets into one GSO write that traverses the
//!   kernel's network stack as a single skb ([`tun_offload::PacketCoalescer`]).
//!
//! Each item on the outbound channel is one batch of packets that arrived together
//! upstream; coalescing extends across exactly that batch.

use anyhow::{Context as _, ErrorExt as _, Result, bail};
use futures::future::{self, Either};
use opentelemetry::KeyValue;
use std::collections::VecDeque;
use std::future::Future;
use std::io;
use std::mem;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::pin::pin;
use std::sync::Arc;
use tokio::io::Interest;
use tokio::io::unix::AsyncFd;
use tun_offload::virtio::{self, VNET_HDR_LEN};

use tun::{InboundTx, OutboundRx, PacketBatch};
use tun_offload::{ChecksumMode, CoalescedPacket, PacketCoalescer, Protocol};

/// Size of the buffer for reading super packets: a `virtio_net_hdr` plus the largest
/// possible IP packet.
const READ_BUFFER_SIZE: usize = VNET_HDR_LEN + u16::MAX as usize;

pub struct Io {
    name: String,
    workers: tun::Workers,
}

impl Io {
    pub fn new(
        name: impl Into<String>,
        fd: TunFd<Arc<OwnedFd>>,
        runtime: &tokio::runtime::Handle,
    ) -> Result<Self> {
        let TunFd { fd, offloads } = fd;
        let send_fd = fd.clone();

        Self::spawn(
            name,
            offloads,
            runtime,
            // SAFETY: Each `AsyncFd` holds a clone of the `OwnedFd`, keeping it open.
            move || {
                unsafe { AsyncFd::register_with_interest(send_fd, Interest::WRITABLE) }
                    .map(Fd)
                    .map_err(io::Error::from)
            },
            // SAFETY: Each `AsyncFd` holds a clone of the `OwnedFd`, keeping it open.
            move || {
                unsafe { AsyncFd::register_with_interest(fd, Interest::READABLE) }
                    .map(Fd)
                    .map_err(io::Error::from)
            },
        )
    }

    /// Starts the worker threads on a device other than a TUN file descriptor, such as an
    /// in-memory one for benchmarks.
    pub fn with_device<D>(
        name: impl Into<String>,
        device: D,
        offloads: bool,
        runtime: &tokio::runtime::Handle,
    ) -> Result<Self>
    where
        D: Device + Clone + Send + 'static,
    {
        let send_device = device.clone();

        Self::spawn(
            name,
            offloads,
            runtime,
            move || Ok(send_device),
            move || Ok(device),
        )
    }

    /// Spawns the workers, each opening its device on its own thread.
    ///
    /// An [`AsyncFd`] must be created on the runtime that polls it, which is the worker's own.
    fn spawn<S, R>(
        name: impl Into<String>,
        offloads: bool,
        runtime: &tokio::runtime::Handle,
        open_send: impl FnOnce() -> io::Result<S> + Send + 'static,
        open_recv: impl FnOnce() -> io::Result<R> + Send + 'static,
    ) -> Result<Self>
    where
        S: Device,
        R: Device,
    {
        let workers = tun::Workers::spawn(
            runtime,
            move |outbound_rx| tun_send(open_send, offloads, outbound_rx),
            move |inbound_tx| tun_recv(open_recv, inbound_tx),
        )?;

        Ok(Self {
            name: name.into(),
            workers,
        })
    }
}

impl tun::Tun for Io {
    fn sender(&mut self) -> &mut tun::OutboundTx {
        self.workers.sender()
    }
    fn receiver(&mut self) -> &mut tun::InboundRx {
        self.workers.receiver()
    }
    fn name(&self) -> &str {
        &self.name
    }
}

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

/// What the worker threads read super packets from and write them to.
///
/// Reads and writes carry a `virtio_net_hdr`, as on a TUN file descriptor with `IFF_VNET_HDR`.
pub trait Device {
    /// Waits until [`Device::try_read`] may succeed.
    fn readable(&self) -> impl Future<Output = io::Result<()>>;

    /// Reads one super packet into `buf`, returning `WouldBlock` once the device is drained.
    fn try_read(&self, buf: &mut [u8]) -> io::Result<usize>;

    /// Writes one super packet with its `virtio_net_hdr`.
    fn write(&self, header: &[u8], packet: &[u8]) -> impl Future<Output = io::Result<usize>>;
}

struct Fd<T: AsRawFd>(AsyncFd<T>);

impl<T> Device for Fd<T>
where
    T: AsRawFd,
{
    async fn readable(&self) -> io::Result<()> {
        // `try_read` clears the readiness once the file descriptor is drained.
        self.0.readable().await?.retain_ready();

        Ok(())
    }

    fn try_read(&self, buf: &mut [u8]) -> io::Result<usize> {
        self.0
            .try_io(Interest::READABLE, |fd| read(fd.as_raw_fd(), buf))
    }

    async fn write(&self, header: &[u8], packet: &[u8]) -> io::Result<usize> {
        let iov = [
            libc::iovec {
                iov_base: header.as_ptr() as *mut _,
                iov_len: header.len(),
            },
            libc::iovec {
                iov_base: packet.as_ptr() as *mut _,
                iov_len: packet.len(),
            },
        ];

        self.0
            .async_io(Interest::WRITABLE, |fd| {
                // Safety: Both iovecs point at valid memory of the given lengths.
                match unsafe { libc::writev(fd.as_raw_fd(), iov.as_ptr(), iov.len() as _) } {
                    -1 => Err(io::Error::last_os_error()),
                    n => Ok(n as usize),
                }
            })
            .await
    }
}

/// Sends packets from `outbound_rx` to the TUN device, coalescing where possible.
fn tun_send<D>(
    open: impl FnOnce() -> io::Result<D>,
    offloads: bool,
    mut outbound_rx: OutboundRx,
) -> Result<()>
where
    D: Device,
{
    let batch_size_histogram = otel_instruments::network_packets_batch_count();
    let dropped_packets_counter = otel_instruments::network_packet_dropped();

    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("Failed to create runtime")?
        .block_on(async move {
            let device = open()?;

            let mut coalescer = if offloads {
                PacketCoalescer::new([Protocol::Tcp, Protocol::Udp], ChecksumMode::Offloaded)
            } else {
                PacketCoalescer::passthrough()
            };

            while let Some(mut batch) = outbound_rx.recv().await {
                for packet in batch.drain() {
                    #[cfg(debug_assertions)]
                    tracing::trace!(target: "wire::dev::send", ?packet);

                    coalescer.enqueue(packet);
                }

                let gso_failed = write_all(
                    &device,
                    &coalescer.take(),
                    &batch_size_histogram,
                    &dropped_packets_counter,
                )
                .await;

                if gso_failed {
                    // Some kernel versions carry a bug that makes them reject GSO writes
                    // with `EINVAL`. Stop coalescing for the remainder of the session;
                    // the dropped segments are re-sent by the endpoints.
                    tracing::info!("Kernel rejected GSO write; disabling TUN segmentation offload");

                    coalescer = PacketCoalescer::passthrough();
                }
            }

            tracing::debug!("Outbound packet sender gone, shutting down task");

            anyhow::Ok(())
        })?;

    Ok(())
}

/// Writes out all ready packets; returns `true` if the kernel rejected a GSO write.
async fn write_all<D>(
    device: &D,
    ready: &[CoalescedPacket],
    batch_size_histogram: &opentelemetry::metrics::Histogram<u64>,
    dropped_packets_counter: &opentelemetry::metrics::Counter<u64>,
) -> bool
where
    D: Device,
{
    let mut gso_failed = false;

    for outgoing in ready {
        let num_segments = outgoing.num_segments();
        let header = virtio::header_for(outgoing);

        match device.write(&header, outgoing.packet()).await {
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

/// Receives packets from the TUN device, splitting super packets into individual [`IpPacket`](ip_packet::IpPacket)s.
fn tun_recv<D>(open: impl FnOnce() -> io::Result<D>, inbound_tx: InboundTx) -> Result<()>
where
    D: Device,
{
    let batch_size_histogram = otel_instruments::network_packets_batch_count();

    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("Failed to create runtime")?
        .block_on(async move {
            let device = open()?;
            let mut buf = vec![0u8; READ_BUFFER_SIZE];
            let mut batch = PacketBatch::default();
            let mut overflow = VecDeque::new();

            loop {
                // Without the explicit wake-up on `closed`, this task would idle in
                // `readable` until the next packet arrives, keeping the TUN fd (and
                // thereby the device) alive long after the receiver is gone.
                let readable = pin!(device.readable());
                let closed = pin!(inbound_tx.closed());

                match future::select(readable, closed).await {
                    Either::Left((readable, _)) => readable?,
                    Either::Right(((), _)) => {
                        tracing::debug!("Inbound packet receiver gone, shutting down task");

                        return anyhow::Ok(());
                    }
                };

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

                    let len = match device.try_read(&mut buf) {
                        Ok(0) => bail!("TUN file descriptor is closed"),
                        Ok(len) => len,
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => break, // Drained; hand off what we have.
                        Err(e) => {
                            return Err(anyhow::Error::new(e))
                                .context("Failed to read from TUN FD");
                        }
                    };

                    match virtio::split(&buf[..len]) {
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
