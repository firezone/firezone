//! TUN I/O through the (experimental) Tundra driver.
//!
//! Tundra shares two rings with us instead of handing out one packet per call. Every
//! packet in them is preceded by a `virtio_net_hdr`, laid out exactly like on a Linux TUN
//! device with `IFF_VNET_HDR`, so we use the same offload code as Linux:
//!
//! - The OS hands us TSO / USO super packets (and packets with partial checksums), which
//!   we split into MTU-sized [`IpPacket`](ip_packet::IpPacket)s using the same code as on Linux.
//! - We coalesce same-flow packets into GSO super packets, which the driver hands to the
//!   Windows network stack as RSC coalesced segments.
//!
//! Like on the other platforms, each direction runs a single-threaded tokio runtime on its
//! worker thread. While packets flow, neither direction makes a system call; a worker only
//! waits (for an event the driver signals) when its ring is empty or full.

use std::mem;
use std::pin::pin;

use anyhow::{Context as _, ErrorExt as _, Result};
use futures::future::{self, Either};
use opentelemetry::KeyValue;
use tun::PacketBatch;
use tun_offload::virtio;
use tun_offload::{ChecksumMode, PacketCoalescer, Protocol};

/// Size of each of the two rings.
///
/// Sized like Wintun's rings (see [`crate`]): 16 MiB bridges a 10 ms gap in servicing a ring at
/// 10 Gbit/s. A full transmit ring makes the driver drop, like a NIC with a full queue.
const RING_CAPACITY: usize = 16 * 1024 * 1024;

pub struct Io {
    name: String,
    workers: tun::Workers,
}

impl Io {
    /// Drives `session` from two worker threads, one per direction.
    pub fn new(
        name: impl Into<String>,
        session: tundra::Session,
        runtime: &tokio::runtime::Handle,
    ) -> Result<Self> {
        let (receiver, sender) = session.into_split();

        let workers = tun::Workers::spawn(
            runtime,
            move |outbound_rx| send(outbound_rx, sender),
            move |inbound_tx| recv(inbound_tx, receiver),
        )
        .context("Failed to start TUN worker threads")?;

        Ok(Self {
            name: name.into(),
            workers,
        })
    }

    pub fn session_config() -> tundra::SessionConfig {
        tundra::SessionConfig {
            transmit_capacity: RING_CAPACITY,
            receive_capacity: RING_CAPACITY,
        }
    }
}

impl tun::Tun for Io {
    fn sender(&self) -> &tun::OutboundTx {
        self.workers.sender()
    }
    fn receiver(&mut self) -> &mut tun::InboundRx {
        self.workers.receiver()
    }
    fn name(&self) -> &str {
        &self.name
    }
}

// Moves packets from Internet towards the user
fn send(mut outbound_rx: tun::OutboundRx, mut sender: tundra::Sender) -> Result<()> {
    let batch_size_histogram = otel_instruments::network_packets_batch_count();
    let dropped_packets_counter = otel_instruments::network_packet_dropped();

    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("Failed to create runtime")?
        .block_on(async move {
            let mut coalescer =
                PacketCoalescer::new([Protocol::Tcp, Protocol::Udp], ChecksumMode::Offloaded);

            while let Some(mut batch) = outbound_rx.recv().await {
                for packet in batch.drain() {
                    #[cfg(debug_assertions)]
                    tracing::trace!(target: "wire::dev::send", ?packet);

                    coalescer.enqueue(packet);
                }

                // Everything pushed into `ring` reaches the driver when it is dropped.
                let mut ring = sender.send_batch();

                for packet in coalescer.drain() {
                    let bytes = packet.packet();
                    let num_segments = packet.num_segments();
                    let vnet_hdr = virtio::header_for(&packet);

                    if ring.push_vnet(&vnet_hdr, bytes).is_err() {
                        // The ring is full: hand over what we have and wait for the driver.
                        drop(ring);

                        if let Err(e) = sender.send_ready(bytes.len()).await {
                            dropped_packets_counter.add(num_segments as u64, &drop_attributes());
                            tracing::debug!("Stopping TUN send worker: {e}");

                            return anyhow::Ok(());
                        }

                        ring = sender.send_batch();
                        if ring.push_vnet(&vnet_hdr, bytes).is_err() {
                            dropped_packets_counter.add(num_segments as u64, &drop_attributes());
                            continue;
                        }
                    }

                    if num_segments > 1 {
                        batch_size_histogram
                            .record(num_segments as u64, &metric_attributes("transmit"));
                    }
                }
            }

            tracing::debug!("Outbound packet sender gone, shutting down task");

            anyhow::Ok(())
        })
}

fn recv(inbound_tx: tun::InboundTx, mut receiver: tundra::Receiver) -> Result<()> {
    let batch_size_histogram = otel_instruments::network_packets_batch_count();

    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("Failed to create runtime")?
        .block_on(async move {
            let mut batch = PacketBatch::default();

            loop {
                // Without the explicit wake-up on `closed`, this task would idle in `recv`
                // until the next packet arrives, keeping the session alive long after the
                // receiver is gone.
                let ring = {
                    let ready = pin!(receiver.recv());
                    let closed = pin!(inbound_tx.closed());

                    match future::select(ready, closed).await {
                        Either::Left((Ok(ring), _)) => ring,
                        Either::Left((Err(e), _)) => {
                            // Expected when the adapter is removed during shutdown.
                            tracing::debug!("Stopping TUN recv worker: {e}");

                            return anyhow::Ok(());
                        }
                        Either::Right(((), _)) => {
                            tracing::debug!("Inbound packet receiver gone, shutting down task");

                            return anyhow::Ok(());
                        }
                    }
                };

                for packet in ring.iter() {
                    let mut segments = match virtio::split(packet.vnet_frame) {
                        Ok(segments) => segments,
                        Err(e) if e.any_is::<ip_packet::Fragmented>() => {
                            tracing::debug!("{e:#}"); // Log on debug to be less noisy.
                            continue;
                        }
                        Err(e) => {
                            tracing::warn!("{e:#}");
                            continue;
                        }
                    };

                    if segments.len() > 1 {
                        batch_size_histogram
                            .record(segments.len() as u64, &metric_attributes("receive"));
                    }

                    for segment in segments.drain(..) {
                        #[cfg(debug_assertions)]
                        tracing::trace!(target: "wire::dev::recv", packet = ?segment);

                        let Err(segment) = batch.try_push(segment) else {
                            continue;
                        };

                        let full = mem::replace(&mut batch, PacketBatch::new(segment));
                        if inbound_tx.send(full).await.is_err() {
                            tracing::debug!("Inbound packet receiver gone, shutting down task");

                            return anyhow::Ok(());
                        }
                    }
                }

                // Hand the ring space back to the driver before we possibly wait for the channel.
                drop(ring);

                if batch.is_empty() {
                    continue;
                }

                if inbound_tx.send(mem::take(&mut batch)).await.is_err() {
                    tracing::debug!("Inbound packet receiver gone, shutting down task");

                    return anyhow::Ok(());
                }
            }
        })
}

fn metric_attributes(direction: &'static str) -> [KeyValue; 2] {
    [
        KeyValue::new("system.device", "tun"),
        KeyValue::new("network.io.direction", direction),
    ]
}

fn drop_attributes() -> [KeyValue; 3] {
    [
        KeyValue::new("system.device", "tun"),
        KeyValue::new("network.io.direction", "transmit"),
        KeyValue::new("error.code", 0),
    ]
}
