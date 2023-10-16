use std::sync::Arc;

use boringtun::x25519::{PublicKey, StaticSecret};
use connlib_shared::messages::SecretKey;
use connlib_shared::{
    control::Reference,
    messages::{GatewayId, Key, Relay, RequestConnection, ResourceId, ReuseConnection},
    Callbacks,
};
use rand_core::OsRng;
use secrecy::Secret;
use webrtc::{
    data_channel::data_channel_init::RTCDataChannelInit,
    peer_connection::{
        peer_connection_state::RTCPeerConnectionState,
        sdp::session_description::RTCSessionDescription, RTCPeerConnection,
    },
};

use crate::{peer::Peer, ClientState, Error, PeerConfig, Request, Result, Tunnel};

#[tracing::instrument(level = "trace", skip(tunnel))]
fn handle_connection_state_update<CB>(
    tunnel: &Arc<Tunnel<CB, ClientState>>,
    state: RTCPeerConnectionState,
    gateway_id: GatewayId,
    resource_id: ResourceId,
) where
    CB: Callbacks + 'static,
{
    tracing::trace!("peer_state");
    if state == RTCPeerConnectionState::Failed {
        tunnel.role_state.lock().on_connection_failed(resource_id);
        tunnel.peer_connections.lock().remove(&gateway_id.into());
    }
}

#[tracing::instrument(level = "trace", skip(tunnel))]
fn set_connection_state_update<CB>(
    tunnel: &Arc<Tunnel<CB, ClientState>>,
    peer_connection: &Arc<RTCPeerConnection>,
    gateway_id: GatewayId,
    resource_id: ResourceId,
) where
    CB: Callbacks + 'static,
{
    let tunnel = Arc::clone(tunnel);
    peer_connection.on_peer_connection_state_change(Box::new(
        move |state: RTCPeerConnectionState| {
            let tunnel = Arc::clone(&tunnel);
            Box::pin(async move {
                handle_connection_state_update(&tunnel, state, gateway_id, resource_id)
            })
        },
    ));
}

