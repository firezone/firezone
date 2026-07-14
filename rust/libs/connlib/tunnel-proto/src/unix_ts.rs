use std::time::{Duration, Instant};

/// Maps portal-supplied unix timestamps (`Duration` since `UNIX_EPOCH`) to
/// monotonic [`Instant`]s.
///
/// Captures an `Instant` and a unix timestamp at startup, then converts
/// later portal timestamps by applying the elapsed delta to the captured
/// baseline `Instant`.
#[derive(Debug, Clone, Copy)]
pub struct UnixTsClock {
    start_instant: Instant,
    start_unix_ts: Duration,
}

impl UnixTsClock {
    pub fn new(now: Instant, unix_ts: Duration) -> Self {
        Self {
            start_instant: now,
            start_unix_ts: unix_ts,
        }
    }

    /// Map a unix timestamp to an [`Instant`].
    ///
    /// `unix_ts` arrives from the portal and is therefore untrusted:
    /// - if it predates `start_unix_ts`, clamp to `start_instant` so the
    ///   resource is already expired against any later `now`;
    /// - if it would overflow `Instant`, log a warning and fall back to a
    ///   1-day expiry so access remains time-bounded.
    pub fn instant_at(&self, unix_ts: Duration, now: Instant) -> Instant {
        if unix_ts < self.start_unix_ts {
            tracing::warn!(
                ?unix_ts,
                start_unix_ts = ?self.start_unix_ts,
                "unix timestamp predates startup; treating as already expired",
            );
            return self.start_instant;
        }

        self.start_instant
            .checked_add(unix_ts - self.start_unix_ts)
            .unwrap_or_else(|| {
                tracing::warn!(
                    ?unix_ts,
                    "unix timestamp out of `Instant` range; falling back to 1 day expiry",
                );
                now + Duration::from_secs(86400)
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forward_offset() {
        let now = Instant::now();
        let baseline_unix = Duration::from_secs(1_700_000_000);
        let clock = UnixTsClock::new(now, baseline_unix);
        let later_unix = baseline_unix + Duration::from_secs(30);
        assert_eq!(
            clock.instant_at(later_unix, now),
            now + Duration::from_secs(30)
        );
    }

    #[test]
    fn past_timestamp_clamps_to_start() {
        let now = Instant::now();
        let baseline_unix = Duration::from_secs(1_700_000_000);
        let clock = UnixTsClock::new(now, baseline_unix);
        let earlier_unix = baseline_unix - Duration::from_secs(10);
        assert_eq!(
            clock.instant_at(earlier_unix, now + Duration::from_secs(60)),
            now
        );
    }
}
