//! Tracks how long a packet spends in each stage of connlib's data path, in both
//! directions.
//!
//! As a packet travels through connlib it is carried by a series of pool buffers. On the
//! outbound path: the buffer read from the TUN device, the buffer it is encrypted into,
//! and finally the GSO batch buffer it is coalesced into before being sent. On the
//! inbound path the decrypted packet's buffer carries it from decryption to the TUN
//! device. Every buffer has a stable identifier, which lets us correlate timestamps
//! captured at the different stages without threading them through the hot path.
//!
//! A packet's timeline is re-keyed as it moves from one buffer to the next, and recorded
//! once it leaves connlib (flushed to the socket, or written to the TUN device). When a
//! buffer is dropped before reaching that terminal stage, [`forget`] discards its
//! timeline so nothing lingers. The per-phase durations are reported to a histogram,
//! differentiated by a `network.io.direction` and a `packet.phase` attribute.
//!
//! Everything is gated on the `stream_metrics` feature-flag via [`set_enabled`]. While
//! disabled, every function returns after a single relaxed atomic load and [`Instant`]
//! captures nothing.

use std::sync::{
    LazyLock,
    atomic::{AtomicBool, Ordering},
};

use dashmap::DashMap;
use opentelemetry::{
    KeyValue,
    metrics::{Histogram, Meter},
};
use smallvec::SmallVec;

/// Whether packet-timing is currently recording.
static ENABLED: AtomicBool = AtomicBool::new(false);

/// Enables or disables packet-timing, driven by the `stream_metrics` feature-flag.
pub fn set_enabled(enabled: bool) {
    ENABLED.store(enabled, Ordering::Relaxed);
}

/// A timestamp that is only actually captured while packet-timing is enabled.
///
/// [`Instant::now`] is a no-op that captures nothing while disabled, so callers on the
/// hot path can record timestamps unconditionally without branching themselves.
#[derive(Clone, Copy, Default, Debug)]
pub struct Instant(Option<std::time::Instant>);

impl Instant {
    /// Captures the current time, or nothing if packet-timing is disabled.
    pub fn now() -> Self {
        Self(enabled().then(std::time::Instant::now))
    }

    /// The duration from `earlier` to `self`, or `None` if either end was not captured.
    fn duration_since(self, earlier: Self) -> Option<std::time::Duration> {
        Some(self.0?.saturating_duration_since(earlier.0?))
    }
}

/// Discards any in-flight timeline keyed by the buffer `id`.
///
/// Called when a pool buffer is dropped, so the timeline of a packet that never reached
/// its terminal stage (a dropped or filtered packet, or a cleared send-queue batch) is
/// cleaned up rather than lingering until the buffer's id is reused.
pub fn forget(id: u64) {
    if !enabled() {
        return;
    }

    pending().remove(&id);
    batches().remove(&id);
}

/// Timing of the outbound path: TUN device -> encryption -> UDP socket.
pub mod transmit {
    use super::*;

    /// A packet was read from the TUN device into the buffer `id`.
    pub fn tun_read(id: u64) {
        if !enabled() {
            return;
        }

        pending().insert(id, Timeline::started(Direction::Transmit));
    }

    /// The packet, still held in buffer `id`, arrived at the processing thread, about to
    /// be handed to the sans-IO state.
    pub fn arrived(id: u64) {
        set(id, |t| t.arrived = Instant::now());
    }

    /// The sans-IO state finished processing the packet, moving its timeline from the
    /// source buffer `from` onto the buffer `into` that now holds the encrypted payload.
    pub fn encrypted(from: u64, into: u64) {
        if !enabled() {
            return;
        }

        let Some((_, mut timeline)) = pending().remove(&from) else {
            return;
        };

        timeline.processed = Instant::now();
        pending().insert(into, timeline);
    }

