use crate::IceState;
use connlib_shared::messages::{ClientId, GatewayId};
use futures::channel::mpsc::Receiver;
use futures_bounded::StreamMap;
use std::collections::HashMap;
use std::task::{ready, Context, Poll};
use std::time::Duration;
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;

pub struct ClientIceState {
    active_ice_candidate_receivers: StreamMap<GatewayId, RTCIceCandidateInit>,
    waiting_ice_candidate_receivers: HashMap<GatewayId, Receiver<RTCIceCandidateInit>>,
}

impl ClientIceState {
    pub fn activate_ice_candidate_receiver(&mut self, id: GatewayId) {
        let Some(receiver) = self.waiting_ice_candidate_receivers.remove(&id) else {
            return;
        };

        let _ = self.active_ice_candidate_receivers.try_push(id, receiver);
    }
}

impl Default for ClientIceState {
    fn default() -> Self {
        Self {
            active_ice_candidate_receivers: StreamMap::new(Duration::from_secs(5 * 60), 100),
            waiting_ice_candidate_receivers: Default::default(),
        }
    }
}

impl IceState for ClientIceState {
    type Id = GatewayId;

    fn add_new_receiver(&mut self, id: Self::Id, receiver: Receiver<RTCIceCandidateInit>) {
        self.waiting_ice_candidate_receivers.insert(id, receiver);
    }

    fn poll_next_ice_candidate(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<(Self::Id, RTCIceCandidateInit)> {
        loop {
            match ready!(self.active_ice_candidate_receivers.poll_next_unpin(cx)) {
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
    ice_candidate_receivers: StreamMap<ClientId, RTCIceCandidateInit>,
}

impl Default for GatewayIceState {
    fn default() -> Self {
        Self {
            ice_candidate_receivers: StreamMap::new(Duration::from_secs(5 * 60), 100),
        }
    }
}

impl IceState for GatewayIceState {
    type Id = ClientId;

    fn add_new_receiver(&mut self, id: Self::Id, receiver: Receiver<RTCIceCandidateInit>) {
        let _ = self.ice_candidate_receivers.try_push(id, receiver);
    }

    fn poll_next_ice_candidate(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<(Self::Id, RTCIceCandidateInit)> {
        loop {
            match ready!(self.ice_candidate_receivers.poll_next_unpin(cx)) {
                (id, Some(Ok(c))) => return Poll::Ready((id, c)),
                (id, Some(Err(e))) => {
                    tracing::warn!(gateway_id = %id, "ICE gathering timed out: {e}")
                }
                (_, None) => {}
            }
        }
    }
}
