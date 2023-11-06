use std::sync::Arc;

use chrono::{DateTime, Utc};
use connlib_shared::{
    messages::{ClientId, Relay, ResourceDescription},
    Callbacks, Error, Result,
};
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;

use crate::control_protocol::{
    new_peer_connection, on_dc_close_handler, on_peer_connection_state_change_handler,
};
use crate::{peer::Peer, ConnectedPeer, GatewayState, PeerConfig, Tunnel};

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
        let (peer_connection, receiver) = new_peer_connection(&self.webrtc_api, relays).await?;
        self.role_state
            .lock()
            .add_new_ice_receiver(client_id, receiver);

        let index = self.next_index();
        let tunnel = Arc::clone(self);
        self.peer_connections
            .lock()
            .insert(client_id, Arc::clone(&peer_connection));

        peer_connection.on_peer_connection_state_change(on_peer_connection_state_change_handler(
            client_id,
            tunnel.stop_peer_command_sender.clone(),
        ));

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
                            let Some(device) = tunnel.device.read().clone() else {
                                let e = Error::NoIface;
                                tracing::error!(err = ?e, "channel_open");
                                let _ = tunnel.callbacks().on_error(&e);
                                return;
                            };
                            let iface_config = &device.config;
                            for &ip in &peer_config.ips {
                                if let Err(e) = iface_config.add_route(ip, tunnel.callbacks()).await
                                {
                                    let _ = tunnel.callbacks.on_error(&e);
                                }
                            }
                        }

                        data_channel
                            .on_close(on_dc_close_handler(client_id, tunnel.stop_peer_command_sender.clone()));

                        let data_channel = data_channel.detach().await.expect("only fails if not opened or not enabled, both of which are always true for us");

                        let peer = Arc::new(Peer::new(
                            tunnel.private_key.clone(),
                            index,
                            peer_config.clone(),
                            client_id,
                            Some((resource, expires_at)),
                            tunnel.rate_limiter.clone()
                        ));

                        // Holding two mutexes here
                        {
                            let mut peers_by_ip = tunnel.peers_by_ip.write();

                            for ip in peer_config.ips {
                                peers_by_ip.insert(ip, ConnectedPeer {
                                    inner: peer.clone(),
                                    channel: data_channel.clone(),
                                });
                            }
                        }

                        tokio::spawn(tunnel.clone().start_peer_handler(peer, data_channel));
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
        if let Some((_, peer)) = self
            .peers_by_ip
            .write()
            .iter_mut()
            .find(|(_, p)| p.inner.conn_id == client_id)
        {
            peer.inner.add_resource(resource, expires_at);
        }
    }
}
