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
    source: Box<dyn Fn() -> Duration + Send>,
    instant_at_start: Instant,
    os_clock_at_start: Duration,
    armed_alarm: Option<ArmedAlarm>,
    timer: Option<Pin<Box<tokio::time::Sleep>>>,
}

impl Default for Clock {
    fn default() -> Self {
        Self::new()
    }
}

impl Clock {
    pub fn new() -> Self {
        Self::with_source(suspend_inclusive_now)
    }

    /// Creates a clock driven by `source`, which returns the time since an
    /// arbitrary, fixed point, including time spent suspended.
    fn with_source(source: impl Fn() -> Duration + Send + 'static) -> Self {
        Self {
            instant_at_start: Instant::now(),
            os_clock_at_start: source(),
            source: Box::new(source),
            armed_alarm: None,
            timer: None,
        }
    }

    pub fn now(&self) -> Instant {
        let elapsed_since_start = (self.source)().saturating_sub(self.os_clock_at_start);

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
        let Some(armed_alarm) = self.armed_alarm.as_ref() else {
            return Poll::Pending;
        };
        let now = self.now();

        let late_by = match *armed_alarm {
            ArmedAlarm::Immediate => Duration::ZERO,
            ArmedAlarm::Scheduled { deadline } if now >= deadline => now.duration_since(deadline),
            ArmedAlarm::Scheduled { deadline } => {
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
    use std::{
        sync::{
            Arc, Mutex,
            atomic::{AtomicBool, Ordering},
        },
        task::{Context, Poll, Wake, Waker},
        time::{Duration, Instant},
    };

    use super::{Alarm, Clock};

    /// Simulates the OS clock; advancing it without advancing Tokio's time models a suspend.
    #[derive(Clone, Default)]
    struct FakeTime(Arc<Mutex<Duration>>);

    impl FakeTime {
        fn now(&self) -> Duration {
            *self.0.lock().expect("not poisoned")
        }

        fn advance(&self, elapsed: Duration) {
            *self.0.lock().expect("not poisoned") += elapsed;
        }
    }

    fn fake_clock() -> (Clock, FakeTime) {
        let time = FakeTime::default();
        let source = time.clone();

        (Clock::with_source(move || source.now()), time)
    }

    #[test]
    fn includes_each_short_suspend_in_the_next_sample() {
        let (clock, time) = fake_clock();
        let start = clock.now();

        for sample in 1..=3 {
            time.advance(Duration::from_millis(400));
            assert_eq!(clock.now(), start + Duration::from_millis(400 * sample));
        }
    }

    #[tokio::test(start_paused = true)]
    async fn delivers_overdue_alarm_even_if_tokio_has_not_fired() {
        let (mut clock, time) = fake_clock();
        let mut cx = Context::from_waker(Waker::noop());
        let start = clock.now();
        clock.set_alarm(&mut cx, Some(start + Duration::from_secs(5)));

        time.advance(Duration::from_secs(1));
        assert_eq!(clock.poll_alarm(&mut cx), Poll::Pending);

        time.advance(Duration::from_secs(44));
        assert_eq!(
            clock.poll_alarm(&mut cx),
            Poll::Ready(Alarm {
                now: start + Duration::from_secs(45),
                late_by: Duration::from_secs(40),
            }),
        );
        assert_eq!(clock.poll_alarm(&mut cx), Poll::Pending);
    }

    #[tokio::test(start_paused = true)]
    async fn already_due_alarm_reports_no_lateness() {
        let (mut clock, time) = fake_clock();
        let mut cx = Context::from_waker(Waker::noop());
        let start = clock.now();
        clock.set_alarm(&mut cx, Some(start));

        time.advance(Duration::from_secs(60));
        assert_eq!(
            clock.poll_alarm(&mut cx),
            Poll::Ready(Alarm {
                now: start + Duration::from_secs(60),
                late_by: Duration::ZERO,
            })
        );
    }

    #[tokio::test(start_paused = true)]
    async fn cancels_armed_alarm() {
        let (mut clock, time) = fake_clock();
        let mut cx = Context::from_waker(Waker::noop());
        let start = clock.now();
        clock.set_alarm(&mut cx, Some(start + Duration::from_secs(5)));
        clock.set_alarm(&mut cx, None);

        time.advance(Duration::from_secs(45));
        assert_eq!(clock.poll_alarm(&mut cx), Poll::Pending);
    }

    #[derive(Default)]
    struct WakeFlag(AtomicBool);

    impl Wake for WakeFlag {
        fn wake(self: Arc<Self>) {
            self.0.store(true, Ordering::Relaxed);
        }
    }

    #[tokio::test(start_paused = true)]
    async fn re_registers_timer_if_it_wakes_before_the_deadline() {
        let (mut clock, time) = fake_clock();
        let wake_flag = Arc::new(WakeFlag::default());
        let waker = Waker::from(wake_flag.clone());
        let mut cx = Context::from_waker(&waker);
        let deadline = clock.now() + Duration::from_secs(5);
        clock.set_alarm(&mut cx, Some(deadline));

        // Tokio's timer fires while the OS clock has only advanced 3s.
        tokio::time::advance(Duration::from_secs(5)).await;
        time.advance(Duration::from_secs(3));
        assert!(wake_flag.0.swap(false, Ordering::Relaxed));
        assert_eq!(clock.poll_alarm(&mut cx), Poll::Pending);

        // The re-armed timer wakes us for the remaining 2s.
        tokio::time::advance(Duration::from_secs(2)).await;
        time.advance(Duration::from_secs(2));
        assert!(wake_flag.0.load(Ordering::Relaxed));
        assert_eq!(
            clock.poll_alarm(&mut cx),
            Poll::Ready(Alarm {
                now: deadline,
                late_by: Duration::ZERO
            })
        );
    }

    #[test]
    fn suspend_inclusive_clock_advances_with_instant_while_awake() {
        let clock = Clock::new();
        let monotonic_start = Instant::now();
        let suspend_inclusive_start = clock.now();

        std::thread::sleep(Duration::from_millis(200));

        let monotonic_elapsed = monotonic_start.elapsed();
        let suspend_inclusive_elapsed = clock.now().duration_since(suspend_inclusive_start);

        assert!(
            suspend_inclusive_elapsed.abs_diff(monotonic_elapsed) < Duration::from_millis(100),
            "suspend-inclusive: {suspend_inclusive_elapsed:?}, `Instant`: {monotonic_elapsed:?}"
        );
    }
}
