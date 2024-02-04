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
