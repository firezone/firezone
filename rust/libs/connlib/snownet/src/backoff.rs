use std::time::{Duration, Instant};

const MULTIPLIER: f32 = 1.5;

#[derive(Debug)]
pub struct ExponentialBackoff {
    start_time: Instant,
    max_elapsed: Duration,
    next_trigger: Instant,
    interval: Duration,
}

impl ExponentialBackoff {
    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        if self.is_expired(now) {
            return;
        }

        if now < self.next_trigger {
            return;
        }

        self.interval = Duration::from_secs_f32(self.interval.as_secs_f32() * MULTIPLIER);
        self.next_trigger += self.interval;
    }

    pub(crate) fn next_trigger(&self) -> Instant {
        self.next_trigger
    }

    pub(crate) fn is_expired(&self, at: Instant) -> bool {
        at >= self.start_time + self.max_elapsed
    }

    pub(crate) fn interval(&self) -> Duration {
        self.interval
    }

    pub(crate) fn start_time(&self) -> Instant {
        self.start_time
    }
}

pub fn new(now: Instant, interval: Duration, max_elapsed: Duration) -> ExponentialBackoff {
    ExponentialBackoff {
        interval,
        start_time: now,
        max_elapsed,
        next_trigger: now + interval,
    }
}

/// Calculates our backoff times, starting from the given [`Instant`].
///
/// The current strategy is multiplying the previous interval by 1.5 and adding them up.
#[cfg(test)]
pub fn steps(start: Instant) -> [Instant; 4] {
    fn secs(secs: f64) -> Duration {
        Duration::from_nanos((secs * 1_000_000_000.0) as u64)
    }

    [
        start + secs(1.0),
        start + secs(1.0 + 1.5),
        start + secs(1.0 + 1.5 + 2.25),
        start + secs(1.0 + 1.5 + 2.25 + 3.375),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{collections::BTreeSet, iter};

    #[test]
    fn backoff_steps() {
        let mut now = Instant::now();

        let steps = Vec::from_iter(
            iter::from_fn({
                let mut backoff = super::new(now, Duration::from_secs(1), Duration::from_secs(8));

                move || {
                    if backoff.is_expired(now) {
                        return None;
                    }

                    now += Duration::from_millis(100); // Purposely updating more often than the interval.
                    backoff.handle_timeout(now);

                    Some(backoff.next_trigger())
                }
            })
            .collect::<BTreeSet<_>>(),
        );

        assert_eq!(&steps, &super::steps(now));
    }
}
