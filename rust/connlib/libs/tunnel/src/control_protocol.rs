use boringtun::{
    noise::Tunn,
    x25519::{PublicKey, StaticSecret},
};
use std::sync::Arc;

use libs_common::{
    error_type::ErrorType::Recoverable,
    messages::{Id, Key, Relay, RequestConnection},
    Callbacks, Error, Result,
};
use rand_core::OsRng;
use webrtc::{
    data_channel::RTCDataChannel,
    ice_transport::{ice_credential_type::RTCIceCredentialType, ice_server::RTCIceServer},
    peer_connection::{
        configuration::RTCConfiguration, peer_connection_state::RTCPeerConnectionState,
        sdp::session_description::RTCSessionDescription, RTCPeerConnection,
    },
};

use crate::{peer::Peer, ControlSignal, PeerConfig, Tunnel};

impl<C, CB> Tunnel<C, CB>
where
    C: ControlSignal + Send + Sync + 'static,
    CB: Callbacks + 'static,
{
    async fn handle_channel_open(
        self: &Arc<Self>,
        data_channel: Arc<RTCDataChannel>,
        index: u32,
        peer_config: PeerConfig,
    ) -> Result<()> {
        let channel = data_channel.detach().await.expect("TODO");
        let tunn = Tunn::new(
            self.private_key.clone(),
            peer_config.public_key,
            Some(peer_config.preshared_key.to_bytes()),
            peer_config.persistent_keepalive,
            index,
            None,
        )?;

        let peer = Arc::new(Peer::from_config(
            tunn,
            index,
            &peer_config,
            Arc::clone(&channel),
        ));

        {
            let mut peers_by_ip = self.peers_by_ip.write();
            for ip in peer_config.ips {
                peers_by_ip.insert(ip, Arc::clone(&peer));
            }
        }

        self.start_peer_handler(Arc::clone(&peer));
        Ok(())
    }

    #[tracing::instrument(level = "trace", skip(self))]
    async fn initialize_peer_request(
        self: &Arc<Self>,
        relays: Vec<Relay>,
    ) -> Result<Arc<RTCPeerConnection>> {
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

        peer_connection.on_peer_connection_state_change(Box::new(|_s| {
            Box::pin(async {
                // Respond with failure to control plane and remove peer
            })
        }));

        Ok(peer_connection)
    }

    #[tracing::instrument(level = "trace", skip(self))]
    fn handle_connection_state_update(self: &Arc<Self>, state: RTCPeerConnectionState) {
        tracing::trace!("Peer Connection State has changed: {state}");
        if state == RTCPeerConnectionState::Failed {
            // Wait until PeerConnection has had no network activity for 30 seconds or another failure. It may be reconnected using an ICE Restart.
            // Use webrtc.PeerConnectionStateDisconnected if you are interested in detecting faster timeout.
            // Note that the PeerConnection may come back from PeerConnectionStateDisconnected.
            tracing::warn!("Peer Connection has gone to failed exiting");
        }
    }

    #[tracing::instrument(level = "trace", skip(self))]
    fn set_connection_state_update(self: &Arc<Self>, peer_connection: &Arc<RTCPeerConnection>) {
        let tunnel = Arc::clone(self);
        peer_connection.on_peer_connection_state_change(Box::new(
            move |state: RTCPeerConnectionState| {
                let tunnel = Arc::clone(&tunnel);
                Box::pin(async move { tunnel.handle_connection_state_update(state) })
            },
        ));
    }

    /// Initiate an ice connection request.
    ///
    /// Given a resource id and a list of relay creates a [RequestConnection]
    /// and prepares the tunnel to handle the connection once initiated.
    ///
    /// # Note
    /// This function blocks until all ICE candidates are gathered so it might block for a long time.
    ///
    /// # Parameters
    /// - `resource_id`: Id of the resource we are going to request the connection to.
    /// - `relays`: The list of relays used for that connection.
    ///
    /// # Returns
    /// A [RequestConnection] that should be sent to the gateway through the control-plane.
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn request_connection(
        self: &Arc<Self>,
        resource_id: Id,
        relays: Vec<Relay>,
    ) -> Result<RequestConnection> {
        let peer_connection = self.initialize_peer_request(relays).await?;
        self.set_connection_state_update(&peer_connection);

        let data_channel = peer_connection.create_data_channel("data", None).await?;
        let d = Arc::clone(&data_channel);

        let tunnel = Arc::clone(self);

        let preshared_key = StaticSecret::random_from_rng(OsRng);
        let p_key = preshared_key.clone();
        let resource_description = tunnel
            .resources
            .read()
            .get_by_id(&resource_id)
            .expect("TODO")
            .clone();
        data_channel.on_open(Box::new(move || {
            tracing::trace!("new data channel opened!");
            Box::pin(async move {
                let index = tunnel.next_index();
                let Some(gateway_public_key) = tunnel.gateway_public_keys.lock().remove(&resource_id) else {
                    tunnel.cleanup_connection(resource_id);
                    tracing::warn!("Opened ICE channel with gateway without ever receiving public key");
                    tunnel.callbacks.on_error(&Error::ControlProtocolError, Recoverable);
                    return;
                };
                let peer_config = PeerConfig {
                    persistent_keepalive: None,
                    public_key: gateway_public_key,
                    ips: resource_description.ips(),
                    preshared_key: p_key,
                };

                if let Err(e) = tunnel.handle_channel_open(d, index, peer_config).await {
                    tracing::error!("Couldn't establish wireguard link after channel was opened: {e}");
                    tunnel.callbacks.on_error(&e, Recoverable);
                    tunnel.cleanup_connection(resource_id);
                }
                tunnel.awaiting_connection.lock().remove(&resource_id);
            })
        }));

        let offer = peer_connection.create_offer(None).await?;
        let mut gather_complete = peer_connection.gathering_complete_promise().await;
        peer_connection.set_local_description(offer).await?;

        // FIXME: timeout here! (but probably don't even bother because we need to implement ICE trickle)
        let _ = gather_complete.recv().await;
        let local_description = peer_connection
            .local_description()
            .await
            .expect("set_local_description was just called above");

        self.peer_connections
            .lock()
            .insert(resource_id, peer_connection);

        Ok(RequestConnection {
            resource_id,
            device_preshared_key: Key(preshared_key.to_bytes()),
            device_rtc_session_description: local_description,
        })
    }

    /// Called when a response to [Tunnel::request_connection] is ready.
    ///
    /// Once this is called if everything goes fine a new tunnel should be started between the 2 peers.
    ///
    /// # Parameters
    /// - `resource_id`: Id of the resource that responded.
    /// - `rtc_sdp`: Remote SDP.
    /// - `gateway_public_key`: Public key of the gateway that is handling that resource for this connection.
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn recieved_offer_response(
        self: &Arc<Self>,
        resource_id: Id,
        rtc_sdp: RTCSessionDescription,
        gateway_public_key: PublicKey,
    ) -> Result<()> {
        let peer_connection = self
            .peer_connections
            .lock()
            .get(&resource_id)
            .ok_or(Error::UnknownResource)?
            .clone();
        self.gateway_public_keys
            .lock()
            .insert(resource_id, gateway_public_key);
        peer_connection.set_remote_description(rtc_sdp).await?;
        Ok(())
    }

    /// Removes client's id from connections we are expecting.
    pub fn cleanup_peer_connection(self: &Arc<Self>, client_id: Id) {
        self.peer_connections.lock().remove(&client_id);
    }

    /// Accept a connection request from a client.
    ///
    /// Sets a connection to a remote SDP, creates the local SDP
    /// and returns it.
    ///
    /// # Note
    ///
    /// This function blocks until it gathers all the ICE candidates
    /// so it might block for a long time.
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
        client_id: Id,
    ) -> Result<RTCSessionDescription> {
        let peer_connection = self.initialize_peer_request(relays).await?;
        let index = self.next_index();
        let tunnel = Arc::clone(self);
        self.peer_connections
            .lock()
            .insert(client_id, Arc::clone(&peer_connection));

        self.set_connection_state_update(&peer_connection);

        peer_connection.on_data_channel(Box::new(move |d| {
            tracing::trace!("data channel created!");
            let data_channel = Arc::clone(&d);
            let peer = peer.clone();
            let tunnel = Arc::clone(&tunnel);
            Box::pin(async move {
                d.on_open(Box::new(move || {
                    tracing::trace!("new data channel opened!");
                    Box::pin(async move {
                        {
                            let mut iface_config = tunnel.iface_config.lock().await;
                            for ip in &peer.ips {
                                if let Err(e) = iface_config.add_route(ip).await {
                                    tunnel.callbacks.on_error(&e, Recoverable);
                                }
                            }
                        }
                        if let Err(e) = tunnel.handle_channel_open(data_channel, index, peer).await
                        {
                            tunnel.callbacks.on_error(&e, Recoverable);
                            tracing::error!(
                                "Couldn't establish wireguard link after opening channel: {e}"
                            );
                            // Note: handle_channel_open can only error out before insert to peers_by_ip
                            // otherwise we would need to clean that up too!
                            tunnel.peer_connections.lock().remove(&client_id);
                        }
                    })
                }))
            })
        }));

        peer_connection.set_remote_description(sdp_session).await?;

        let mut gather_complete = peer_connection.gathering_complete_promise().await;
        let answer = peer_connection.create_answer(None).await?;
        peer_connection.set_local_description(answer).await?;
        let _ = gather_complete.recv().await;
        let local_desc = peer_connection
            .local_description()
            .await
            .ok_or(Error::ConnectionEstablishError)?;

        Ok(local_desc)
    }

    /// Clean up a connection to a resource.
    pub fn cleanup_connection(&self, resource_id: Id) {
        self.awaiting_connection.lock().remove(&resource_id);
        self.peer_connections.lock().remove(&resource_id);
    }
}
