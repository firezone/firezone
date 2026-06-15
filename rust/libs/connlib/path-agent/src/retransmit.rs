//! Per-pair `HandshakeInit` retransmit ladder driving the
//! path-evaluation fanout.

use std::time::{Duration, Instant};

pub(crate) struct PairRetransmit {
    pub(crate) next_fire_at: Instant,
    pub(crate) step: usize,
}

impl PairRetransmit {
    /// 50/50/50 ms head covers the race where our init lands on a
    /// relay before the *peer's* channel-bind is registered. Past
    /// that, exponential doubling capped at 1.6 s.
    const LADDER_MS: &'static [u64] = &[50, 50, 50, 100, 200, 400, 800, 1600];

    pub(crate) fn new(now: Instant) -> Self {
        Self {
            next_fire_at: now + Duration::from_millis(Self::LADDER_MS[0]),
            step: 0,
        }
    }

    pub(crate) fn advance(&mut self, now: Instant) {
        self.step = (self.step + 1).min(Self::LADDER_MS.len() - 1);
        self.next_fire_at = now + Duration::from_millis(Self::LADDER_MS[self.step]);
    }
}
