use futures::channel::mpsc;
use futures_util::SinkExt;
use std::sync::Arc;

use connlib_shared::{
    messages::{Relay, RequestConnection, ReuseConnection},
    Callbacks, Error, Result,
};
use webrtc::data_channel::OnCloseHdlrFn;
use webrtc::peer_connection::OnPeerConnectionStateChangeHdlrFn;
use webrtc::{
    ice_transport::{
        ice_candidate::RTCIceCandidateInit, ice_credential_type::RTCIceCredentialType,
        ice_server::RTCIceServer,
    },
    peer_connection::{
        configuration::RTCConfiguration, peer_connection_state::RTCPeerConnectionState,
        RTCPeerConnection,
    },
};

use crate::{stop_peer, RoleState, Tunnel};

mod client;
mod gateway;

const ICE_CANDIDATE_BUFFER: usize = 100;

#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(clippy::large_enum_variant)]
pub enum Request {
    NewConnection(RequestConnection),
    ReuseConnection(ReuseConnection),
}

impl<CB, TRoleState> Tunnel<CB, TRoleState>
where
    CB: Callbacks + 'static,
    TRoleState: RoleState,
{
    pub fn on_dc_close_handler(
        self: Arc<Self>,
        index: u32,
        conn_id: TRoleState::Id,
    ) -> OnCloseHdlrFn {
        let sender = self.dc_closed_sender.lock().clone();

        Box::new(move || {
            let mut sender = sender.clone();

            tracing::debug!("channel_closed");
            Box::pin(async move {
                let _ = sender.send((index, conn_id)).await;
            })
        })
    }

    pub fn on_peer_connection_state_change_handler(
        self: Arc<Self>,
        index: u32,
        conn_id: TRoleState::Id,
    ) -> OnPeerConnectionStateChangeHdlrFn {
        Box::new(move |state| {
            let tunnel = Arc::clone(&self);
            Box::pin(async move {
                tracing::trace!(?state, "peer_state_update");
                if state == RTCPeerConnectionState::Failed {
                    stop_peer(
                        &mut tunnel.peers_by_ip.write(),
                        &mut tunnel.peer_connections.lock(),
                        &mut tunnel.close_connection_tasks.lock(),
                        index,
                        conn_id,
                    );
                }
            })
        })
    }

    pub async fn add_ice_candidate(
        &self,
        conn_id: TRoleState::Id,
        ice_candidate: RTCIceCandidateInit,
    ) -> Result<()> {
        let peer_connection = self
            .peer_connections
            .lock()
            .get(&conn_id)
            .ok_or(Error::ControlProtocolError)?
            .clone();
        peer_connection.add_ice_candidate(ice_candidate).await?;
        Ok(())
    }
}

#[tracing::instrument(level = "trace", skip(webrtc))]
pub async fn new_peer_connection(
    webrtc: &webrtc::api::API,
    relays: Vec<Relay>,
) -> Result<(Arc<RTCPeerConnection>, mpsc::Receiver<RTCIceCandidateInit>)> {
    let config = RTCConfiguration {
        ice_servers: relays
            .into_iter()
            .map(|srv| match srv {
                Relay::Stun(stun) => RTCIceServer {
                    urls: vec![stun.uri],
                    ..Default::default()
                },
                Relay::Turn(turn) => RTCIceServer {
                    urls: vec![turn.uri],
                    username: turn.username,
                    credential: turn.password,
                    // TODO: check what this is used for
                    credential_type: RTCIceCredentialType::Password,
                },
            })
            .collect(),
        ..Default::default()
    };

    let peer_connection = Arc::new(webrtc.new_peer_connection(config).await?);

    let (ice_candidate_tx, ice_candidate_rx) = mpsc::channel(ICE_CANDIDATE_BUFFER);

    peer_connection.on_ice_candidate(Box::new(move |candidate| {
        let Some(candidate) = candidate else {
            return Box::pin(async {});
        };

        let mut ice_candidate_tx = ice_candidate_tx.clone();
        Box::pin(async move {
            let ice_candidate = match candidate.to_json() {
                Ok(ice_candidate) => ice_candidate,
                Err(e) => {
                    tracing::warn!("Failed to serialize ICE candidate to JSON: {e}",);
                    return;
                }
            };

            if ice_candidate_tx.send(ice_candidate).await.is_err() {
                debug_assert!(false, "receiver was dropped before sender")
            }
        })
    }));

    Ok((peer_connection, ice_candidate_rx))
}
