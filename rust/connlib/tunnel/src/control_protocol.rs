use boringtun::noise::Tunn;
use chrono::{DateTime, Utc};
use futures::channel::mpsc;
use futures_util::SinkExt;
use parking_lot::Mutex;
use secrecy::ExposeSecret;
use std::sync::Arc;
use tracing::instrument;

use connlib_shared::{
    messages::{Relay, RequestConnection, ResourceDescription, ReuseConnection},
    Callbacks, Error, Result,
};
use webrtc::{
    data_channel::RTCDataChannel,
    ice_transport::{
        ice_candidate::RTCIceCandidateInit, ice_credential_type::RTCIceCredentialType,
        ice_server::RTCIceServer,
    },
    peer_connection::{
        configuration::RTCConfiguration, peer_connection_state::RTCPeerConnectionState,
        RTCPeerConnection,
    },
};

use crate::{peer::Peer, ConnId, ControlSignal, PeerConfig, RoleState, Tunnel};

mod client;
mod gateway;

const ICE_CANDIDATE_BUFFER: usize = 100;

#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(clippy::large_enum_variant)]
pub enum Request {
    NewConnection(RequestConnection),
    ReuseConnection(ReuseConnection),
}

#[tracing::instrument(level = "trace", skip(tunnel))]
async fn handle_connection_state_update_with_peer<C, CB, TRoleState>(
    tunnel: &Arc<Tunnel<C, CB, TRoleState>>,
    state: RTCPeerConnectionState,
    index: u32,
    conn_id: ConnId,
) where
    C: ControlSignal + Clone + Send + Sync + 'static,
    CB: Callbacks + 'static,
    TRoleState: RoleState,
{
    tracing::trace!(?state, "peer_state_update");
    if state == RTCPeerConnectionState::Failed {
        tunnel.stop_peer(index, conn_id).await;
    }
}

#[tracing::instrument(level = "trace", skip(tunnel))]
fn set_connection_state_with_peer<C, CB, TRoleState>(
    tunnel: &Arc<Tunnel<C, CB, TRoleState>>,
    peer_connection: &Arc<RTCPeerConnection>,
    index: u32,
    conn_id: ConnId,
) where
    C: ControlSignal + Clone + Send + Sync + 'static,
    CB: Callbacks + 'static,
    TRoleState: RoleState,
{
    let tunnel = Arc::clone(tunnel);
    peer_connection.on_peer_connection_state_change(Box::new(
        move |state: RTCPeerConnectionState| {
            let tunnel = Arc::clone(&tunnel);
            Box::pin(async move {
                handle_connection_state_update_with_peer(&tunnel, state, index, conn_id).await
            })
        },
    ));
}

impl<C, CB, TRoleState> Tunnel<C, CB, TRoleState>
where
    C: ControlSignal + Clone + Send + Sync + 'static,
    CB: Callbacks + 'static,
    TRoleState: RoleState,
{
    #[instrument(level = "trace", skip(self, data_channel, peer_config))]
    async fn handle_channel_open(
        self: &Arc<Self>,
        data_channel: Arc<RTCDataChannel>,
        index: u32,
        peer_config: PeerConfig,
        conn_id: ConnId,
        resources: Option<(ResourceDescription, DateTime<Utc>)>,
    ) -> Result<()> {
        tracing::trace!(
            ?peer_config.ips,
            "data_channel_open",
        );
        let channel = data_channel.detach().await?;
        let tunn = Tunn::new(
            self.private_key.clone(),
            peer_config.public_key,
            Some(peer_config.preshared_key.expose_secret().0),
            peer_config.persistent_keepalive,
            index,
            None,
        )?;

        let peer = Arc::new(Peer::new(
            Mutex::new(tunn),
            index,
            peer_config.ips.clone(),
            channel,
            conn_id,
            resources,
        ));

        {
            // Watch out! we need 2 locks, make sure you don't lock both at the same time anywhere else
            let mut gateway_awaiting_connection = self.gateway_awaiting_connection.lock();
            let mut peers_by_ip = self.peers_by_ip.write();
            // In the gateway this will always be none, no harm done
            match conn_id {
                ConnId::Gateway(gateway_id) => {
                    if let Some(awaiting_ips) = gateway_awaiting_connection.remove(&gateway_id) {
                        for ip in awaiting_ips {
                            peer.add_allowed_ip(ip);
                            peers_by_ip.insert(ip, Arc::clone(&peer));
                        }
                    }
                }
                ConnId::Client(_) => {}
                ConnId::Resource(_) => {}
            }
            for ip in peer_config.ips {
                peers_by_ip.insert(ip, Arc::clone(&peer));
            }
        }

        if let Some(conn) = self.peer_connections.lock().get(&conn_id) {
            set_connection_state_with_peer(self, conn, index, conn_id)
        }

        data_channel.on_close({
            let tunnel = Arc::clone(self);
            Box::new(move || {
                tracing::debug!("channel_closed");
                let tunnel = tunnel.clone();
                Box::pin(async move {
                    tunnel.stop_peer(index, conn_id).await;
                })
            })
        });

        let tunnel = Arc::clone(self);
        tokio::spawn(async move { tunnel.start_peer_handler(peer).await });

        Ok(())
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn new_peer_connection(
        self: &Arc<Self>,
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

        let peer_connection = Arc::new(self.webrtc_api.new_peer_connection(config).await?);

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

    pub async fn add_ice_candidate(
        &self,
        conn_id: ConnId,
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

    /// Clean up a connection to a resource.
    // FIXME: this cleanup connection is wrong!
    pub fn cleanup_connection(&self, id: ConnId) {
        self.awaiting_connection.lock().remove(&id);
        self.peer_connections.lock().remove(&id);
    }
}
