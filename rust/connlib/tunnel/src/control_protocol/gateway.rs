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

use crate::{ControlSignal, PeerConfig, Tunnel};

#[tracing::instrument(level = "trace", skip(tunnel))]
fn handle_connection_state_update<C, CB>(
    tunnel: &Arc<Tunnel<C, CB>>,
    state: RTCPeerConnectionState,
    client_id: ClientId,
) where
    C: ControlSignal + Clone + Send + Sync + 'static,
    CB: Callbacks + 'static,
{
    tracing::trace!(?state, "peer_state");
    if state == RTCPeerConnectionState::Failed {
        tunnel.peer_connections.lock().remove(&client_id.into());
    }
}

#[tracing::instrument(level = "trace", skip(tunnel))]
fn set_connection_state_update<C, CB>(
    tunnel: &Arc<Tunnel<C, CB>>,
    peer_connection: &Arc<RTCPeerConnection>,
    client_id: ClientId,
) where
    C: ControlSignal + Clone + Send + Sync + 'static,
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

impl<C, CB> Tunnel<C, CB>
where
    C: ControlSignal + Clone + Send + Sync + 'static,
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
        let peer_connection = self
            .initialize_peer_request(relays, client_id.into())
            .await?;
        self.start_ice_candidate_handler(client_id.into())?;

        let index = self.next_index();
        let tunnel = Arc::clone(self);
        self.peer_connections
            .lock()
            .insert(client_id.into(), Arc::clone(&peer_connection));

        set_connection_state_update(self, &peer_connection, client_id);

        peer_connection.on_data_channel(Box::new(move |d| {
            tracing::trace!("new_data_channel");
            let data_channel = Arc::clone(&d);
            let peer = peer.clone();
            let tunnel = Arc::clone(&tunnel);
            let resource = resource.clone();
            Box::pin(async move {
                d.on_open(Box::new(move || {
                    tracing::trace!("new_data_channel_open");
                    Box::pin(async move {
                        {
                            let Some(iface_config) = tunnel.iface_config.read().await.clone()
                            else {
                                let e = Error::NoIface;
                                tracing::error!(err = ?e, "channel_open");
                                let _ = tunnel.callbacks().on_error(&e);
                                return;
                            };
                            for &ip in &peer.ips {
                                if let Err(e) = iface_config.add_route(ip, tunnel.callbacks()).await
                                {
                                    let _ = tunnel.callbacks.on_error(&e);
                                }
                            }
                        }

                        if let Err(e) = tunnel
                            .handle_channel_open(
                                data_channel,
                                index,
                                peer,
                                client_id.into(),
                                Some((resource, expires_at)),
                            )
                            .await
                        {
                            let _ = tunnel.callbacks.on_error(&e);
                            tracing::error!(err = ?e, "channel_open");
                            // Note: handle_channel_open can only error out before insert to peers_by_ip
                            // otherwise we would need to clean that up too!
                            let conn = tunnel.peer_connections.lock().remove(&client_id.into());
                            if let Some(conn) = conn {
                                if let Err(e) = conn.close().await {
                                    tracing::error!(error = ?e, "webrtc_close_channel");
                                    let _ = tunnel.callbacks().on_error(&e.into());
                                }
                            }
                        }
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
}
