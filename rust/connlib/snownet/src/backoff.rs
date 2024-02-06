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
        max_elapsed_time: Some(Duration::from_millis(
            backoff::default::MAX_ELAPSED_TIME_MILLIS,
        )),
        clock: ManualClock { now },
    }
}

/// Calculates our backoff times, starting from the given [`Instant`].
///
/// The current strategy is multiplying the previous interval by 1.5 and adding them up.
#[cfg(test)]
pub fn steps(start: Instant) -> [Instant; 19] {
    fn secs(secs: f64) -> Duration {
        Duration::from_micros((secs * 1_000_000.0) as u64)
    }

    [
        start + secs(5.0),
        start + secs(5.0 + 7.5),
        start + secs(5.0 + 7.5 + 11.25),
        start + secs(5.0 + 7.5 + 11.25 + 16.875),
        start + secs(5.0 + 7.5 + 11.25 + 16.875 + 25.3125),
        start + secs(5.0 + 7.5 + 11.25 + 16.875 + 25.3125 + 37.96875),
        start + secs(5.0 + 7.5 + 11.25 + 16.875 + 25.3125 + 37.96875 + 56.953125),
        start + secs(5.0 + 7.5 + 11.25 + 16.875 + 25.3125 + 37.96875 + 56.953125 + 60.0 * 1.0),
        start + secs(5.0 + 7.5 + 11.25 + 16.875 + 25.3125 + 37.96875 + 56.953125 + 60.0 * 2.0),
        start + secs(5.0 + 7.5 + 11.25 + 16.875 + 25.3125 + 37.96875 + 56.953125 + 60.0 * 3.0),
        start + secs(5.0 + 7.5 + 11.25 + 16.875 + 25.3125 + 37.96875 + 56.953125 + 60.0 * 4.0),
        start + secs(5.0 + 7.5 + 11.25 + 16.875 + 25.3125 + 37.96875 + 56.953125 + 60.0 * 5.0),
        start + secs(5.0 + 7.5 + 11.25 + 16.875 + 25.3125 + 37.96875 + 56.953125 + 60.0 * 6.0),
        start + secs(5.0 + 7.5 + 11.25 + 16.875 + 25.3125 + 37.96875 + 56.953125 + 60.0 * 7.0),
        start + secs(5.0 + 7.5 + 11.25 + 16.875 + 25.3125 + 37.96875 + 56.953125 + 60.0 * 8.0),
        start + secs(5.0 + 7.5 + 11.25 + 16.875 + 25.3125 + 37.96875 + 56.953125 + 60.0 * 9.0),
        start + secs(5.0 + 7.5 + 11.25 + 16.875 + 25.3125 + 37.96875 + 56.953125 + 60.0 * 10.0),
        start + secs(5.0 + 7.5 + 11.25 + 16.875 + 25.3125 + 37.96875 + 56.953125 + 60.0 * 11.0),
        start + secs(5.0 + 7.5 + 11.25 + 16.875 + 25.3125 + 37.96875 + 56.953125 + 60.0 * 12.0),
    ]
}
