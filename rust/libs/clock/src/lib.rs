use std::time::{Duration, Instant, SystemTime};

/// Differences smaller than this are assumed to be clock resolution, sampling jitter, or clock
/// slewing rather than time spent suspended.
const CLOCK_DRIFT_TOLERANCE: Duration = Duration::from_secs(1);

/// A monotonic clock that also advances while the system is suspended.
///
/// [`Instant`] does not consistently include time spent suspended across supported platforms.
/// [`SystemTime`] does, but can move backwards and is therefore unsuitable for state-machine
/// deadlines. This clock retains [`Instant`] as its clock domain and adds any elapsed time observed
/// by [`SystemTime`] but not by [`Instant`].
pub struct Clock {
    last_monotonic: Instant,
    last_system: SystemTime,
    suspend_offset: Duration,
}

impl Clock {
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns a monotonic timestamp that includes time spent suspended.
    pub fn now(&mut self) -> Instant {
        self.sample(Instant::now(), SystemTime::now())
    }

    fn sample(&mut self, monotonic: Instant, system: SystemTime) -> Instant {
        let monotonic_elapsed = monotonic.saturating_duration_since(self.last_monotonic);
        let system_elapsed = system.duration_since(self.last_system).ok();

        self.last_monotonic = monotonic;
        self.last_system = system;

        let missing = system_elapsed
            .unwrap_or(monotonic_elapsed)
            .saturating_sub(monotonic_elapsed);

        if missing >= CLOCK_DRIFT_TOLERANCE {
            let offset = self.suspend_offset.saturating_add(missing);

            if monotonic.checked_add(offset).is_some() {
                self.suspend_offset = offset;
                tracing::debug!(
                    advanced_by = ?missing,
                    total_advance = ?self.suspend_offset,
                    "Advancing suspend-aware clock after system suspend or wall-clock adjustment"
                );
            } else {
                tracing::warn!(
                    ?missing,
                    "Unable to advance suspend-aware clock without overflowing"
                );
            }
        }

        monotonic
            .checked_add(self.suspend_offset)
            .unwrap_or(monotonic)
    }
}

impl Default for Clock {
    fn default() -> Self {
        Self {
            last_monotonic: Instant::now(),
            last_system: SystemTime::now(),
            suspend_offset: Duration::ZERO,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn follows_monotonic_clock_during_normal_operation() {
        let monotonic = Instant::now();
        let system = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let mut clock = clock_at(monotonic, system);

        assert_eq!(
            clock.sample(
                monotonic + Duration::from_secs(5),
                system + Duration::from_secs(5)
            ),
            monotonic + Duration::from_secs(5)
        );
    }

    #[test]
    fn adds_time_missing_from_monotonic_clock() {
        let monotonic = Instant::now();
        let system = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let mut clock = clock_at(monotonic, system);

        let now = clock.sample(
            monotonic + Duration::from_secs(1),
            system + Duration::from_secs(3 * 60 * 60 + 1),
        );

        assert_eq!(now, monotonic + Duration::from_secs(3 * 60 * 60 + 1));

        // The detected suspend offset remains part of the clock domain without being counted
        // again on subsequent samples.
        assert_eq!(
            clock.sample(
                monotonic + Duration::from_secs(2),
                system + Duration::from_secs(3 * 60 * 60 + 2),
            ),
            monotonic + Duration::from_secs(3 * 60 * 60 + 2)
        );
    }

    #[test]
    fn ignores_small_clock_differences_without_accumulating_them() {
        let monotonic = Instant::now();
        let system = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let mut clock = clock_at(monotonic, system);

        assert_eq!(
            clock.sample(
                monotonic + Duration::from_secs(1),
                system + Duration::from_millis(1_500),
            ),
            monotonic + Duration::from_secs(1)
        );
        assert_eq!(
            clock.sample(
                monotonic + Duration::from_secs(2),
                system + Duration::from_millis(2_500),
            ),
            monotonic + Duration::from_secs(2)
        );
    }

    #[test]
    fn ignores_backward_system_clock_adjustments() {
        let monotonic = Instant::now();
        let system = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let mut clock = clock_at(monotonic, system);

        assert_eq!(
            clock.sample(
                monotonic + Duration::from_secs(5),
                system - Duration::from_secs(60),
            ),
            monotonic + Duration::from_secs(5)
        );
        assert_eq!(
            clock.sample(
                monotonic + Duration::from_secs(6),
                system - Duration::from_secs(59),
            ),
            monotonic + Duration::from_secs(6)
        );
    }

    fn clock_at(monotonic: Instant, system: SystemTime) -> Clock {
        Clock {
            last_monotonic: monotonic,
            last_system: system,
            suspend_offset: Duration::ZERO,
        }
    }
}
