use std::{
    future::Future as _,
    pin::Pin,
    task::{Context, Poll},
    time::{Duration, Instant},
};

#[derive(Debug, PartialEq, Eq)]
pub struct Alarm {
    /// The current time when the deadline was observed.
    pub now: Instant,
    /// Time the alarm was overdue. Zero if the deadline was already due when armed.
    pub late_by: Duration,
}

enum ArmedAlarm {
    Immediate,
    Scheduled { deadline: Instant },
}

/// A monotonic clock that also advances while the system is suspended.
///
/// All timestamps are in this clock's domain. Tokio's timer requests a poll, and
/// the suspend-inclusive clock determines when the deadline is due.
pub struct Clock {
    instant_at_start: Instant,
    os_clock_at_start: Duration,
    armed_alarm: Option<ArmedAlarm>,
    timer: Option<Pin<Box<tokio::time::Sleep>>>,
}

impl Clock {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn now(&self) -> Instant {
        self.instant_at(suspend_inclusive_now())
    }

    fn instant_at(&self, os_clock_now: Duration) -> Instant {
        let elapsed_since_start = os_clock_now.saturating_sub(self.os_clock_at_start);

        self.instant_at_start + elapsed_since_start
    }

    /// Replaces the alarm and registers the event loop for a wake-up.
    ///
    /// Poll for due alarms before replacing the deadline.
    pub fn set_alarm(&mut self, cx: &mut Context<'_>, deadline: Option<Instant>) {
        let Some(at) = deadline else {
            self.armed_alarm = None;
            self.timer = None;
            return;
        };

        let now = self.now();
        if at <= now {
            // Preserve a scheduled alarm if it became due while processing a poll.
            if !matches!(self.armed_alarm, Some(ArmedAlarm::Scheduled { deadline }) if deadline == at)
            {
                self.armed_alarm = Some(ArmedAlarm::Immediate);
            }

            cx.waker().wake_by_ref();
            return;
        }

        self.armed_alarm = Some(ArmedAlarm::Scheduled { deadline: at });
        self.arm_timer(cx, at.duration_since(now));
    }

    /// Reports the armed deadline once it has passed, including on an I/O wake
    /// while the Tokio timer is still pending.
    pub fn poll_alarm(&mut self, cx: &mut Context<'_>) -> Poll<Alarm> {
        if self.armed_alarm.is_none() {
            return Poll::Pending;
        }

        self.poll_at(cx, self.now())
    }

    fn poll_at(&mut self, cx: &mut Context<'_>, now: Instant) -> Poll<Alarm> {
        let late_by = match self.armed_alarm {
            None => return Poll::Pending,
            Some(ArmedAlarm::Immediate) => Duration::ZERO,
            Some(ArmedAlarm::Scheduled { deadline }) if now >= deadline => {
                now.duration_since(deadline)
            }
            Some(ArmedAlarm::Scheduled { deadline }) => {
                let timer = self.timer.as_mut().expect("scheduled alarm has a timer");
                if timer.as_mut().poll(cx).is_ready() {
                    self.arm_timer(cx, deadline.duration_since(now));
                }
                return Poll::Pending;
            }
        };

        self.armed_alarm = None;
        Poll::Ready(Alarm { now, late_by })
    }

    fn arm_timer(&mut self, cx: &mut Context<'_>, remaining: Duration) {
        let target = tokio::time::Instant::now() + remaining;
        let timer = self
            .timer
            .get_or_insert_with(|| Box::pin(tokio::time::sleep_until(target)));

        if timer.deadline() != target {
            timer.as_mut().reset(target);
        }

        if timer.as_mut().poll(cx).is_ready() {
            cx.waker().wake_by_ref();
        }
    }
}

impl Default for Clock {
    fn default() -> Self {
        Self {
            instant_at_start: Instant::now(),
            os_clock_at_start: suspend_inclusive_now(),
            armed_alarm: None,
            timer: None,
        }
    }
}

/// Returns the time since an arbitrary point, including time spent suspended.
fn suspend_inclusive_now() -> Duration {
    cfg_select! {
        any(target_os = "linux", target_os = "android") => clock_gettime(libc::CLOCK_BOOTTIME),
        target_vendor = "apple" => clock_gettime(libc::CLOCK_MONOTONIC_RAW),
        windows => {
            // SAFETY: `QueryInterruptTimePrecise` has no preconditions.
            let hundred_nanos =
                unsafe { windows::Win32::System::WindowsProgramming::QueryInterruptTimePrecise() };

            Duration::from_nanos(hundred_nanos * 100)
        }
    }
}

