use crate::OutboundRequestId;
use futures::FutureExt;
use std::{
    pin::Pin,
    sync::{atomic::AtomicU64, Arc},
    task::{ready, Context, Poll},
    time::Duration,
};
use tokio::time::MissedTickBehavior;

pub const INTERVAL: Duration = Duration::from_secs(30);
pub const TIMEOUT: Duration = Duration::from_secs(5);

pub struct Heartbeat {
    /// When to send the next heartbeat.
    interval: Pin<Box<tokio::time::Interval>>,

    timeout: Duration,

    /// The ID of our heatbeat if we haven't received a reply yet.
    pending: Option<(OutboundRequestId, Pin<Box<tokio::time::Sleep>>)>,

    next_request_id: Arc<AtomicU64>,
}

impl Heartbeat {
    pub fn new(interval: Duration, timeout: Duration, next_request_id: Arc<AtomicU64>) -> Self {
        let mut interval = tokio::time::interval(interval);
        interval.set_missed_tick_behavior(MissedTickBehavior::Skip);

        Self {
            interval: Box::pin(interval),
            pending: Default::default(),
            next_request_id,
            timeout,
        }
    }

    pub fn maybe_handle_reply(&mut self, id: OutboundRequestId) -> bool {
        match self.pending.as_ref() {
            Some((pending, timeout)) if pending == &id && !timeout.is_elapsed() => {
                self.pending = None;

                true
            }
            _ => false,
        }
    }

    pub fn reset(&mut self) {
        self.pending = None;
        self.interval.reset();
    }

    pub fn poll(
        &mut self,
        cx: &mut Context,
    ) -> Poll<Result<OutboundRequestId, MissedLastHeartbeat>> {
        if let Some((_, timeout)) = self.pending.as_mut() {
            ready!(timeout.poll_unpin(cx));
            tracing::trace!("Timeout waiting for heartbeat response");
            self.pending = None;
            return Poll::Ready(Err(MissedLastHeartbeat {}));
        }

        ready!(self.interval.poll_tick(cx));

        tracing::trace!("Time to send a new heartbeat");

        let next_id = self
            .next_request_id
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        self.pending = Some((
            OutboundRequestId(next_id),
            Box::pin(tokio::time::sleep(self.timeout)),
        ));

        Poll::Ready(Ok(OutboundRequestId(next_id)))
    }
}

#[derive(Debug)]
pub struct MissedLastHeartbeat {}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::future::Either;
    use std::{future::poll_fn, time::Instant};

    const INTERVAL: Duration = Duration::from_millis(180);
    // Windows won't allow Tokio to schedule any timer shorter than about 15 ms.
    // If we only set 15 here, sometimes the timeout and heartbeat may both fall on a 30-ms tick, so it has to be longer.
    const TIMEOUT: Duration = Duration::from_millis(30);

    #[tokio::test]
    async fn returns_heartbeat_after_interval() {
        let start = Instant::now();
        let mut heartbeat = Heartbeat::new(INTERVAL, TIMEOUT, Arc::new(AtomicU64::new(0)));
        let id = poll_fn(|cx| heartbeat.poll(cx)).await.unwrap(); // Tick once at startup.
        heartbeat.maybe_handle_reply(id);

        let result = poll_fn(|cx| heartbeat.poll(cx)).await;

        let elapsed = start.elapsed();

        assert!(result.is_ok());
        assert!(elapsed >= INTERVAL, "Only suspended for {elapsed:?}");
    }

    #[tokio::test]
    async fn fails_if_response_is_not_provided_before_next_poll() {
        let mut heartbeat = Heartbeat::new(INTERVAL, TIMEOUT, Arc::new(AtomicU64::new(0)));

        let _ = poll_fn(|cx| heartbeat.poll(cx)).await;

        let result = poll_fn(|cx| heartbeat.poll(cx)).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn ignores_other_ids() {
        let mut heartbeat = Heartbeat::new(INTERVAL, TIMEOUT, Arc::new(AtomicU64::new(0)));

        let _ = poll_fn(|cx| heartbeat.poll(cx)).await;
        heartbeat.maybe_handle_reply(OutboundRequestId::for_test(2));

        let result = poll_fn(|cx| heartbeat.poll(cx)).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn succeeds_if_response_is_provided_inbetween_polls() {
        let mut heartbeat = Heartbeat::new(INTERVAL, TIMEOUT, Arc::new(AtomicU64::new(0)));

        let id = poll_fn(|cx| heartbeat.poll(cx)).await.unwrap();
        heartbeat.maybe_handle_reply(id);

        let result = poll_fn(|cx| heartbeat.poll(cx)).await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn fails_if_not_provided_within_timeout() {
        let _guard = firezone_logging::test("trace");

        let mut heartbeat = Heartbeat::new(INTERVAL, TIMEOUT, Arc::new(AtomicU64::new(0)));

        let id = poll_fn(|cx| heartbeat.poll(cx)).await.unwrap();

        let select = futures::future::select(
            tokio::time::sleep(TIMEOUT * 2).boxed(),
            poll_fn(|cx| heartbeat.poll(cx)),
        )
        .await;

        match select {
            Either::Left(((), _)) => panic!("timeout should not resolve"),
            Either::Right((Ok(_), _)) => panic!("heartbeat should fail and not issue new ID"),
            Either::Right((Err(_), _)) => {}
        }

        let handled = heartbeat.maybe_handle_reply(id);
        assert!(!handled);
    }
}
