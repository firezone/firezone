use std::{
    pin::Pin,
    task::{Context, Poll, ready},
    time::{Duration, Instant},
};

use futures::FutureExt as _;

/// A dedicated timeout future that is always initialised and auto-advances by the given [`Duration`] as soon as it is ready.
pub struct Timeout {
    default_advance: Duration,
    inner: Pin<Box<tokio::time::Sleep>>,
}

impl Timeout {
    pub fn new(default_advance: Duration) -> Self {
        Self {
            default_advance,
            inner: Box::pin(tokio::time::sleep(default_advance)),
        }
    }

    pub fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        ready!(self.inner.as_mut().poll_unpin(cx));

        self.reset(self.deadline() + self.default_advance);

        Poll::Ready(())
    }

    pub fn reset(&mut self, deadline: Instant) {
        self.inner
            .as_mut()
            .reset(tokio::time::Instant::from_std(deadline));
    }

    pub fn deadline(&self) -> Instant {
        self.inner.as_ref().deadline().into()
    }
}

#[cfg(test)]
mod tests {
    use std::future::poll_fn;

    use super::*;

    #[tokio::test]
    async fn deadline_auto_resets_to_old_deadline_plus_advance_after_firing() {
        let advance = Duration::from_secs(1);
        let mut timeout = Timeout::new(advance);

        let original_deadline = timeout.deadline();

        poll_fn(|cx| timeout.poll_ready(cx)).await;

        assert_eq!(
            timeout.deadline(),
            original_deadline + advance,
            "deadline should be old_deadline + default_advance, not based on wall-clock now"
        );
    }
}
