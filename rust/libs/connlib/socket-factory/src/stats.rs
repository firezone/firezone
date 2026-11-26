//! Process-wide timing counters for the UDP receive and send paths, for profiling.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

pub(crate) static RECV_NANOS: AtomicU64 = AtomicU64::new(0);
pub(crate) static RECV_CALLS: AtomicU64 = AtomicU64::new(0);
pub(crate) static RECV_DATAGRAMS: AtomicU64 = AtomicU64::new(0);
pub(crate) static RECV_WAITS: AtomicU64 = AtomicU64::new(0);
pub(crate) static SEND_NANOS: AtomicU64 = AtomicU64::new(0);
pub(crate) static SEND_CALLS: AtomicU64 = AtomicU64::new(0);
pub(crate) static SEND_WAITS: AtomicU64 = AtomicU64::new(0);

pub(crate) fn add_since(counter: &AtomicU64, start: Instant) {
    counter.fetch_add(start.elapsed().as_nanos() as u64, Ordering::Relaxed);
}

pub(crate) fn inc(counter: &AtomicU64, n: u64) {
    counter.fetch_add(n, Ordering::Relaxed);
}

/// Counters since the last call to [`take`].
#[derive(Debug)]
pub struct Snapshot {
    /// Time in `quinn-udp`'s receive and building the batch.
    pub recv_ms: u64,
    pub recv_calls: u64,
    pub recv_datagrams: u64,
    /// How often receiving had to wait for readiness.
    pub recv_waits: u64,
    /// Time in `quinn-udp`'s send.
    pub send_ms: u64,
    pub send_calls: u64,
    /// How often a RIO send had to wait for a free slot.
    pub send_waits: u64,
}

pub fn take() -> Snapshot {
    let take = |c: &AtomicU64| c.swap(0, Ordering::Relaxed);

    Snapshot {
        recv_ms: take(&RECV_NANOS) / 1_000_000,
        recv_calls: take(&RECV_CALLS),
        recv_datagrams: take(&RECV_DATAGRAMS),
        recv_waits: take(&RECV_WAITS),
        send_ms: take(&SEND_NANOS) / 1_000_000,
        send_calls: take(&SEND_CALLS),
        send_waits: take(&SEND_WAITS),
    }
}
