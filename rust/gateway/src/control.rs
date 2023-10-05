use crate::messages::BroadcastClientIceCandidates;
use async_trait::async_trait;
use connlib_shared::Error::ControlProtocolError;
use connlib_shared::{
    messages::{GatewayId, ResourceDescription},
    Result,
};
use firezone_tunnel::{ConnId, ControlSignal};
use tokio::sync::mpsc;
use webrtc::ice_transport::ice_candidate::RTCIceCandidate;

#[derive(Clone)]
pub struct ControlSignaler {
    tx: mpsc::Sender<BroadcastClientIceCandidates>,
}

impl ControlSignaler {
    pub fn new(tx: mpsc::Sender<BroadcastClientIceCandidates>) -> Self {
        Self { tx }
    }
}

#[async_trait]
impl ControlSignal for ControlSignaler {
    async fn signal_connection_to(
        &self,
        resource: &ResourceDescription,
        _connected_gateway_ids: &[GatewayId],
        _: usize,
    ) -> Result<()> {
        tracing::warn!("A message to network resource: {resource:?} was discarded, gateways aren't meant to be used as clients.");
        Ok(())
    }

    async fn signal_ice_candidate(
        &self,
        ice_candidate: RTCIceCandidate,
        conn_id: ConnId,
    ) -> Result<()> {
        // TODO: We probably want to have different signal_ice_candidate
        // functions for gateway/client but ultimately we just want
        // separate control_plane modules
        if let ConnId::Client(id) = conn_id {
            let _ = self
                .tx
                .send(BroadcastClientIceCandidates {
                    client_ids: vec![id],
                    candidates: vec![ice_candidate.to_json()?],
                })
                .await;
            Ok(())
        } else {
            Err(ControlProtocolError)
        }
    }
}