    /// The encrypted `payload` buffer was coalesced into the GSO `batch` buffer, moving
    /// its timeline onto the batch.
    pub fn enqueued(payload: u64, batch: u64) {
        if !enabled() {
            return;
        }

        let Some((_, timeline)) = pending().remove(&payload) else {
            return;
        };

        batches().entry(batch).or_default().push(timeline);
    }

    /// The GSO `batch` buffer was flushed to the socket, finalising every packet
    /// coalesced into it.
    ///
    /// Called from the socket layer right after the send syscall, while the buffer is
    /// still owned by the send, so a recycled buffer reusing this `id` cannot race it.
    pub fn flushed(batch: u64) {
        if !enabled() {
            return;
        }

        let now = Instant::now();

        let Some((_, timelines)) = batches().remove(&batch) else {
            return;
        };

        for timeline in timelines {
            timeline.record(now);
        }
    }
}

/// Timing of the inbound path: UDP socket -> decryption -> TUN device.
pub mod receive {
    use super::*;

    /// The sans-IO state finished decrypting an inbound packet into the buffer `id`.
    ///
    /// Unlike the outbound path, an inbound datagram has no stable per-packet buffer
    /// until it is decrypted (it starts as a slice into a coalesced GRO buffer), so the
    /// earlier timestamps are passed in: `received_at` is when the datagram was read off
    /// the socket and `arrived` is when the event-loop handed it to the sans-IO state.
    pub fn decrypted(id: u64, received_at: Instant, arrived: Instant) {
        if !enabled() {
            return;
        }

        pending().insert(
            id,
            Timeline {
                direction: Direction::Receive,
                io_in: received_at,
                arrived,
                processed: Instant::now(),
            },
        );
    }

    /// The decrypted packet in buffer `id` was written to the TUN device, finalising it.
    pub fn written_to_tun(id: u64) {
        if !enabled() {
            return;
        }

        let now = Instant::now();

        let Some((_, timeline)) = pending().remove(&id) else {
            return;
        };

        timeline.record(now);
    }
}

fn enabled() -> bool {
    ENABLED.load(Ordering::Relaxed)
}

/// Updates the in-flight timeline keyed by `id`, if one exists and tracking is enabled.
fn set(id: u64, update: impl FnOnce(&mut Timeline)) {
    if !enabled() {
        return;
    }

    if let Some(mut timeline) = pending().get_mut(&id) {
        update(&mut timeline);
    }
}

#[derive(Clone, Copy)]
enum Direction {
    Transmit,
    Receive,
}

/// The timestamps captured for a single packet as it moves through connlib.
///
/// `arrived` is when the event-loop handed the packet to the sans-IO state and
/// `processed` is when that call returned, so the span between them (the `processing`
/// phase) covers routing and the (en|de)cryption that dominates it. Timestamps not yet
/// reached are empty and simply omit their phase when recording.
struct Timeline {
    direction: Direction,
    io_in: Instant,
    arrived: Instant,
    processed: Instant,
}

impl Timeline {
    fn started(direction: Direction) -> Self {
        Self {
            direction,
            io_in: Instant::now(),
            arrived: Instant::default(),
            processed: Instant::default(),
        }
    }

    fn record(self, io_out: Instant) {
        let direction = direction(self.direction);

        if let Some(duration) = self.arrived.duration_since(self.io_in) {
            histogram().record(
                duration.as_secs_f64(),
                &[direction.clone(), phase("io_to_processing")],
            );
        }
        if let Some(duration) = self.processed.duration_since(self.arrived) {
            histogram().record(
                duration.as_secs_f64(),
                &[direction.clone(), phase("processing")],
            );
        }
        if let Some(duration) = io_out.duration_since(self.processed) {
            histogram().record(
                duration.as_secs_f64(),
                &[direction.clone(), phase("processing_to_io")],
            );
        }
        if let Some(duration) = io_out.duration_since(self.io_in) {
            histogram().record(duration.as_secs_f64(), &[direction, phase("total")]);
        }
    }
}

