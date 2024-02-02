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
    let prototype = backoff::ExponentialBackoff::default();

    ExponentialBackoff {
        current_interval: initial_interval,
        initial_interval,
        randomization_factor: 0.,
        multiplier: prototype.multiplier,
        max_interval: prototype.max_interval,
        start_time: now,
        max_elapsed_time: prototype.max_elapsed_time,
        clock: ManualClock { now },
    }
}
