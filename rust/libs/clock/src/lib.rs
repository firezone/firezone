use std::time::{Duration, Instant, SystemTime};

/// Differences smaller than this are assumed to be clock resolution, sampling jitter, or clock
/// slewing rather than time spent suspended.
const CLOCK_DRIFT_TOLERANCE: Duration = Duration::from_secs(1);

/// How far past its deadline a sample may land before the event loop counts as stalled.
///
/// Missing a deadline by this much means we went that long without servicing our sockets, so NAT
/// bindings, ICE candidates and peer sessions are all suspect. The cause does not matter: a system
/// suspend, a starved process and an OS that never reported its suspend all look the same here.
const LATENESS_THRESHOLD: Duration = Duration::from_secs(30);

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
    sample_due_by: Option<Instant>,
    lateness: Option<Duration>,
}

impl Clock {
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns a monotonic timestamp that includes time spent suspended.
    pub fn now(&mut self) -> Instant {
        self.sample(Instant::now(), SystemTime::now())
    }

    /// Records when the caller next expects to sample this clock.
    ///
    /// Only a sample measured against a deadline can be called late: without one, an event loop
    /// that slept because it had nothing to do is indistinguishable from one that was prevented
    /// from running.
    pub fn expect_sample_by(&mut self, deadline: Option<Instant>) {
        self.sample_due_by = deadline;
    }

    /// Returns, once, by how much the latest sample overshot its deadline.
    pub fn poll_lateness(&mut self) -> Option<Duration> {
        self.lateness.take()
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

        let now = monotonic
            .checked_add(self.suspend_offset)
            .unwrap_or(monotonic);

        // Time spent suspended counts towards the overshoot: it is time we did not service our
        // sockets.
        if let Some(due_by) = self.sample_due_by.take() {
            let late_by = now.saturating_duration_since(due_by);

            if late_by >= LATENESS_THRESHOLD {
                self.lateness = Some(late_by);
            }
        }

        now
    }
}

impl Default for Clock {
    fn default() -> Self {
        Self {
            last_monotonic: Instant::now(),
            last_system: SystemTime::now(),
            suspend_offset: Duration::ZERO,
            sample_due_by: None,
            lateness: None,
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

    #[test]
    fn reports_a_sample_that_overshoots_its_deadline() {
        let monotonic = Instant::now();
        let system = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let mut clock = clock_at(monotonic, system);

        clock.expect_sample_by(Some(monotonic + Duration::from_secs(10)));
        clock.sample(
            monotonic + Duration::from_secs(45),
            system + Duration::from_secs(45),
        );

        assert_eq!(clock.poll_lateness(), Some(Duration::from_secs(35)));
        assert_eq!(clock.poll_lateness(), None, "overshoot is reported once");
    }

    #[test]
    fn does_not_report_a_sample_that_roughly_meets_its_deadline() {
        let monotonic = Instant::now();
        let system = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let mut clock = clock_at(monotonic, system);

        clock.expect_sample_by(Some(monotonic + Duration::from_secs(10)));
        clock.sample(
            monotonic + Duration::from_secs(11),
            system + Duration::from_secs(11),
        );

        assert_eq!(clock.poll_lateness(), None);
    }

    #[test]
    fn does_not_report_a_long_gap_without_a_deadline() {
        let monotonic = Instant::now();
        let system = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let mut clock = clock_at(monotonic, system);

        clock.sample(
            monotonic + Duration::from_secs(600),
            system + Duration::from_secs(600),
        );

        assert_eq!(clock.poll_lateness(), None);
    }

    #[test]
    fn counts_time_spent_suspended_towards_the_overshoot() {
        let monotonic = Instant::now();
        let system = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let mut clock = clock_at(monotonic, system);

        clock.expect_sample_by(Some(monotonic + Duration::from_secs(10)));

        // A suspend barely advances the monotonic clock but does not stop the system clock.
        clock.sample(
            monotonic + Duration::from_secs(1),
            system + Duration::from_secs(120),
        );

        assert_eq!(clock.poll_lateness(), Some(Duration::from_secs(110)));
    }

    fn clock_at(monotonic: Instant, system: SystemTime) -> Clock {
        Clock {
            last_monotonic: monotonic,
            last_system: system,
            suspend_offset: Duration::ZERO,
            sample_due_by: None,
            lateness: None,
        }
    }
}
