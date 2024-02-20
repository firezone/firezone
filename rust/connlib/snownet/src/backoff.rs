use std::time::{Duration, Instant};

pub type ExponentialBackoff = backoff::exponential::ExponentialBackoff<ManualClock>;

#[derive(Debug)]
pub struct ManualClock {
    pub now: Instant,
}

impl backoff::Clock for ManualClock {
    fn now(&self) -> Instant {
        self.now
    }
}

pub fn new(
    now: Instant,
    initial_interval: Duration,
) -> backoff::exponential::ExponentialBackoff<ManualClock> {
    ExponentialBackoff {
        current_interval: initial_interval,
        initial_interval,
        randomization_factor: 0.,
        multiplier: backoff::default::MULTIPLIER,
        max_interval: Duration::from_millis(backoff::default::MAX_INTERVAL_MILLIS),
        start_time: now,
        max_elapsed_time: Some(Duration::from_secs(60)),
        clock: ManualClock { now },
    }
}

/// Calculates our backoff times, starting from the given [`Instant`].
///
/// The current strategy is multiplying the previous interval by 1.5 and adding them up.
#[cfg(test)]
pub fn steps(start: Instant) -> [Instant; 8] {
    fn secs(secs: f64) -> Duration {
        Duration::from_nanos((secs * 1_000_000_000.0) as u64)
    }

    [
        start + secs(1.0),
        start + secs(1.0 + 1.5),
        start + secs(1.0 + 1.5 + 2.25),
        start + secs(1.0 + 1.5 + 2.25 + 3.375),
        start + secs(1.0 + 1.5 + 2.25 + 3.375 + 5.0625),
        start + secs(1.0 + 1.5 + 2.25 + 3.375 + 5.0625 + 7.59375),
        start + secs(1.0 + 1.5 + 2.25 + 3.375 + 5.0625 + 7.59375 + 11.390625),
        start + secs(1.0 + 1.5 + 2.25 + 3.375 + 5.0625 + 7.59375 + 11.390625 + 17.0859375),
    ]
}
