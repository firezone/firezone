use std::{
    pin::Pin,
    task::{Context, Poll, ready},
    time::{Duration, Instant},
};

use futures::FutureExt as _;

/// A dedicated timeout future that is always initialised and auto-advances by the given [`Duration`] as soon as it is ready.
///
/// Every deadline passed to [`Timeout::reset`] or [`Timeout::schedule`] is rounded **up**
/// to the next multiple of `granularity` measured from an epoch fixed at construction time.
/// This coalesces wakeups that fall within the same coarse tick, avoiding churn in the
/// underlying OS timer when many small resets arrive in rapid succession.
pub struct Timeout {
    default_advance: Duration,
    inner: Pin<Box<tokio::time::Sleep>>,
    /// Upper-bound imposed by [`Timeout::schedule`]. [`Timeout::reset`] will never move
    /// the deadline beyond this value while it is set.
    scheduled: Option<Instant>,
    /// The granularity of our timer.
    tick: Duration,
    created_at: Instant,
}

impl Timeout {
    pub fn new(default_advance: Duration, tick: Duration, now: Instant) -> Self {
        Self {
            default_advance,
            inner: Box::pin(tokio::time::sleep_until(
                tokio::time::Instant::from_std(now) + default_advance,
            )),
            scheduled: None,
            tick,
            created_at: now,
        }
    }

    pub fn poll_tick(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        ready!(self.inner.as_mut().poll_unpin(cx));

        // Clear the scheduled ceiling — it has been honoured by firing.
        self.scheduled = None;

        self.set_deadline(self.deadline() + self.default_advance);

        Poll::Ready(())
    }

    /// Moves the deadline to `deadline`, clamping it to the scheduled wakeup ceiling if one is set.
    pub fn reset(&mut self, deadline: Instant) {
        let coarse = self.round_up(deadline);

        let effective = match self.scheduled {
            Some(ceiling) => coarse.min(ceiling),
            None => coarse,
        };

        self.set_deadline(effective);
    }

    /// Sets an upper-bound on the deadline and immediately applies it.
    ///
    /// Subsequent calls to [`Timeout::reset`] will never push the deadline past `ceiling`.
    /// The ceiling is cleared once the timer fires via [`Timeout::poll_tick`].
    pub fn schedule(&mut self, ceiling: Instant) {
        self.scheduled = Some(match self.scheduled {
            // Keep the tightest ceiling if schedule() is called more than once.
            Some(existing) => ceiling.min(existing),
            None => ceiling,
        });

        // Apply the ceiling to the current deadline immediately.
        if self.deadline() > ceiling {
            self.set_deadline(ceiling);
        }
    }

    pub fn deadline(&self) -> Instant {
        self.inner.as_ref().deadline().into()
    }

    fn set_deadline(&mut self, deadline: Instant) {
        self.inner
            .as_mut()
            .reset(tokio::time::Instant::from_std(deadline));
    }

    fn round_up(&self, deadline: Instant) -> Instant {
        if self.tick.is_zero() {
            return deadline;
        }

        let offset = deadline.saturating_duration_since(self.created_at);
        let remainder_nanos = offset.as_nanos() % self.tick.as_nanos();

        if remainder_nanos == 0 {
            deadline
        } else {
            deadline + (self.tick - Duration::from_nanos(remainder_nanos as u64))
        }
    }
}

#[cfg(test)]
mod tests {
    use std::future::poll_fn;

    use super::*;

    const STEP: Duration = Duration::from_millis(50);

    #[tokio::test(start_paused = true)]
    async fn deadline_auto_resets_to_old_deadline_plus_advance_after_firing() {
        let now = Instant::now();
        let advance = Duration::from_secs(1);
        let mut timeout = Timeout::new(advance, STEP, now);

        let original_deadline = timeout.deadline();

        tokio::time::advance(advance).await;
        poll_fn(|cx| timeout.poll_tick(cx)).await;

        assert_eq!(timeout.deadline(), original_deadline + advance);
    }

    #[tokio::test]
    async fn reset_moves_deadline_freely_without_scheduled_ceiling() {
        let now = Instant::now();
        let mut timeout = Timeout::new(Duration::from_secs(10), STEP, now);

        timeout.reset(now + Duration::from_secs(5));
        assert_eq!(timeout.deadline(), now + Duration::from_secs(5));

        timeout.reset(now + Duration::from_millis(100));
        assert_eq!(timeout.deadline(), now + Duration::from_millis(100));
    }

