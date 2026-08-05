//! Centralised definitions of the OpenTelemetry instruments recorded throughout Firezone's Rust components.
//!
//! An instrument is identified by its name, kind and unit.
//! All call sites recording to the same instrument must use a single, consistent definition.
//! Individual data points are differentiated through attributes instead.

use std::ops::ControlFlow;
use std::time::Duration;

use opentelemetry::KeyValue;
pub use opentelemetry::metrics::{Counter, Gauge, Histogram, Meter, UpDownCounter};

fn meter() -> Meter {
    opentelemetry::global::meter("connlib")
}

/// How many packets we have processed.
pub fn network_packets() -> Counter<u64> {
    meter()
        .u64_counter("connlib.network.packets")
        .with_description("The number of packets processed.")
        .with_unit("{packet}")
        .build()
}

/// How many packets were dropped or discarded.
pub fn network_packet_dropped() -> Counter<u64> {
    meter()
        .u64_counter("connlib.network.dropped")
        .with_description("Count of packets that are dropped or discarded")
        .with_unit("{packet}")
        .build()
}

/// How many IO errors we have encountered.
pub fn network_errors() -> Counter<u64> {
    meter()
        .u64_counter("connlib.network.errors")
        .with_description("Number of IO errors encountered")
        .with_unit("{error}")
        .build()
}

/// How many times a network write was retried after a transient queue-full error.
///
/// Shared across IO paths (UDP sockets, the TUN device); distinguish them via attributes.
pub fn network_retries() -> Histogram<u64> {
    meter()
        .u64_histogram("connlib.network.retries")
        .with_description(
            "How many times a network write was retried (spun) after a transient queue-full error before it succeeded or was dropped.",
        )
        .with_unit("{retry}")
        .with_boundaries((1..=24_u64).map(|i| i as f64).collect())
        .build()
}

/// How many packets we have processed in a single syscall.
///
/// The batch is the syscall: one packet per record means the IO path is not batching at all.
pub fn network_packets_batch_count() -> Histogram<u64> {
    meter()
        .u64_histogram("connlib.network.packets.batch_count")
        .with_description("How many packets we have processed in a single syscall.")
        .with_unit("{packet}")
        // Small batches are by far the most common, so keep unit steps over the range a single
        // GRO list can produce, coarsen through the mid range and fall back to a doubling ladder
        // for the tail. The top is the largest batch our IO paths produce: a Linux `recvmmsg`
        // fills up to 32 buffers, each holding a full GRO list of 64 datagrams.
        .with_boundaries(
            (1..=16_u64)
                .chain((20..=32).step_by(4))
                .chain([48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048])
                .map(|i| i as f64)
                .collect(),
        )
        .build()
}

/// How many connected flow sockets were evicted from the socket pool's cache.
///
/// Only recorded on Apple, the only platform with per-destination flow sockets. Rebinding
/// on a network change discards the whole pool and does not count; this measures cache
/// churn - sockets displaced to make room for another pair.
pub fn flow_socket_evictions() -> Counter<u64> {
    meter()
        .u64_counter("connlib.flow_sockets.evicted")
        .with_description(
            "Number of connected flow sockets evicted from the socket pool's cache to make room for another pair.",
        )
        .with_unit("{socket}")
        .build()
}

/// Number of errors encountered while processing a packet batch.
pub fn tunnel_errors() -> Counter<u64> {
    meter()
        .u64_counter("tunnel.error")
        .with_description("Number of errors encountered while processing a packet batch.")
        .with_unit("{error}")
        .build()
}

/// Number of portal connection hiccups by cause.
pub fn portal_connection_hiccups() -> Counter<u64> {
    meter()
        .u64_counter("portal.connection.hiccup")
        .with_description("Number of portal connection hiccups by cause.")
        .with_unit("{hiccup}")
        .build()
}

/// Number of connections by the network path in use.
pub fn connection_count() -> Gauge<u64> {
    meter()
        .u64_gauge("tunnel.connection.count")
        .with_description("Number of connections by the network path in use.")
        .with_unit("{connection}")
        .build()
}

/// Measures how long connlib takes to recursively resolve a DNS query against an upstream resolver.
pub fn dns_lookup_duration() -> Histogram<f64> {
    meter()
        .f64_histogram("dns.lookup.duration")
        .with_description("Duration of a recursive DNS lookup against an upstream resolver.")
        .with_unit("s")
        .with_boundaries(vec![
            0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0,
        ])
        .build()
}

/// The length of a queue.
pub fn queue_length() -> Gauge<u64> {
    meter()
        .u64_gauge("connlib.queue.length")
        .with_description("The length of a queue.")
        .build()
}

