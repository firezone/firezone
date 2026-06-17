//! Centralised definitions of the OpenTelemetry instruments recorded throughout the data plane.
//!
//! An instrument is identified by its name, kind and unit.
//! All call sites recording to the same instrument must use a single, consistent definition.
//! Individual data points are differentiated through attributes instead.

use std::ops::ControlFlow;
use std::time::Duration;

use opentelemetry::KeyValue;
use opentelemetry::metrics::{Counter, Gauge, Histogram, Meter, UpDownCounter};

fn meter() -> Meter {
    opentelemetry::global::meter("connlib")
}

/// Meter for OS-reported, host-level metrics in the `system.*` namespace.
fn system_meter() -> Meter {
    opentelemetry::global::meter("system")
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

/// How many batches of packets we have processed in a single syscall.
pub fn network_packets_batch_count() -> Histogram<u64> {
    meter()
        .u64_histogram("connlib.network.packets.batch_count")
        .with_description("How many batches of packets we have processed in a single syscall.")
        .with_unit("{batches}")
        .with_boundaries((1..32_u64).map(|i| i as f64).collect())
        .build()
}

/// Count of packets transferred on a network interface, as reported by the OS.
pub fn system_network_packets() -> Counter<u64> {
    system_meter()
        .u64_counter("system.network.packets")
        .with_description("Count of packets transferred on a network interface.")
        .with_unit("{packet}")
        .build()
}

/// Count of bytes transferred on a network interface, as reported by the OS.
pub fn system_network_io() -> Counter<u64> {
    system_meter()
        .u64_counter("system.network.io")
        .with_description("Count of bytes transferred on a network interface.")
        .with_unit("By")
        .build()
}

/// Count of errors encountered on a network interface, as reported by the OS.
pub fn system_network_errors() -> Counter<u64> {
    system_meter()
        .u64_counter("system.network.errors")
        .with_description("Count of errors encountered on a network interface.")
        .with_unit("{error}")
        .build()
}

/// Count of packets dropped on a network interface, as reported by the OS.
pub fn system_network_dropped() -> Counter<u64> {
    system_meter()
        .u64_counter("system.network.dropped")
        .with_description("Count of packets dropped on a network interface.")
        .with_unit("{packet}")
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