impl<CB> Tunnel<CB, ClientState>
where
    CB: Callbacks + 'static,
{
    /// Initiate an ice connection request.
    ///
    /// Given a resource id and a list of relay creates a [RequestConnection]
    /// and prepares the tunnel to handle the connection once initiated.
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
        resource_id: ResourceId,
        gateway_id: GatewayId,
        relays: Vec<Relay>,
        reference: Option<Reference>,
    ) -> Result<Request> {
        tracing::trace!("request_connection");

        let reference: usize = reference
            .ok_or(Error::InvalidReference)?
            .parse()
            .map_err(|_| Error::InvalidReference)?;

        let resource_description =
            self.role_state
                .lock()
                .on_new_connection(resource_id, gateway_id, reference)?;

        if resource_description
            .ips()
            .iter()
            .any(|&ip| self.peers_by_ip.read().exact_match(ip).is_some())
        {
            return Err(Error::UnexpectedConnectionDetails);
        }

        {
            let mut role_state = self.role_state.lock();

            if let Some(g) = role_state.gateway_awaiting_connection.get_mut(&gateway_id) {
                g.extend(resource_description.ips());
                return Ok(Request::ReuseConnection(ReuseConnection {
                    resource_id,
                    gateway_id,
                }));
            } else {
                role_state
                    .gateway_awaiting_connection
                    .insert(gateway_id, vec![]);
            }
        }
        {
            let found = {
                let mut peers_by_ip = self.peers_by_ip.write();
                let peer = peers_by_ip
                    .iter()
                    .find_map(|(_, p)| (p.conn_id == gateway_id.into()).then_some(p))
                    .cloned();
                if let Some(peer) = peer {
                    for ip in resource_description.ips() {
                        peer.add_allowed_ip(ip);
                        peers_by_ip.insert(ip, Arc::clone(&peer));
                    }
                    true
                } else {
                    false
                }
            };

            if found {
                self.role_state
                    .lock()
                    .awaiting_connection
                    .remove(&resource_id);
                return Ok(Request::ReuseConnection(ReuseConnection {
                    resource_id,
                    gateway_id,
                }));
            }
        }
        let peer_connection = {
            let (peer_connection, receiver) = self.new_peer_connection(relays).await?;
            self.role_state
                .lock()
                .add_waiting_ice_receiver(gateway_id, receiver);
            let peer_connection = Arc::new(peer_connection);
            let mut peer_connections = self.peer_connections.lock();
            peer_connections.insert(gateway_id.into(), Arc::clone(&peer_connection));
            peer_connection
        };

        set_connection_state_update(self, &peer_connection, gateway_id, resource_id);

        let data_channel = peer_connection
            .create_data_channel(
                "data",
                Some(RTCDataChannelInit {
                    ordered: Some(false),
                    max_retransmits: Some(0),
                    ..Default::default()
                }),
            )
            .await?;
        let d = Arc::clone(&data_channel);

        let tunnel = Arc::clone(self);

        let preshared_key = StaticSecret::random_from_rng(OsRng);
        let p_key = preshared_key.clone();
        data_channel.on_open(Box::new(move || {
            Box::pin(async move {
                tracing::trace!("new_data_channel_opened");
                let index = tunnel.next_index();
                let gateway_public_key = {
                    let mut role_state = tunnel.role_state.lock();

                    let Some(gateway_public_key) =
                        role_state.gateway_public_keys.remove(&gateway_id)
                    else {
                        role_state.awaiting_connection.remove(&resource_id);
                        role_state.gateway_awaiting_connection.remove(&gateway_id);

                        tunnel.peer_connections.lock().remove(&gateway_id.into());

                        let e = Error::ControlProtocolError;
                        tracing::warn!(err = ?e, "channel_open");
                        let _ = tunnel.callbacks.on_error(&e);
                        return;
                    };

                    gateway_public_key
                };
                let peer_config = PeerConfig {
                    persistent_keepalive: None,
                    public_key: gateway_public_key,
                    ips: resource_description.ips(),
                    preshared_key: SecretKey::new(Key(p_key.to_bytes())),
                };

                d.on_close(tunnel.clone().on_dc_close_handler(index, gateway_id.into()));

                let peer = Arc::new(Peer::new(
                    tunnel.private_key.clone(),
                    index,
                    peer_config.clone(),
                    d.detach().await.expect("only fails if not opened or not enabled, both of which are always true for us"),
                    gateway_id.into(),
                    None,
                ));

                {
                    let mut role_state = tunnel.role_state.lock();
                    // Watch out! we need 2 locks, make sure you don't lock both at the same time anywhere else
                    let mut peers_by_ip = tunnel.peers_by_ip.write();

                    if let Some(awaiting_ips) =
                        role_state.gateway_awaiting_connection.remove(&gateway_id)
                    {
                        for ip in awaiting_ips {
                            peer.add_allowed_ip(ip);
                            peers_by_ip.insert(ip, Arc::clone(&peer));
                        }
                    }

                    for ip in peer_config.ips {
                        peers_by_ip.insert(ip, Arc::clone(&peer));
                    }
                }

                if let Some(conn) = tunnel.peer_connections.lock().get(&gateway_id.into()) {
                    conn.on_peer_connection_state_change(
                        tunnel
                            .clone()
                            .on_peer_connection_state_change_handler(index, gateway_id.into()),
                    );
                }

                tokio::spawn(tunnel.clone().start_peer_handler(peer));

                tunnel
                    .role_state
                    .lock()
                    .awaiting_connection
                    .remove(&resource_id);
            })
        }));

        let offer = peer_connection.create_offer(None).await?;
        peer_connection.set_local_description(offer.clone()).await?;

        Ok(Request::NewConnection(RequestConnection {
            resource_id,
            gateway_id,
            client_preshared_key: Secret::new(Key(preshared_key.to_bytes())),
            client_rtc_session_description: offer,
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
    pub async fn received_offer_response(
        self: &Arc<Self>,
        resource_id: ResourceId,
        rtc_sdp: RTCSessionDescription,
        gateway_public_key: PublicKey,
    ) -> Result<()> {
        let gateway_id = self
            .role_state
            .lock()
            .gateway_by_resource(&resource_id)
            .ok_or(Error::UnknownResource)?;
        let peer_connection = self
            .peer_connections
            .lock()
            .get(&gateway_id.into())
            .ok_or(Error::UnknownResource)?
            .clone();
        peer_connection.set_remote_description(rtc_sdp).await?;

        self.role_state
            .lock()
            .activate_ice_candidate_receiver(gateway_id, gateway_public_key);

        Ok(())
    }
}
