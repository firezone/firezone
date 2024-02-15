use arc_swap::ArcSwapOption;
use bytes::Bytes;
use futures::channel::mpsc;
use futures_util::SinkExt;
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use std::{fmt, sync::Arc};

use connlib_shared::{
    messages::{Relay, RequestConnection, ReuseConnection},
    Callbacks, Error, Result,
};
use webrtc::ice_transport::{
    ice_candidate::RTCIceCandidate, ice_gatherer::RTCIceGatherOptions,
    ice_parameters::RTCIceParameters, ice_transport_state::RTCIceTransportState,
};
use webrtc::ice_transport::{ice_candidate_type::RTCIceCandidateType, RTCIceTransport};
use webrtc::ice_transport::{ice_credential_type::RTCIceCredentialType, ice_server::RTCIceServer};

use crate::{
    device_channel::Device,
    peer::{PacketTransform, Peer},
    peer_handler, ConnectedPeer, RoleState, Tunnel,
};

mod client;
mod gateway;

const ICE_CANDIDATE_BUFFER: usize = 100;
// We should use not more than 1-2 relays (WebRTC in Firefox breaks at 5) due to combinatoric
// complexity of checking all the ICE candidate pairs
const MAX_RELAYS: usize = 2;

const MAX_HOST_CANDIDATES: usize = 8;

#[derive(Debug, Clone, PartialEq, Eq)]
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
        tracing::info!(%ice_candidate, %conn_id, "adding new remote candidate");
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

pub(crate) struct IceConnection {
    pub ice_parameters: RTCIceParameters,
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

    gatherer.on_local_candidate({
        let gatherer = gatherer.clone();
        Box::new(move |candidate| {
            let Some(candidate) = candidate else {
                gatherer.on_local_candidate(Box::new(|_| Box::pin(async {})));
                return Box::pin(async {});
            };

            tracing::info!(%candidate, "found new local candidate");

            let mut ice_candidate_tx = ice_candidate_tx.clone();
            let gatherer = gatherer.clone();
            Box::pin(async move {
                if candidate.typ == RTCIceCandidateType::Host {
                    if let Ok(candidates) = gatherer.get_local_candidates().await {
                        if candidates
                            .iter()
                            .filter(|c| c.typ == RTCIceCandidateType::Host)
                            .count()
                            > MAX_HOST_CANDIDATES
                        {
                            return;
                        }
                    }
                }

                if ice_candidate_tx.send(candidate).await.is_err() {
                    tracing::warn!("ice gatherer receiver was dropped before sender");
                }
            })
        })
    });

    gatherer.gather().await?;

    Ok(IceConnection {
        ice_parameters: gatherer.get_local_parameters().await?,
        ice_transport,
        ice_candidate_rx,
    })
}

fn insert_peers<TId: Copy, TTransform>(
    peers_by_ip: &mut IpNetworkTable<ConnectedPeer<TId, TTransform>>,
    ips: &Vec<IpNetwork>,
    peer: ConnectedPeer<TId, TTransform>,
) {
    for ip in ips {
        peers_by_ip.insert(*ip, peer.clone());
    }
}

fn start_handlers<TId, TTransform, TRoleState>(
    tunnel: Arc<Tunnel<impl Callbacks + 'static, TRoleState>>,
    device: Arc<ArcSwapOption<Device>>,
    peer: Arc<Peer<TId, TTransform>>,
    ice: Arc<RTCIceTransport>,
    peer_receiver: tokio::sync::mpsc::Receiver<Bytes>,
) where
    TId: Copy + Send + Sync + fmt::Debug + 'static,
    TTransform: Send + Sync + PacketTransform + 'static,
    TRoleState: RoleState<Id = TId>,
{
    let conn_id = peer.conn_id;
    ice.on_connection_state_change(Box::new(move |state| {
        let tunnel = tunnel.clone();
        Box::pin(async move {
            if state == RTCIceTransportState::Failed {
                tunnel.peers_to_stop.lock().push_back(conn_id);
            }
        })
    }));

    tokio::spawn({
        async move {
            // If this fails receiver will be dropped and the connection will expire at some point
            // this will not fail though, since this is always called after start ice
            let Some(ep) = ice.new_endpoint(Box::new(|_| true)).await else {
                return;
            };
            tokio::spawn(peer_handler::start_peer_handler(device, peer, ep.clone()));
            tokio::spawn(peer_handler::handle_packet(ep, peer_receiver));
        }
    });
}