    #[tokio::test]
    async fn reset_is_clamped_to_scheduled_ceiling() {
        let now = Instant::now();
        let mut timeout = Timeout::new(Duration::from_secs(10), STEP, now);
        let ceiling = now + Duration::from_secs(1);

        timeout.schedule(ceiling);
        timeout.reset(now + Duration::from_secs(5));

        assert_eq!(timeout.deadline(), ceiling);
    }

    #[tokio::test]
    async fn reset_can_shorten_below_scheduled_ceiling() {
        let now = Instant::now();
        let mut timeout = Timeout::new(Duration::from_secs(10), STEP, now);

        timeout.schedule(now + Duration::from_secs(1));
        timeout.reset(now + Duration::from_millis(100));

        assert_eq!(timeout.deadline(), now + Duration::from_millis(100));
    }

    #[tokio::test]
    async fn schedule_clamps_existing_deadline_and_keeps_tightest_on_repeated_calls() {
        let now = Instant::now();
        let mut timeout = Timeout::new(Duration::from_secs(10), STEP, now);

        timeout.schedule(now + Duration::from_secs(2));
        assert_eq!(
            timeout.deadline(),
            now + Duration::from_secs(2),
            "first schedule should pull deadline in from 10s to 2s"
        );

        timeout.schedule(now + Duration::from_secs(1));
        assert_eq!(
            timeout.deadline(),
            now + Duration::from_secs(1),
            "tighter ceiling should win"
        );

        timeout.schedule(now + Duration::from_secs(5));
        assert_eq!(
            timeout.deadline(),
            now + Duration::from_secs(1),
            "looser ceiling should be ignored"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn ceiling_is_cleared_after_firing_allowing_reset_to_move_deadline_freely() {
        let now = Instant::now();
        let mut timeout = Timeout::new(Duration::from_secs(10), STEP, now);

        timeout.schedule(now + Duration::from_secs(1));

        tokio::time::advance(Duration::from_secs(1)).await;
        poll_fn(|cx| timeout.poll_tick(cx)).await;

        let far = now + Duration::from_secs(20);
        timeout.reset(far);

        assert_eq!(
            timeout.deadline(),
            far,
            "ceiling should be cleared after firing, allowing reset to move deadline freely"
        );
    }

    #[tokio::test]
    async fn reset_rounds_up_to_granularity_boundary() {
        let now = Instant::now();
        let mut timeout = Timeout::new(Duration::from_secs(10), STEP, now);

        timeout.reset(now + Duration::from_millis(10));
        assert_eq!(
            timeout.deadline(),
            now + Duration::from_millis(50),
            "10ms past epoch should round up to the 50ms boundary"
        );

        timeout.reset(now + Duration::from_millis(50));
        assert_eq!(
            timeout.deadline(),
            now + Duration::from_millis(50),
            "deadline exactly on a boundary should be unchanged"
        );

        timeout.reset(now + Duration::from_millis(51));
        assert_eq!(
            timeout.deadline(),
            now + Duration::from_millis(100),
            "51ms past epoch should round up to the 100ms boundary"
        );
    }

    #[tokio::test]
    async fn schedule_stores_ceiling_without_rounding() {
        let now = Instant::now();
        let mut timeout = Timeout::new(Duration::from_secs(10), STEP, now);

        let ceiling = now + Duration::from_millis(30);
        timeout.schedule(ceiling);

        assert_eq!(
            timeout.deadline(),
            ceiling,
            "schedule should store and apply the ceiling as-is, without rounding"
        );
    }

    #[tokio::test]
    async fn reset_rounded_up_value_is_still_clamped_by_ceiling() {
        let now = Instant::now();
        let mut timeout = Timeout::new(Duration::from_secs(10), STEP, now);

        timeout.schedule(now + Duration::from_millis(30));
        timeout.reset(now + Duration::from_millis(10));

        assert_eq!(
            timeout.deadline(),
            now + Duration::from_millis(30),
            "10ms rounds up to 50ms but ceiling is 30ms, so ceiling should win"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn auto_advance_after_fire_is_not_rounded() {
        let now = Instant::now();
        let advance = Duration::from_secs(1);
        let mut timeout = Timeout::new(advance, STEP, now);

        let original_deadline = timeout.deadline();

        tokio::time::advance(advance).await;
        poll_fn(|cx| timeout.poll_tick(cx)).await;

        assert_eq!(
            timeout.deadline(),
            original_deadline + advance,
            "post-fire advance should be applied exactly, without rounding"
        );
    }
}
