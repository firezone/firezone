use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll, Waker, ready};
use std::time::Instant;

/// A future that sleeps until a given instant.
///
/// The difference to [`tokio::time::Sleep`] is that it has a default state in which it always returns [`Poll::Pending`].
/// Similarly, once it resolves, it will go to sleep (pun intended) until it is reset, at which point any pending tasks will be woken.
#[derive(Default)]
pub struct Sleep {
    /// The inner sleep future. Boxed for convenience to make [`Sleep`] implement [`Unpin`].
    inner: Option<Pin<Box<tokio::time::Sleep>>>,
    waker: Option<Waker>,
}

impl Sleep {
    pub fn reset(self: Pin<&mut Self>, deadline: Instant) {
        let this = self.get_mut();
        let deadline = tokio::time::Instant::from_std(deadline);

        match this.inner.as_mut() {
            Some(sleep) if sleep.deadline() != deadline => sleep.as_mut().reset(deadline),
            Some(_) => (),
            None => {
                this.inner = Some(Box::pin(tokio::time::sleep_until(deadline)));

                if let Some(waker) = this.waker.take() {
                    waker.wake();
                }
            }
        }
    }
}

impl Future for Sleep {
    type Output = Instant;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let this = self.get_mut();

        if let Some(inner) = &mut this.inner {
            let deadline = inner.deadline();

            ready!(Pin::new(inner).poll(cx));

            this.inner = None;
            return Poll::Ready(deadline.into());
        }

        this.waker = Some(cx.waker().clone());

        Poll::Pending
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::FutureExt as _;
    use std::pin::pin;
    use std::time::Duration;

    #[test]
    fn default_sleep_returns_pending() {
        let sleep = pin!(Sleep::default());

        let poll = sleep.poll(&mut Context::from_waker(futures::task::noop_waker_ref()));

        assert!(poll.is_pending())
    }

    #[tokio::test]
    async fn finished_sleep_returns_pending() {
        let mut sleep = Sleep::default();
        Pin::new(&mut sleep).reset(Instant::now() + Duration::from_millis(100));

        tokio::time::sleep(Duration::from_millis(200)).await;

        let first_poll =
            sleep.poll_unpin(&mut Context::from_waker(futures::task::noop_waker_ref()));
        let second_poll =
            sleep.poll_unpin(&mut Context::from_waker(futures::task::noop_waker_ref()));

        assert!(first_poll.is_ready());
        assert!(second_poll.is_pending())
    }

    #[tokio::test]
    async fn does_not_crash_and_fires_immediately_when_reset_to_past() {
        let mut sleep = Sleep::default();
        Pin::new(&mut sleep).reset(Instant::now() - Duration::from_millis(100));

        sleep.await;
    }
}
