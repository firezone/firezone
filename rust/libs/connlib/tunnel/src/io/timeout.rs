use std::{
    pin::Pin,
    task::{Context, Poll, ready},
    time::{Duration, Instant},
};

use futures::FutureExt as _;

/// A dedicated timeout future that is always initialised and auto-advances by the given [`Duration`] as soon as it is ready.
///
/// There are two ways to set the deadline:
///
/// - [`Timeout::reset`]: moves the deadline to an arbitrary point in time.
///   If a scheduled wakeup ceiling has been set via [`Timeout::schedule`], the effective
///   deadline is clamped to that ceiling so a scheduled wakeup is never accidentally postponed.
///
/// - [`Timeout::schedule`]: records an upper-bound ("scheduled wakeup") and immediately
///   clamps the current deadline to it.  The ceiling is cleared once the timer fires.
pub struct Timeout {
    default_advance: Duration,
    inner: Pin<Box<tokio::time::Sleep>>,
    /// Upper-bound imposed by [`Timeout::schedule`]. [`Timeout::reset`] will never move
    /// the deadline beyond this value while it is set.
    scheduled: Option<Instant>,
}

impl Timeout {
    pub fn new(default_advance: Duration) -> Self {
        Self {
            default_advance,
            inner: Box::pin(tokio::time::sleep(default_advance)),
            scheduled: None,
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
        let effective = match self.scheduled {
            Some(ceiling) => deadline.min(ceiling),
            None => deadline,
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
}

#[cfg(test)]
mod tests {
    use std::future::poll_fn;

    use super::*;

    #[tokio::test(start_paused = true)]
    async fn deadline_auto_resets_to_old_deadline_plus_advance_after_firing() {
        let advance = Duration::from_secs(1);
        let mut timeout = Timeout::new(advance);

        let original_deadline = timeout.deadline();

        tokio::time::advance(advance).await;
        poll_fn(|cx| timeout.poll_tick(cx)).await;

        assert_eq!(timeout.deadline(), original_deadline + advance);
    }

    #[tokio::test]
    async fn reset_moves_deadline_freely_without_scheduled_ceiling() {
        let mut timeout = Timeout::new(Duration::from_secs(10));
        let now = Instant::now();

        timeout.reset(now + Duration::from_secs(5));
        assert_eq!(timeout.deadline(), now + Duration::from_secs(5));

        timeout.reset(now + Duration::from_millis(100));
        assert_eq!(timeout.deadline(), now + Duration::from_millis(100));
    }

    #[tokio::test]
    async fn reset_is_clamped_to_scheduled_ceiling() {
        let mut timeout = Timeout::new(Duration::from_secs(10));
        let now = Instant::now();
        let ceiling = now + Duration::from_secs(1);

        timeout.schedule(ceiling);
        timeout.reset(now + Duration::from_secs(5));

        assert_eq!(timeout.deadline(), ceiling);
    }

    #[tokio::test]
    async fn reset_can_shorten_below_scheduled_ceiling() {
        let mut timeout = Timeout::new(Duration::from_secs(10));
        let now = Instant::now();

        timeout.schedule(now + Duration::from_secs(1));
        timeout.reset(now + Duration::from_millis(100));

        assert_eq!(timeout.deadline(), now + Duration::from_millis(100));
    }

    #[tokio::test]
    async fn schedule_clamps_existing_deadline_and_keeps_tightest_on_repeated_calls() {
        let mut timeout = Timeout::new(Duration::from_secs(10));
        let now = Instant::now();

        // First schedule pulls the deadline in from 10s to 2s.
        timeout.schedule(now + Duration::from_secs(2));
        assert_eq!(timeout.deadline(), now + Duration::from_secs(2));

        // A tighter ceiling wins.
        timeout.schedule(now + Duration::from_secs(1));
        assert_eq!(timeout.deadline(), now + Duration::from_secs(1));

        // A looser ceiling is ignored.
        timeout.schedule(now + Duration::from_secs(5));
        assert_eq!(timeout.deadline(), now + Duration::from_secs(1));
    }

    #[tokio::test(start_paused = true)]
    async fn ceiling_is_cleared_after_firing_allowing_reset_to_move_deadline_freely() {
        let mut timeout = Timeout::new(Duration::from_secs(10));
        let now = Instant::now();

        timeout.schedule(now + Duration::from_secs(1));

        tokio::time::advance(Duration::from_secs(1)).await;
        poll_fn(|cx| timeout.poll_tick(cx)).await;

        // Ceiling is gone — reset should now move the deadline freely past the old ceiling.
        let far = Instant::now() + Duration::from_secs(20);
        timeout.reset(far);

        assert_eq!(timeout.deadline(), far);
    }
}
