use crate::Event;
use connlib_shared::messages::{ClientId, GatewayId};
use futures::channel::mpsc::Receiver;
use futures_bounded::{PushError, StreamMap};
use std::collections::HashMap;
use std::fmt;
use std::task::{ready, Context, Poll};
use std::time::Duration;
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;

/// Dedicated trait for abstracting over the different ICE states.
///
/// By design, this trait does not allow any operations apart from advancing via [`RoleState::poll_next_event`].
/// The state should only be modified when the concrete type is known, e.g. [`ClientState`] or [`GatewayState`].
pub trait RoleState: Default + Send + 'static {
    type Id: fmt::Debug;

    fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Event<Self::Id>>;
}

/// For how long we will attempt to gather ICE candidates before aborting.
///
/// Chosen arbitrarily.
/// Very likely, the actual WebRTC connection will timeout before this.
/// This timeout is just here to eventually clean-up tasks if they are somehow broken.
const ICE_GATHERING_TIMEOUT_SECONDS: u64 = 5 * 60;

/// How many concurrent ICE gathering attempts we are allow.
///
/// Chosen arbitrarily.
const MAX_CONCURRENT_ICE_GATHERING: usize = 100;

/// [`Tunnel`](crate::Tunnel) state specific to clients.
pub struct ClientState {
    active_candidate_receivers: StreamMap<GatewayId, RTCIceCandidateInit>,
    /// We split the receivers of ICE candidates into two phases because we only want to start sending them once we've received an SDP from the gateway.
    waiting_for_sdp_from_gatway: HashMap<GatewayId, Receiver<RTCIceCandidateInit>>,
}

impl ClientState {
    pub fn add_waiting_ice_receiver(
        &mut self,
        id: GatewayId,
        receiver: Receiver<RTCIceCandidateInit>,
    ) {
        self.waiting_for_sdp_from_gatway.insert(id, receiver);
    }

    pub fn activate_ice_candidate_receiver(&mut self, id: GatewayId) {
        let Some(receiver) = self.waiting_for_sdp_from_gatway.remove(&id) else {
            return;
        };

        match self.active_candidate_receivers.try_push(id, receiver) {
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

impl Default for ClientState {
    fn default() -> Self {
        Self {
            active_candidate_receivers: StreamMap::new(
                Duration::from_secs(ICE_GATHERING_TIMEOUT_SECONDS),
                MAX_CONCURRENT_ICE_GATHERING,
            ),
            waiting_for_sdp_from_gatway: Default::default(),
        }
    }
}

impl RoleState for ClientState {
    type Id = GatewayId;

    fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Event<Self::Id>> {
        loop {
            match ready!(self.active_candidate_receivers.poll_next_unpin(cx)) {
                (conn_id, Some(Ok(c))) => {
                    return Poll::Ready(Event::SignalIceCandidate {
                        conn_id,
                        candidate: c,
                    })
                }
                (id, Some(Err(e))) => {
                    tracing::warn!(gateway_id = %id, "ICE gathering timed out: {e}")
                }
                (_, None) => {}
            }
        }
    }
}

/// [`Tunnel`](crate::Tunnel) state specific to gateways.
pub struct GatewayState {
    candidate_receivers: StreamMap<ClientId, RTCIceCandidateInit>,
}

impl GatewayState {
    pub fn add_new_ice_receiver(&mut self, id: ClientId, receiver: Receiver<RTCIceCandidateInit>) {
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
                    })
                }
                (id, Some(Err(e))) => {
                    tracing::warn!(gateway_id = %id, "ICE gathering timed out: {e}")
                }
                (_, None) => {}
            }
        }
    }
}
