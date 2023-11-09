use futures::channel::mpsc;
use futures_util::SinkExt;
use std::sync::Arc;

use connlib_shared::{
    messages::{Relay, RequestConnection, ReuseConnection},
    Callbacks, Error, Result,
};
use webrtc::ice_transport::{
    ice_candidate::RTCIceCandidate, ice_gatherer::RTCIceGatherOptions,
    ice_parameters::RTCIceParameters, OnConnectionStateChangeHdlrFn,
};
use webrtc::ice_transport::{ice_credential_type::RTCIceCredentialType, ice_server::RTCIceServer};
use webrtc::ice_transport::{ice_transport_state::RTCIceTransportState, RTCIceTransport};

use crate::{RoleState, Tunnel};

mod client;
mod gateway;

const ICE_CANDIDATE_BUFFER: usize = 100;
// We should use not more than 1-2 relays (WebRTC in Firefox breaks at 5) due to combinatoric
// complexity of checking all the ICE candidate pairs
const MAX_RELAYS: usize = 2;

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
    pub async fn add_ice_candidate(
        &self,
        conn_id: TRoleState::Id,
        ice_candidate: RTCIceCandidate,
    ) -> Result<()> {
        let peer_connection = self
            .peer_connections
            .lock()
            .get(&conn_id)
            .ok_or(Error::ControlProtocolError)?
            .clone();
        peer_connection
            .add_remote_candidate(Some(ice_candidate))
            .await?;
        Ok(())
    }
}

pub fn on_peer_connection_state_change_handler<TId>(
    conn_id: TId,
    stop_command_sender: mpsc::Sender<TId>,
) -> OnConnectionStateChangeHdlrFn
where
    TId: Copy + Send + Sync + 'static,
{
    Box::new(move |state| {
        let mut sender = stop_command_sender.clone();

        tracing::trace!(?state, "peer_state_update");
        Box::pin(async move {
            if matches!(
                state,
                RTCIceTransportState::Failed | RTCIceTransportState::Closed
            ) {
                let _ = sender.send(conn_id).await;
            }
        })
    })
}

pub(crate) struct IceConnection {
    pub ice_params: RTCIceParameters,
    pub ice_transport: Arc<RTCIceTransport>,
    pub ice_candidate_rx: mpsc::Receiver<RTCIceCandidate>,
}

#[tracing::instrument(level = "trace", skip(webrtc))]
pub(crate) async fn new_ice_connection(
    webrtc: &webrtc::api::API,
    relays: Vec<Relay>,
) -> Result<IceConnection> {
    let config = RTCIceGatherOptions {
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
                    credential_type: RTCIceCredentialType::Password,
                },
            })
            .take(MAX_RELAYS)
            .collect(),
        ..Default::default()
    };

    let gatherer = Arc::new(webrtc.new_ice_gatherer(config)?);
    let ice_transport = Arc::new(webrtc.new_ice_transport(Arc::clone(&gatherer)));

    let (ice_candidate_tx, ice_candidate_rx) = mpsc::channel(ICE_CANDIDATE_BUFFER);

    gatherer.on_local_candidate(Box::new(move |candidate| {
        let Some(candidate) = candidate else {
            return Box::pin(async {});
        };

        let mut ice_candidate_tx = ice_candidate_tx.clone();
        Box::pin(async move {
            if ice_candidate_tx.send(candidate).await.is_err() {
                debug_assert!(false, "receiver was dropped before sender")
            }
        })
    }));

    gatherer.gather().await?;

    Ok(IceConnection {
        ice_params: gatherer.get_local_parameters().await?,
        ice_transport,
        ice_candidate_rx,
    })
}
