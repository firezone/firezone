use crate::device_channel::Device;
use crate::{
    Event, RoleState, Tunnel, ICE_GATHERING_TIMEOUT_SECONDS, MAX_CONCURRENT_ICE_GATHERING,
};
use connlib_shared::messages::{ClientId, Interface as InterfaceConfig};
use connlib_shared::Callbacks;
use futures::channel::mpsc::Receiver;
use futures_bounded::{PushError, StreamMap};
use std::sync::Arc;
use std::task::{ready, Context, Poll};
use std::time::Duration;
use webrtc::ice_transport::ice_candidate::RTCIceCandidate;

impl<CB> Tunnel<CB, GatewayState>
where
    CB: Callbacks + 'static,
{
    /// Sets the interface configuration and starts background tasks.
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn set_interface(&self, config: &InterfaceConfig) -> connlib_shared::Result<()> {
        let device = Arc::new(Device::new(config, self.callbacks()).await?);

        self.device.store(Some(device.clone()));
        self.no_device_waker.wake();

        tracing::debug!("background_loop_started");

        Ok(())
    }

    /// Clean up a connection to a resource.
    // FIXME: this cleanup connection is wrong!
    pub fn cleanup_connection(&self, id: ClientId) {
        self.peer_connections.lock().remove(&id);
    }
}

/// [`Tunnel`] state specific to gateways.
pub struct GatewayState {
    pub candidate_receivers: StreamMap<ClientId, RTCIceCandidate>,
}

impl GatewayState {
    pub fn add_new_ice_receiver(&mut self, id: ClientId, receiver: Receiver<RTCIceCandidate>) {
        match self.candidate_receivers.try_push(id, receiver) {
            Ok(()) => {}
            Err(PushError::BeyondCapacity(_)) => {
                tracing::warn!("Too many active ICE candidate receivers at a time")
            }
            Err(PushError::Replaced(_)) => {
                tracing::warn!(%id, "Replaced old ICE candidate receiver with new one")
            }
        }
    }
}

impl Default for GatewayState {
    fn default() -> Self {
        Self {
            candidate_receivers: StreamMap::new(
                Duration::from_secs(ICE_GATHERING_TIMEOUT_SECONDS),
                MAX_CONCURRENT_ICE_GATHERING,
            ),
        }
    }
}

impl RoleState for GatewayState {
    type Id = ClientId;

    fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Event<Self::Id>> {
        loop {
            match ready!(self.candidate_receivers.poll_next_unpin(cx)) {
                (conn_id, Some(Ok(c))) => {
                    return Poll::Ready(Event::SignalIceCandidate {
                        conn_id,
                        candidate: c,
                    });
                }
                (id, Some(Err(e))) => {
                    tracing::warn!(gateway_id = %id, "ICE gathering timed out: {e}")
                }
                (_, None) => {}
            }
        }
    }
}
