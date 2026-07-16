use std::time::{Duration, Instant};

pub(crate) struct PairRetransmit {
    /// `None` once the ladder is spent: it runs once and stops, leaving further
    /// retransmission to boringtun's own re-init cadence.
    pub(crate) next_fire_at: Option<Instant>,
    pub(crate) step: usize,
}

impl PairRetransmit {
    /// Burst head covers the race where our init lands on a relay
    /// before the peer's channel-bind registers.
    const LADDER_MS: &'static [u64] = &[50, 50, 50, 100, 200, 400, 800, 1600];

    pub(crate) fn new(now: Instant) -> Self {
        Self {
            next_fire_at: Some(now + Duration::from_millis(Self::LADDER_MS[0])),
            step: 0,
        }
    }

    pub(crate) fn advance(&mut self, now: Instant) {
        self.step += 1;
        self.next_fire_at = Self::LADDER_MS
            .get(self.step)
            .map(|ms| now + Duration::from_millis(*ms));
    }
}