fn phase(phase: &'static str) -> KeyValue {
    KeyValue::new("packet.phase", phase)
}

fn direction(direction: Direction) -> KeyValue {
    KeyValue::new(
        "network.io.direction",
        match direction {
            Direction::Transmit => "transmit",
            Direction::Receive => "receive",
        },
    )
}

fn pending() -> &'static DashMap<u64, Timeline> {
    static PENDING: LazyLock<DashMap<u64, Timeline>> = LazyLock::new(DashMap::new);

    &PENDING
}

fn batches() -> &'static DashMap<u64, SmallVec<[Timeline; 8]>> {
    static BATCHES: LazyLock<DashMap<u64, SmallVec<[Timeline; 8]>>> = LazyLock::new(DashMap::new);

    &BATCHES
}

fn histogram() -> &'static Histogram<f64> {
    static HISTOGRAM: LazyLock<Histogram<f64>> = LazyLock::new(packet_processing_duration);

    &HISTOGRAM
}

/// Time a packet spends in each phase of connlib's data path.
///
/// Individual phases are differentiated through the `network.io.direction` and
/// `packet.phase` attributes.
fn packet_processing_duration() -> Histogram<f64> {
    meter()
        .f64_histogram("connlib.packet.processing.duration")
        .with_description("Time a packet spends in each phase of connlib's data path.")
        .with_unit("s")
        .with_boundaries(vec![
            0.000_001, // 1µs
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
            0.025_000, // 25ms
            0.050_000, // 50ms
            0.100_000, // 100ms
        ])
        .build()
}

fn meter() -> Meter {
    opentelemetry::global::meter("connlib")
}

#[cfg(test)]
mod tests {
    use super::*;

    // The module relies on process-global state, so the chains and the disabled case are
    // exercised within a single test to keep it deterministic.
    #[test]
    fn rekeys_timelines_along_buffer_chain_and_is_a_noop_while_disabled() {
        const TUN: u64 = 1001;
        const PAYLOAD: u64 = 1002;
        const BATCH: u64 = 1003;
        const DECRYPTED: u64 = 1004;
        const DROPPED: u64 = 1005;
        const DISABLED: u64 = 1006;

        set_enabled(true);

        // Outbound: the timeline moves TUN buffer -> payload buffer -> GSO batch.
        transmit::tun_read(TUN);
        assert!(pending().contains_key(&TUN));

        transmit::arrived(TUN);
        transmit::encrypted(TUN, PAYLOAD);
        assert!(
            !pending().contains_key(&TUN),
            "timeline moves off the TUN buffer"
        );
        assert!(pending().contains_key(&PAYLOAD));

        transmit::enqueued(PAYLOAD, BATCH);
        assert!(
            !pending().contains_key(&PAYLOAD),
            "timeline moves onto the batch"
        );
        assert_eq!(batches().get(&BATCH).map(|b| b.len()), Some(1));

        transmit::flushed(BATCH);
        assert!(
            !batches().contains_key(&BATCH),
            "flushing finalises the batch"
        );

        // Inbound: the timeline lives on the decrypted buffer until written to the TUN.
        receive::decrypted(DECRYPTED, Instant::now(), Instant::now());
        assert!(pending().contains_key(&DECRYPTED));

        receive::written_to_tun(DECRYPTED);
        assert!(
            !pending().contains_key(&DECRYPTED),
            "writing to TUN finalises it"
        );

        // A buffer dropped before its terminal stage has its timeline forgotten.
        transmit::tun_read(DROPPED);
        assert!(pending().contains_key(&DROPPED));
        forget(DROPPED);
        assert!(
            !pending().contains_key(&DROPPED),
            "forget cleans up an abandoned timeline"
        );

        set_enabled(false);
        transmit::tun_read(DISABLED);
        assert!(!pending().contains_key(&DISABLED), "no-op while disabled");
    }
}
