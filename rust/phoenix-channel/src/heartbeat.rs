use crate::{EgressControlMessage, OutboundRequestId};
use std::{
    pin::Pin,
    task::{ready, Context, Poll},
    time::Duration,
};
use tokio::time::MissedTickBehavior;

const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);

pub struct Heartbeat {
    /// When to send the next heartbeat.
    interval: Pin<Box<tokio::time::Interval>>,
    /// The ID of our heatbeat if we haven't received a reply yet.
    id: Option<OutboundRequestId>,
}

impl Heartbeat {
    pub fn maybe_handle_reply(&mut self, id: OutboundRequestId) -> bool {
        let Some(pending) = self.id.take() else {
            return false;
        };

        if pending != id {
            return false;
        }

        self.id = None;
        true
    }

    pub fn set_id(&mut self, id: OutboundRequestId) {
        self.id = Some(id);
    }

    pub fn poll(
        &mut self,
        cx: &mut Context,
    ) -> Poll<Result<EgressControlMessage<()>, MissedLastHeartbeat>> {
        ready!(self.interval.poll_tick(cx));

        if self.id.is_some() {
            self.id = None;
            return Poll::Ready(Err(MissedLastHeartbeat {}));
        }

        Poll::Ready(Ok(EgressControlMessage::Heartbeat(crate::Empty {})))
    }

    fn new(interval: Duration) -> Self {
        let mut interval = tokio::time::interval(interval);
        interval.set_missed_tick_behavior(MissedTickBehavior::Skip);

        Self {
            interval: Box::pin(interval),
            id: Default::default(),
        }
    }
}

#[derive(Debug)]
pub struct MissedLastHeartbeat {}

impl Default for Heartbeat {
    fn default() -> Self {
        Self::new(HEARTBEAT_INTERVAL)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{future::poll_fn, time::Instant};

    #[tokio::test]
    async fn returns_heartbeat_after_interval() {
        let mut heartbeat = Heartbeat::new(Duration::from_millis(30));
        let _ = poll_fn(|cx| heartbeat.poll(cx)).await; // Tick once at startup.

        let start = Instant::now();

        let result = poll_fn(|cx| heartbeat.poll(cx)).await;

        let elapsed = start.elapsed();

        assert!(result.is_ok());
        assert!(elapsed >= Duration::from_millis(10));
    }

    #[tokio::test]
    async fn fails_if_response_is_not_provided_before_next_poll() {
        let mut heartbeat = Heartbeat::new(Duration::from_millis(10));

        let _ = poll_fn(|cx| heartbeat.poll(cx)).await;
        heartbeat.set_id(OutboundRequestId::new(1));

        let result = poll_fn(|cx| heartbeat.poll(cx)).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn succeeds_if_response_is_provided_inbetween_polls() {
        let mut heartbeat = Heartbeat::new(Duration::from_millis(10));

        let _ = poll_fn(|cx| heartbeat.poll(cx)).await;
        heartbeat.set_id(OutboundRequestId::new(1));
        heartbeat.maybe_handle_reply(OutboundRequestId::new(1));

        let result = poll_fn(|cx| heartbeat.poll(cx)).await;
        assert!(result.is_ok());
    }
}
