use boringtun::{
    noise::Tunn,
    x25519::{PublicKey, StaticSecret},
};
use chrono::{DateTime, Utc};
use std::sync::Arc;
use tracing::instrument;

use libs_common::{
    messages::{Id, Key, Relay, RequestConnection, ResourceDescription, ReuseConnection},
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

mod candidate_parser;

#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(clippy::large_enum_variant)]
pub enum Request {
    NewConnection(RequestConnection),
    ReuseConnection(ReuseConnection),
}

impl<C, CB> Tunnel<C, CB>
where
    C: ControlSignal + Send + Sync + 'static,
    CB: Callbacks + 'static,
{
    #[instrument(level = "trace", skip(self, data_channel, peer_config))]
    async fn handle_channel_open(
        self: &Arc<Self>,
        data_channel: Arc<RTCDataChannel>,
        index: u32,
        peer_config: PeerConfig,
        conn_id: Id,
        resources: Option<(ResourceDescription, DateTime<Utc>)>,
    ) -> Result<()> {
        tracing::trace!(
            "New datachannel opened for peer with ips: {:?}",
            peer_config.ips
        );
        let channel = data_channel.detach().await?;
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
            channel,
            conn_id,
            resources,
        ));

        {
            // Watch out! we need 2 locks, make sure you don't lock both at the same time anywhere else
            let mut gateway_awaiting_connection = self.gateway_awaiting_connection.lock();
            let mut peers_by_ip = self.peers_by_ip.write();
            // In the gateway this will always be none, no harm done
            if let Some(awaiting_ips) = gateway_awaiting_connection.remove(&conn_id) {
                for ip in awaiting_ips {
                    peer.add_allowed_ip(ip);
                    peers_by_ip.insert(ip, Arc::clone(&peer));
                }
            }
            for ip in peer_config.ips {
                peers_by_ip.insert(ip, Arc::clone(&peer));
            }
        }

        self.start_peer_handler(peer)?;
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
    fn handle_connection_state_update_initiator(
        self: &Arc<Self>,
        state: RTCPeerConnectionState,
        gateway_id: Id,
        resource_id: Id,
    ) {
        tracing::trace!("Peer Connection State has changed: {state}");
        if state == RTCPeerConnectionState::Failed {
            self.awaiting_connection.lock().remove(&resource_id);
            self.peer_connections.lock().remove(&gateway_id);
            self.gateway_awaiting_connection.lock().remove(&gateway_id);
            tracing::warn!("Peer Connection has gone to failed exiting");
        }
    }

    #[tracing::instrument(level = "trace", skip(self))]
    fn set_connection_state_update_initiator(
        self: &Arc<Self>,
        peer_connection: &Arc<RTCPeerConnection>,
        gateway_id: Id,
        resource_id: Id,
    ) {
        let tunnel = Arc::clone(self);
        peer_connection.on_peer_connection_state_change(Box::new(
            move |state: RTCPeerConnectionState| {
                let tunnel = Arc::clone(&tunnel);
                Box::pin(async move {
                    tunnel.handle_connection_state_update_initiator(state, gateway_id, resource_id)
                })
            },
        ));
    }

    #[tracing::instrument(level = "trace", skip(self))]
    fn handle_connection_state_update_responder(
        self: &Arc<Self>,
        state: RTCPeerConnectionState,
        client_id: Id,
    ) {
        tracing::trace!("Peer Connection State has changed: {state}");
        if state == RTCPeerConnectionState::Failed {
            self.peer_connections.lock().remove(&client_id);
            tracing::warn!("Peer Connection has gone to failed exiting");
        }
    }

    #[tracing::instrument(level = "trace", skip(self))]
    fn set_connection_state_update_responder(
        self: &Arc<Self>,
        peer_connection: &Arc<RTCPeerConnection>,
        client_id: Id,
    ) {
        let tunnel = Arc::clone(self);
        peer_connection.on_peer_connection_state_change(Box::new(
            move |state: RTCPeerConnectionState| {
                let tunnel = Arc::clone(&tunnel);
                Box::pin(async move {
                    tunnel.handle_connection_state_update_responder(state, client_id)
                })
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
        gateway_id: Id,
        relays: Vec<Relay>,
    ) -> Result<Request> {
        self.resources_gateways
            .lock()
            .insert(resource_id, gateway_id);
        let resource_description = self
            .resources
            .read()
            .get_by_id(&resource_id)
            .ok_or(Error::UnknownResource)?
            .clone();
        {
            let mut gateway_awaiting_connection = self.gateway_awaiting_connection.lock();
            if let Some(g) = gateway_awaiting_connection.get_mut(&gateway_id) {
                g.extend(resource_description.ips());
                return Ok(Request::ReuseConnection(ReuseConnection {
                    resource_id,
                    gateway_id,
                }));
            } else {
                gateway_awaiting_connection.insert(gateway_id, vec![]);
            }
        }
        {
            let mut peers_by_ip = self.peers_by_ip.write();
            let peer = peers_by_ip
                .iter()
                .find_map(|(_, p)| (p.conn_id == gateway_id).then_some(p))
                .cloned();
            if let Some(peer) = peer {
                for ip in resource_description.ips() {
                    peer.add_allowed_ip(ip);
                    peers_by_ip.insert(ip, Arc::clone(&peer));
                }
                return Ok(Request::ReuseConnection(ReuseConnection {
                    resource_id,
                    gateway_id,
                }));
            }
        }
        let peer_connection = self.initialize_peer_request(relays).await?;
        self.set_connection_state_update_initiator(&peer_connection, gateway_id, resource_id);

        let data_channel = peer_connection.create_data_channel("data", None).await?;
        let d = Arc::clone(&data_channel);

        let tunnel = Arc::clone(self);

        let preshared_key = StaticSecret::random_from_rng(OsRng);
        let p_key = preshared_key.clone();
        data_channel.on_open(Box::new(move || {
            Box::pin(async move {
            tracing::trace!("new data channel opened!");
                let index = tunnel.next_index();
                let Some(gateway_public_key) = tunnel.gateway_public_keys.lock().remove(&gateway_id) else {
                    tunnel.awaiting_connection.lock().remove(&resource_id);
                    tunnel.peer_connections.lock().remove(&gateway_id);
                    tunnel.gateway_awaiting_connection.lock().remove(&gateway_id);
                    tracing::warn!("Opened ICE channel with gateway without ever receiving public key");
                    let _ = tunnel.callbacks.on_error(&Error::ControlProtocolError);
                    return;
                };
                let peer_config = PeerConfig {
                    persistent_keepalive: None,
                    public_key: gateway_public_key,
                    ips: resource_description.ips(),
                    preshared_key: p_key,
                };

                if let Err(e) = tunnel.handle_channel_open(d, index, peer_config, gateway_id, None).await {
                    tracing::error!("Couldn't establish wireguard link after channel was opened: {e}");
                    let _ = tunnel.callbacks.on_error(&e);
                    tunnel.peer_connections.lock().remove(&gateway_id);
                    tunnel.gateway_awaiting_connection.lock().remove(&gateway_id);
                }
                tunnel.awaiting_connection.lock().remove(&resource_id);
            })
        }));

        let offer = peer_connection.create_offer(None).await?;
        let mut gather_complete = peer_connection.gathering_complete_promise().await;
        // TODO: Remove tunnel ip from offer
        peer_connection.set_local_description(offer).await?;

        // FIXME: timeout here! (but probably don't even bother because we need to implement ICE trickle)
        let _ = gather_complete.recv().await;
        let local_description = peer_connection
            .local_description()
            .await
            .expect("Developer error: set_local_description was just called above");

        self.peer_connections
            .lock()
            .insert(gateway_id, peer_connection);

        Ok(Request::NewConnection(RequestConnection {
            resource_id,
            gateway_id,
            device_preshared_key: Key(preshared_key.to_bytes()),
            device_rtc_session_description: local_description,
        }))
    }

    /// Called when a response to [Tunnel::request_connection] is ready.
    ///
    /// Once this is called, if everything goes fine, a new tunnel should be started between the 2 peers.
    ///
    /// # Parameters
    /// - `resource_id`: Id of the resource that responded.
    /// - `rtc_sdp`: Remote SDP.
    /// - `gateway_public_key`: Public key of the gateway that is handling that resource for this connection.
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn recieved_offer_response(
        self: &Arc<Self>,
        resource_id: Id,
        mut rtc_sdp: RTCSessionDescription,
        gateway_public_key: PublicKey,
    ) -> Result<()> {
        let gateway_id = *self
            .resources_gateways
            .lock()
            .get(&resource_id)
            .ok_or(Error::UnknownResource)?;
        let peer_connection = self
            .peer_connections
            .lock()
            .get(&gateway_id)
            .ok_or(Error::UnknownResource)?
            .clone();
        self.gateway_public_keys
            .lock()
            .insert(gateway_id, gateway_public_key);

        let mut sdp = rtc_sdp.unmarshal()?;

        // We don't want to allow tunnel-over-tunnel as it leads to some weirdness
        // I'm sure there are some edge-cases where we want that but let's tackle that when it comes up
        self.sdp_remove_resource_attributes(&mut sdp.attributes);
        for m in sdp.media_descriptions.iter_mut() {
            self.sdp_remove_resource_attributes(&mut m.attributes);
        }

        rtc_sdp.sdp = sdp.marshal();

        peer_connection.set_remote_description(rtc_sdp).await?;
        Ok(())
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
        expires_at: DateTime<Utc>,
        resource: ResourceDescription,
    ) -> Result<RTCSessionDescription> {
        let peer_connection = self.initialize_peer_request(relays).await?;
        let index = self.next_index();
        let tunnel = Arc::clone(self);
        self.peer_connections
            .lock()
            .insert(client_id, Arc::clone(&peer_connection));

        self.set_connection_state_update_responder(&peer_connection, client_id);

        peer_connection.on_data_channel(Box::new(move |d| {
            tracing::trace!("data channel created!");
            let data_channel = Arc::clone(&d);
            let peer = peer.clone();
            let tunnel = Arc::clone(&tunnel);
            let resource = resource.clone();
            Box::pin(async move {
                d.on_open(Box::new(move || {
                    tracing::trace!("new data channel opened!");
                    Box::pin(async move {
                        {
                            let Some(ref mut iface_config) = *tunnel.iface_config.lock().await else {
                                tracing::error!(message = "Error opening channel", error = "Tried to open a channel before interface was ready");
                                let _ = tunnel.callbacks().on_error(&Error::NoIface);
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
                                client_id,
                                Some((resource, expires_at)),
                            )
                            .await
                        {
                            let _ = tunnel.callbacks.on_error(&e);
                            tracing::error!(
                                "Couldn't establish wireguard link after opening channel: {e}"
                            );
                            // Note: handle_channel_open can only error out before insert to peers_by_ip
                            // otherwise we would need to clean that up too!
                            let conn = tunnel.peer_connections.lock().remove(&client_id);
                            if let Some(conn) = conn {
                                if let Err(e) = conn.close().await {
                                    tracing::error!(message = "Error trying to close channel", error = ?e);
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

    pub fn allow_access(
        &self,
        resource: ResourceDescription,
        client_id: Id,
        expires_at: DateTime<Utc>,
    ) {
        if let Some(peer) = self
            .peers_by_ip
            .write()
            .iter_mut()
            .find_map(|(_, p)| (p.conn_id == client_id).then_some(p))
        {
            peer.add_resource(resource, expires_at);
        }
    }

    /// Clean up a connection to a resource.
    // FIXME: this cleanup connection is wrong!
    pub fn cleanup_connection(&self, id: Id) {
        self.awaiting_connection.lock().remove(&id);
        self.peer_connections.lock().remove(&id);
    }
}
