use std::{
    future::Future as _,
    pin::Pin,
    task::{Context, Poll, ready},
    time::{Duration, Instant, SystemTime},
};

/// Differences smaller than this are assumed to be clock resolution, sampling jitter, or clock
/// slewing rather than time spent suspended.
const CLOCK_DRIFT_TOLERANCE: Duration = Duration::from_secs(1);

/// How far past its deadline a sample may land before the event loop counts as stalled.
///
/// Missing a deadline by this much means we went that long without servicing our sockets, so NAT
/// bindings, ICE candidates and peer sessions are all suspect. The cause does not matter: a system
/// suspend, a starved process and an OS that never reported its suspend all look the same here.
const LATENESS_THRESHOLD: Duration = Duration::from_secs(30);

/// What the event loop has to react to, in the order [`Clock::poll_event`] reports it.
#[derive(Debug, PartialEq, Eq)]
pub enum Event {
    /// The latest sample landed this far past the deadline set via [`Clock::set_alarm`].
    Late(Duration),
    /// The deadline set via [`Clock::set_alarm`] has passed, as observed at this instant.
    Alarm(Instant),
}

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
    /// The deadline the event loop asked to be woken at, in this clock's domain.
    alarm_at: Option<Instant>,
    /// The same deadline as a raw [`Instant`], which is what the timer runs on.
    raw_alarm_at: Option<Instant>,
    alarm: Option<Pin<Box<tokio::time::Sleep>>>,
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

    /// Arms the alarm for `deadline`, which is in this clock's domain, and registers interest in
    /// it so that `cx` is woken once it rings.
    ///
    /// Time spent suspended before the next sample counts towards the overshoot reported as
    /// [`Event::Late`]: it is time we did not service our sockets.
    pub fn set_alarm(&mut self, cx: &mut Context<'_>, deadline: Option<Instant>) {
        let Some(deadline) = deadline else {
            self.alarm_at = None;
            self.raw_alarm_at = None;
            self.alarm = None;

            return;
        };

        let raw_now = Instant::now();
        let now = raw_now.checked_add(self.suspend_offset).unwrap_or(raw_now);

        // A deadline we are already past means the caller has work waiting, not that we mean to
        // sleep. Measuring an overshoot against it would report how stale the deadline is rather
        // than how late we ran.
        self.alarm_at = (deadline > now).then_some(deadline);
        self.raw_alarm_at = Some(raw_now + deadline.saturating_duration_since(now));

        // A deadline that is already due leaves nothing to wake us, so ask to be polled again.
        if self.poll_alarm(cx).is_ready() {
            cx.waker().wake_by_ref();
        }
    }

    /// Reports each [`Event`] once.
    ///
    /// The alarm rings once per [`Clock::set_alarm`] and is quiet until re-armed, so a caller that
    /// polls after every wake-up runs its timeout handling exactly once per deadline.
    pub fn poll_event(&mut self, cx: &mut Context<'_>) -> Poll<Event> {
        if let Some(by) = self.lateness.take() {
            return Poll::Ready(Event::Late(by));
        }

        ready!(self.poll_alarm(cx));
        self.raw_alarm_at = None;

        Poll::Ready(Event::Alarm(self.now()))
    }

    fn poll_alarm(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        let Some(target) = self.raw_alarm_at else {
            return Poll::Pending;
        };
        let target = tokio::time::Instant::from_std(target);

        let alarm = self
            .alarm
            .get_or_insert_with(|| Box::pin(tokio::time::sleep_until(target)));

        if alarm.deadline() != target {
            alarm.as_mut().reset(target);
        }

        alarm.as_mut().poll(cx)
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

        if let Some(due) = self.alarm_at.take() {
            let late = now.saturating_duration_since(due);

            if late >= LATENESS_THRESHOLD {
                self.lateness = Some(late);
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
            alarm_at: None,
            raw_alarm_at: None,
            alarm: None,
            lateness: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::task::Waker;

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

    #[tokio::test(start_paused = true)]
    async fn reports_a_sample_that_overshoots_its_deadline() {
        let monotonic = Instant::now();
        let system = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let mut clock = clock_at(monotonic, system);

        set_alarm(&mut clock, Some(monotonic + Duration::from_secs(10)));
        clock.sample(
            monotonic + Duration::from_secs(45),
            system + Duration::from_secs(45),
        );

        assert_eq!(
            poll_once(&mut clock),
            Poll::Ready(Event::Late(Duration::from_secs(35)))
        );
        assert_eq!(
            poll_once(&mut clock),
            Poll::Pending,
            "overshoot is reported once"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn does_not_report_a_sample_that_roughly_meets_its_deadline() {
        let monotonic = Instant::now();
        let system = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let mut clock = clock_at(monotonic, system);

        set_alarm(&mut clock, Some(monotonic + Duration::from_secs(10)));
        clock.sample(
            monotonic + Duration::from_secs(11),
            system + Duration::from_secs(11),
        );

        assert_eq!(poll_once(&mut clock), Poll::Pending);
    }

    #[tokio::test(start_paused = true)]
    async fn does_not_report_an_overshoot_against_a_deadline_that_had_already_passed() {
        let monotonic = Instant::now();
        let system = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let mut clock = clock_at(monotonic, system);

        // Arming a deadline in the past says there is work waiting, not that we will sleep.
        set_alarm(&mut clock, Some(monotonic - Duration::from_secs(120)));
        clock.sample(
            monotonic + Duration::from_secs(1),
            system + Duration::from_secs(1),
        );

        assert_eq!(
            poll_once(&mut clock),
            Poll::Pending,
            "a deadline we never meant to sleep until is not an overshoot"
        );

        tokio::time::advance(Duration::from_secs(1)).await;
        assert!(matches!(
            poll_once(&mut clock),
            Poll::Ready(Event::Alarm(_))
        ));
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

        assert_eq!(poll_once(&mut clock), Poll::Pending);
    }

    #[tokio::test(start_paused = true)]
    async fn counts_time_spent_suspended_towards_the_overshoot() {
        let monotonic = Instant::now();
        let system = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let mut clock = clock_at(monotonic, system);

        set_alarm(&mut clock, Some(monotonic + Duration::from_secs(10)));

        // A suspend barely advances the monotonic clock but does not stop the system clock.
        clock.sample(
            monotonic + Duration::from_secs(1),
            system + Duration::from_secs(120),
        );

        assert_eq!(
            poll_once(&mut clock),
            Poll::Ready(Event::Late(Duration::from_secs(110)))
        );
    }

    #[tokio::test(start_paused = true)]
    async fn alarm_rings_once_the_deadline_has_passed() {
        let mut clock = Clock::new();
        let now = Instant::now();

        set_alarm(&mut clock, Some(now + Duration::from_secs(5)));
        assert_eq!(poll_once(&mut clock), Poll::Pending);

        tokio::time::advance(Duration::from_secs(6)).await;
        assert!(matches!(
            poll_once(&mut clock),
            Poll::Ready(Event::Alarm(_))
        ));
        assert_eq!(
            poll_once(&mut clock),
            Poll::Pending,
            "the alarm rings once until re-armed"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn alarm_without_deadline_never_rings() {
        let mut clock = Clock::new();

        set_alarm(&mut clock, None);
        tokio::time::advance(Duration::from_secs(60)).await;

        assert_eq!(poll_once(&mut clock), Poll::Pending);
    }

    fn poll_once(clock: &mut Clock) -> Poll<Event> {
        clock.poll_event(&mut Context::from_waker(Waker::noop()))
    }

    fn set_alarm(clock: &mut Clock, deadline: Option<Instant>) {
        clock.set_alarm(&mut Context::from_waker(Waker::noop()), deadline);
    }

    fn clock_at(monotonic: Instant, system: SystemTime) -> Clock {
        Clock {
            last_monotonic: monotonic,
            last_system: system,
            suspend_offset: Duration::ZERO,
            alarm_at: None,
            raw_alarm_at: None,
            alarm: None,
            lateness: None,
        }
    }
}