#[cfg(unix)]
fn clock_gettime(clock: libc::clockid_t) -> Duration {
    let mut time = std::mem::MaybeUninit::<libc::timespec>::uninit();

    // SAFETY: `time` is valid for writing one `timespec`.
    let ret = unsafe { libc::clock_gettime(clock, time.as_mut_ptr()) };
    assert_eq!(ret, 0, "suspend-inclusive clock should be available");

    // SAFETY: `clock_gettime` succeeded and therefore initialised `time`.
    let time = unsafe { time.assume_init() };

    Duration::new(time.tv_sec as u64, time.tv_nsec as u32)
}

#[cfg(test)]
mod tests {
    use std::task::Waker;

    use super::*;

    #[test]
    fn includes_each_short_suspend_in_the_next_sample() {
        let clock = Clock::new();

        for sample in 1..=3 {
            let elapsed = Duration::from_millis(1_400 * sample);
            assert_eq!(
                clock.instant_at(clock.os_clock_at_start + elapsed),
                clock.instant_at_start + elapsed,
            );
        }
    }

    #[tokio::test(start_paused = true)]
    async fn delivers_overdue_alarm_even_if_tokio_has_not_fired() {
        let mut clock = Clock::new();
        let mut cx = Context::from_waker(Waker::noop());
        let start = clock.now();
        clock.set_alarm(&mut cx, Some(start + Duration::from_secs(5)));

        assert_eq!(
            clock.poll_at(&mut cx, start + Duration::from_secs(1)),
            Poll::Pending
        );
        assert!(
            clock
                .timer
                .as_mut()
                .expect("armed deadline has a timer")
                .as_mut()
                .poll(&mut cx)
                .is_pending()
        );

        let now = start + Duration::from_secs(45);
        assert_eq!(
            clock.poll_at(&mut cx, now),
            Poll::Ready(Alarm {
                now,
                late_by: Duration::from_secs(40)
            }),
        );
        assert_eq!(clock.poll_at(&mut cx, now), Poll::Pending);
    }

    #[tokio::test(start_paused = true)]
    async fn already_due_alarm_reports_no_lateness() {
        let mut clock = Clock::new();
        let mut cx = Context::from_waker(Waker::noop());
        let start = clock.now();
        clock.set_alarm(&mut cx, Some(start));

        let now = start + Duration::from_secs(60);
        assert_eq!(
            clock.poll_at(&mut cx, now),
            Poll::Ready(Alarm {
                now,
                late_by: Duration::ZERO
            })
        );
    }

    #[tokio::test(start_paused = true)]
    async fn cancels_armed_alarm() {
        let mut clock = Clock::new();
        let mut cx = Context::from_waker(Waker::noop());
        let start = clock.now();
        clock.set_alarm(&mut cx, Some(start + Duration::from_secs(5)));
        clock.set_alarm(&mut cx, None);

        assert_eq!(
            clock.poll_at(&mut cx, start + Duration::from_secs(45)),
            Poll::Pending
        );
    }

    #[tokio::test(start_paused = true)]
    async fn re_registers_timer_if_it_wakes_before_the_logical_deadline() {
        let mut clock = Clock::new();
        let mut cx = Context::from_waker(Waker::noop());
        let start = clock.now();
        clock.set_alarm(&mut cx, Some(start + Duration::from_secs(5)));
        tokio::time::advance(Duration::from_secs(6)).await;

        assert_eq!(
            clock.poll_at(&mut cx, start + Duration::from_secs(3)),
            Poll::Pending
        );
        assert!(
            clock
                .timer
                .as_mut()
                .expect("armed deadline has a timer")
                .as_mut()
                .poll(&mut cx)
                .is_pending()
        );
    }

    #[test]
    fn suspend_inclusive_clock_advances_with_instant_while_awake() {
        let monotonic_start = Instant::now();
        let suspend_inclusive_start = suspend_inclusive_now();

        std::thread::sleep(Duration::from_millis(200));

        let monotonic_elapsed = monotonic_start.elapsed();
        let suspend_inclusive_elapsed = suspend_inclusive_now()
            .checked_sub(suspend_inclusive_start)
            .expect("suspend-inclusive clock should not go backwards");

        assert!(
            suspend_inclusive_elapsed.abs_diff(monotonic_elapsed) < Duration::from_millis(100),
            "suspend-inclusive: {suspend_inclusive_elapsed:?}, `Instant`: {monotonic_elapsed:?}"
        );
    }
}
