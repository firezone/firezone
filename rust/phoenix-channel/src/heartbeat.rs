use crate::{EgressControlMessage, OutboundRequestId};
use std::{
    pin::Pin,
    sync::{atomic::AtomicU64, Arc},
    task::{ready, Context, Poll},
    time::Duration,
};
use tokio::time::MissedTickBehavior;

pub const INTERVAL: Duration = Duration::from_secs(30);

pub struct Heartbeat {
    /// When to send the next heartbeat.
    interval: Pin<Box<tokio::time::Interval>>,
    /// The ID of our heatbeat if we haven't received a reply yet.
    id: Option<OutboundRequestId>,

    next_request_id: Arc<AtomicU64>,
}

impl Heartbeat {
    pub fn new(interval: Duration, next_request_id: Arc<AtomicU64>) -> Self {
        let mut interval = tokio::time::interval(interval);
        interval.set_missed_tick_behavior(MissedTickBehavior::Skip);

        Self {
            interval: Box::pin(interval),
            id: Default::default(),
            next_request_id,
        }
    }

    pub fn maybe_handle_reply(&mut self, id: OutboundRequestId) -> bool {
        match self.id.as_ref() {
            Some(pending) if pending == &id => {
                self.id = None;

                true
            }
            _ => false,
        }
    }

    pub fn poll(
        &mut self,
        cx: &mut Context,
    ) -> Poll<Result<(OutboundRequestId, EgressControlMessage<()>), MissedLastHeartbeat>> {
        ready!(self.interval.poll_tick(cx));

        if self.id.is_some() {
            self.id = None;
            return Poll::Ready(Err(MissedLastHeartbeat {}));
        }

        let next_id = self
            .next_request_id
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);

        Poll::Ready(Ok((
            OutboundRequestId(next_id),
            EgressControlMessage::Heartbeat(crate::Empty {}),
        )))
    }
}

#[derive(Debug)]
pub struct MissedLastHeartbeat {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{future::poll_fn, time::Instant};

    #[tokio::test]
    async fn returns_heartbeat_after_interval() {
        let mut heartbeat = Heartbeat::new(Duration::from_millis(30), Arc::new(AtomicU64::new(0)));
        let _ = poll_fn(|cx| heartbeat.poll(cx)).await; // Tick once at startup.

        let start = Instant::now();

        let result = poll_fn(|cx| heartbeat.poll(cx)).await;

        let elapsed = start.elapsed();

        assert!(result.is_ok());
        assert!(elapsed >= Duration::from_millis(10));
    }

    #[tokio::test]
    async fn fails_if_response_is_not_provided_before_next_poll() {
        let mut heartbeat = Heartbeat::new(Duration::from_millis(10), Arc::new(AtomicU64::new(0)));

        let _ = poll_fn(|cx| heartbeat.poll(cx)).await;

        let result = poll_fn(|cx| heartbeat.poll(cx)).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn ignores_other_ids() {
        let mut heartbeat = Heartbeat::new(Duration::from_millis(10), Arc::new(AtomicU64::new(0)));

        let _ = poll_fn(|cx| heartbeat.poll(cx)).await;
        heartbeat.maybe_handle_reply(OutboundRequestId::for_test(2));

        let result = poll_fn(|cx| heartbeat.poll(cx)).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn succeeds_if_response_is_provided_inbetween_polls() {
        let mut heartbeat = Heartbeat::new(Duration::from_millis(10), Arc::new(AtomicU64::new(0)));

        let (id, _) = poll_fn(|cx| heartbeat.poll(cx)).await.unwrap();
        heartbeat.maybe_handle_reply(id);

        let result = poll_fn(|cx| heartbeat.poll(cx)).await;
        assert!(result.is_ok());
    }
}