/// The number of buffers allocated in a buffer pool.
pub fn buffer_count() -> UpDownCounter<i64> {
    buffer_count_with(&meter())
}

/// [`buffer_count`] recorded through the given `meter` rather than the global meter.
pub fn buffer_count_with(meter: &Meter) -> UpDownCounter<i64> {
    meter
        .i64_up_down_counter("connlib.buffer.count")
        .with_description("The number of buffers allocated in the pool.")
        .with_unit("{buffers}")
        .build()
}

/// Duration of a single event-loop poll.
pub fn eventloop_poll_duration() -> Histogram<f64> {
    meter()
        .f64_histogram("eventloop.poll.duration")
        .with_description("Duration of a single event-loop poll.")
        .with_unit("s")
        .with_boundaries(vec![
            0.000_005, // 5µs
            0.000_010, // 10µs
            0.000_025, // 25µs
            0.000_050, // 50µs
            0.000_100, // 100µs
            0.000_250, // 250µs
            0.000_500, // 500µs
            0.001_000, // 1ms
            0.002_500, // 2.5ms
            0.005_000, // 5ms
            0.010_000, // 10ms
        ])
        .build()
}

/// Periodically records the length of a queue to the [`queue_length`] gauge until the queue is gone.
pub async fn periodic_queue_length<const N: usize>(
    queue: impl QueueLength,
    attributes: [KeyValue; N],
) {
    periodic_gauge(
        queue_length(),
        |gauge| {
            let len = match queue.queue_length() {
                Some(len) => len,
                None => return ControlFlow::Break(()),
            };

            gauge.record(len, &attributes);

            ControlFlow::Continue(())
        },
        Duration::from_secs(1),
    )
    .await;
}

fn relay_meter() -> Meter {
    opentelemetry::global::meter("relay")
}

/// Up/down counter of currently active relay allocations.
pub fn relay_active_allocations() -> UpDownCounter<i64> {
    relay_meter()
        .i64_up_down_counter("relay.active_allocations")
        .with_description("The number of active allocations")
        .with_unit("{allocation}")
        .build()
}

/// Counter of responses sent by the relay.
pub fn relay_responses() -> Counter<u64> {
    relay_meter()
        .u64_counter("relay.responses")
        .with_description("The number of responses")
        .with_unit("{response}")
        .build()
}

/// Histogram of relayed packet sizes, recorded on both the userspace and the XDP datapath.
///
/// Both call-sites build the instrument from this function so the metric definition
/// (name, unit, buckets) stays identical; tag each measurement with
/// `relay_datapath_userspace` or `relay_datapath_xdp` to tell the two datapaths apart.
pub fn relay_packet_size() -> Histogram<u64> {
    relay_meter()
        .u64_histogram("relay.packet.size")
        .with_description("Size of relayed packets")
        .with_unit("By")
        .with_boundaries(vec![
            100.0, 200.0, 300.0, 400.0, 500.0, 600.0, 700.0, 800.0, 900.0, 1000.0, 1100.0, 1200.0,
            1300.0, 1400.0, 1500.0,
        ])
        .build()
}

/// Histogram of the time the eBPF XDP program spent processing one relayed packet.
pub fn relay_xdp_processing_duration() -> Histogram<u64> {
    relay_meter()
        .u64_histogram("relay.xdp.processing.duration")
        .with_description("Time the eBPF XDP program spent processing one relayed packet")
        .with_unit("ns")
        .with_boundaries(vec![
            50.0, 100.0, 200.0, 500.0, 1_000.0, 2_000.0, 5_000.0, 10_000.0, 20_000.0, 50_000.0,
            100_000.0,
        ])
        .build()
}

/// Invokes `callback` to record to `gauge` every `interval` until it signals completion.
pub async fn periodic_gauge<T>(
    gauge: Gauge<T>,
    callback: impl Fn(&Gauge<T>) -> ControlFlow<(), ()>,
    interval: Duration,
) {
    while callback(&gauge).is_continue() {
        tokio::time::sleep(interval).await;
    }
}

/// Something whose current queue length can be sampled.
pub trait QueueLength: Send + Sync + 'static {
    fn queue_length(&self) -> Option<u64>;
}

impl<T> QueueLength for tokio::sync::mpsc::WeakSender<T>
where
    T: Send + Sync + 'static,
{
    fn queue_length(&self) -> Option<u64> {
        let sender = self.upgrade()?;
        let len = sender.max_capacity() - sender.capacity();

        Some(len as u64)
    }
}
