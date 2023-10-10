use crate::PollNextIceCandidate;
use connlib_shared::messages::{ClientId, GatewayId};
use futures::channel::mpsc::Receiver;
use futures_bounded::{PushError, StreamMap};
use std::collections::HashMap;
use std::task::{ready, Context, Poll};
use std::time::Duration;
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;

/// The [`Tunnel`]s ICE state on the client.
///
/// We split the receivers of ICE candidates into two phases because we only want to start sending them once we've received an SDP from the gateway.
pub struct ClientIceState {
    active_candidate_receivers: StreamMap<GatewayId, RTCIceCandidateInit>,
    waiting_for_sdp_from_gatway: HashMap<GatewayId, Receiver<RTCIceCandidateInit>>,
}

impl ClientIceState {
    pub fn add_waiting_receiver(&mut self, id: GatewayId, receiver: Receiver<RTCIceCandidateInit>) {
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

impl Default for ClientIceState {
    fn default() -> Self {
        Self {
            active_candidate_receivers: StreamMap::new(Duration::from_secs(5 * 60), 100),
            waiting_for_sdp_from_gatway: Default::default(),
        }
    }
}

impl PollNextIceCandidate for ClientIceState {
    type Id = GatewayId;

    fn poll_next_ice_candidate(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<(Self::Id, RTCIceCandidateInit)> {
        loop {
            match ready!(self.active_candidate_receivers.poll_next_unpin(cx)) {
                (id, Some(Ok(c))) => return Poll::Ready((id, c)),
                (id, Some(Err(e))) => {
                    tracing::warn!(gateway_id = %id, "ICE gathering timed out: {e}")
                }
                (_, None) => {}
            }
        }
    }
}

pub struct GatewayIceState {
    candidate_receivers: StreamMap<ClientId, RTCIceCandidateInit>,
}

impl GatewayIceState {
    pub fn add_new_receiver(&mut self, id: ClientId, receiver: Receiver<RTCIceCandidateInit>) {
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

impl Default for GatewayIceState {
    fn default() -> Self {
        Self {
            candidate_receivers: StreamMap::new(Duration::from_secs(5 * 60), 100),
        }
    }
}

impl PollNextIceCandidate for GatewayIceState {
    type Id = ClientId;

    fn poll_next_ice_candidate(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<(Self::Id, RTCIceCandidateInit)> {
        loop {
            match ready!(self.candidate_receivers.poll_next_unpin(cx)) {
                (id, Some(Ok(c))) => return Poll::Ready((id, c)),
                (id, Some(Err(e))) => {
                    tracing::warn!(gateway_id = %id, "ICE gathering timed out: {e}")
                }
                (_, None) => {}
            }
        }
    }
}
