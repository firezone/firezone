use std::sync::Arc;

use chrono::{DateTime, Utc};
use connlib_shared::{
    messages::{ClientId, Relay, ResourceDescription},
    Callbacks, Error, Result,
};
use webrtc::peer_connection::{
    peer_connection_state::RTCPeerConnectionState, sdp::session_description::RTCSessionDescription,
    RTCPeerConnection,
};

use crate::{peer::Peer, GatewayState, PeerConfig, Tunnel};

#[tracing::instrument(level = "trace", skip(tunnel))]
fn handle_connection_state_update<CB>(
    tunnel: &Arc<Tunnel<CB, GatewayState>>,
    state: RTCPeerConnectionState,
    client_id: ClientId,
) where
    CB: Callbacks + 'static,
{
    tracing::trace!(?state, "peer_state");
    if state == RTCPeerConnectionState::Failed {
        tunnel.peer_connections.lock().remove(&client_id.into());
    }
}

#[tracing::instrument(level = "trace", skip(tunnel))]
fn set_connection_state_update<CB>(
    tunnel: &Arc<Tunnel<CB, GatewayState>>,
    peer_connection: &Arc<RTCPeerConnection>,
    client_id: ClientId,
) where
    CB: Callbacks + 'static,
{
    let tunnel = Arc::clone(tunnel);
    peer_connection.on_peer_connection_state_change(Box::new(
        move |state: RTCPeerConnectionState| {
            let tunnel = Arc::clone(&tunnel);
            Box::pin(async move { handle_connection_state_update(&tunnel, state, client_id) })
        },
    ));
}

impl<CB> Tunnel<CB, GatewayState>
where
    CB: Callbacks + 'static,
{
    /// Accept a connection request from a client.
    ///
    /// Sets a connection to a remote SDP, creates the local SDP
    /// and returns it.
    ///
    /// # Parameters
    /// - `sdp_session`: Remote session description.
    /// - `peer`: Configuration for the remote peer.
    /// - `relays`: List of relays to use with this connection.
    /// - `client_id`: UUID of the remote client.
    ///
    /// # Returns
    /// An [RTCSessionDescription] of the local sdp, with candidates gathered.
    pub async fn set_peer_connection_request(
        self: &Arc<Self>,
        sdp_session: RTCSessionDescription,
        peer: PeerConfig,
        relays: Vec<Relay>,
        client_id: ClientId,
        expires_at: DateTime<Utc>,
        resource: ResourceDescription,
    ) -> Result<RTCSessionDescription> {
        let (peer_connection, receiver) = self.new_peer_connection(relays).await?;
        self.role_state
            .lock()
            .add_new_ice_receiver(client_id, receiver);

        let index = self.next_index();
        let tunnel = Arc::clone(self);
        self.peer_connections
            .lock()
            .insert(client_id.into(), Arc::clone(&peer_connection));

        set_connection_state_update(self, &peer_connection, client_id);

        peer_connection.on_data_channel(Box::new(move |d| {
            tracing::trace!("new_data_channel");
            let data_channel = Arc::clone(&d);
            let peer_config = peer.clone();
            let tunnel = Arc::clone(&tunnel);
            let resource = resource.clone();
            Box::pin(async move {
                d.on_open(Box::new(move || {
                    tracing::trace!(?peer_config.ips, "new_data_channel_open");
                    Box::pin(async move {
                        {
                            let Some(device) = tunnel.device.read().await.clone() else {
                                let e = Error::NoIface;
                                tracing::error!(err = ?e, "channel_open");
                                let _ = tunnel.callbacks().on_error(&e);
                                return;
                            };
                            let iface_config = device.config;
                            for &ip in &peer_config.ips {
                                if let Err(e) = iface_config.add_route(ip, tunnel.callbacks()).await
                                {
                                    let _ = tunnel.callbacks.on_error(&e);
                                }
                            }
                        }

                        data_channel
                            .on_close(tunnel.clone().on_dc_close_handler(index, client_id.into()));

                        let peer = Arc::new(Peer::new(
                            tunnel.private_key.clone(),
                            index,
                            peer_config.clone(),
                            data_channel.detach().await.expect("only fails if not opened or not enabled, both of which are always true for us"),
                            client_id.into(),
                            Some((resource, expires_at)),
                        ));

                        let mut peers_by_ip = tunnel.peers_by_ip.write();

                        for ip in peer_config.ips {
                            peers_by_ip.insert(ip, Arc::clone(&peer));
                        }

                        if let Some(conn) = tunnel.peer_connections.lock().get(&client_id.into()) {
                            conn.on_peer_connection_state_change(
                                tunnel.clone().on_peer_connection_state_change_handler(
                                    index,
                                    client_id.into(),
                                ),
                            );
                        }

                        tokio::spawn(tunnel.clone().start_peer_handler(peer));
                    })
                }))
            })
        }));

        peer_connection.set_remote_description(sdp_session).await?;

        // TODO: remove tunnel IP from answer
        let answer = peer_connection.create_answer(None).await?;
        peer_connection.set_local_description(answer).await?;
        let local_desc = peer_connection
            .local_description()
            .await
            .ok_or(Error::ConnectionEstablishError)?;

        Ok(local_desc)
    }

    pub fn allow_access(
        &self,
        resource: ResourceDescription,
        client_id: ClientId,
        expires_at: DateTime<Utc>,
    ) {
        if let Some(peer) = self
            .peers_by_ip
            .write()
            .iter_mut()
            .find_map(|(_, p)| (p.conn_id == client_id.into()).then_some(p))
        {
            peer.add_resource(resource, expires_at);
        }
    }
}
