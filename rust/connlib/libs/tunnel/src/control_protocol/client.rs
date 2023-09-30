use std::sync::Arc;

use boringtun::x25519::{PublicKey, StaticSecret};
use chrono::{DateTime, Utc};
use libs_common::messages::SecretKey;
use libs_common::{
    control::Reference,
    messages::{
        ClientId, GatewayId, Key, Relay, RequestConnection, ResourceDescription, ResourceId,
        ReuseConnection,
    },
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

use crate::{ControlSignal, Error, PeerConfig, Request, Result, Tunnel};

#[tracing::instrument(level = "trace", skip(tunnel))]
fn handle_connection_state_update<C, CB>(
    tunnel: &Arc<Tunnel<C, CB>>,
    state: RTCPeerConnectionState,
    gateway_id: GatewayId,
    resource_id: ResourceId,
) where
    C: ControlSignal + Clone + Send + Sync + 'static,
    CB: Callbacks + 'static,
{
    tracing::trace!("peer_state");
    if state == RTCPeerConnectionState::Failed {
        tunnel
            .awaiting_connection
            .lock()
            .remove(&resource_id.into());
        tunnel.peer_connections.lock().remove(&gateway_id.into());
        tunnel
            .gateway_awaiting_connection
            .lock()
            .remove(&gateway_id);
    }
}

#[tracing::instrument(level = "trace", skip(tunnel))]
fn set_connection_state_update<C, CB>(
    tunnel: &Arc<Tunnel<C, CB>>,
    peer_connection: &Arc<RTCPeerConnection>,
    gateway_id: GatewayId,
    resource_id: ResourceId,
) where
    C: ControlSignal + Clone + Send + Sync + 'static,
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

impl<C, CB> Tunnel<C, CB>
where
    C: ControlSignal + Clone + Send + Sync + 'static,
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
        let resource_description = self
            .resources
            .read()
            .get_by_id(&resource_id)
            .ok_or(Error::UnknownResource)?
            .clone();

        let reference: usize = reference
            .ok_or(Error::InvalidReference)?
            .parse()
            .map_err(|_| Error::InvalidReference)?;
        {
            let mut awaiting_connections = self.awaiting_connection.lock();
            let Some(awaiting_connection) = awaiting_connections.get_mut(&resource_id.into())
            else {
                return Err(Error::UnexpectedConnectionDetails);
            };
            awaiting_connection.response_received = true;
            if awaiting_connection.total_attemps != reference
                || resource_description
                    .ips()
                    .iter()
                    .any(|&ip| self.peers_by_ip.read().exact_match(ip).is_some())
            {
                return Err(Error::UnexpectedConnectionDetails);
            }
        }

        self.resources_gateways
            .lock()
            .insert(resource_id, gateway_id);
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
                self.awaiting_connection.lock().remove(&resource_id.into());
                return Ok(Request::ReuseConnection(ReuseConnection {
                    resource_id,
                    gateway_id,
                }));
            }
        }
        let peer_connection = {
            let peer_connection = Arc::new(
                self.initialize_peer_request(relays, gateway_id.into())
                    .await?,
            );
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
                let Some(gateway_public_key) =
                    tunnel.gateway_public_keys.lock().remove(&gateway_id)
                else {
                    tunnel
                        .awaiting_connection
                        .lock()
                        .remove(&resource_id.into());
                    tunnel.peer_connections.lock().remove(&gateway_id.into());
                    tunnel
                        .gateway_awaiting_connection
                        .lock()
                        .remove(&gateway_id);
                    let e = Error::ControlProtocolError;
                    tracing::warn!(err = ?e, "channel_open");
                    let _ = tunnel.callbacks.on_error(&e);
                    return;
                };
                let peer_config = PeerConfig {
                    persistent_keepalive: None,
                    public_key: gateway_public_key,
                    ips: resource_description.ips(),
                    preshared_key: SecretKey::new(Key(p_key.to_bytes())),
                };

                if let Err(e) = tunnel
                    .handle_channel_open(d, index, peer_config, gateway_id.into(), None)
                    .await
                {
                    tracing::error!(err = ?e, "channel_open");
                    let _ = tunnel.callbacks.on_error(&e);
                    tunnel.peer_connections.lock().remove(&gateway_id.into());
                    tunnel
                        .gateway_awaiting_connection
                        .lock()
                        .remove(&gateway_id);
                }
                tunnel
                    .awaiting_connection
                    .lock()
                    .remove(&resource_id.into());
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
        let gateway_id = *self
            .resources_gateways
            .lock()
            .get(&resource_id)
            .ok_or(Error::UnknownResource)?;
        let peer_connection = self
            .peer_connections
            .lock()
            .get(&gateway_id.into())
            .ok_or(Error::UnknownResource)?
            .clone();
        self.gateway_public_keys
            .lock()
            .insert(gateway_id, gateway_public_key);

        peer_connection.set_remote_description(rtc_sdp).await?;
        self.start_ice_candidate_handler(gateway_id.into())?;

        Ok(())
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
