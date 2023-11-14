use std::sync::Arc;

use boringtun::x25519::{PublicKey, StaticSecret};
use connlib_shared::{
    control::Reference,
    messages::{GatewayId, Key, Relay, RequestConnection, ResourceId},
    Callbacks,
};
use rand_core::OsRng;
use secrecy::Secret;
use webrtc::ice_transport::{
    ice_parameters::RTCIceParameters, ice_role::RTCIceRole,
    ice_transport_state::RTCIceTransportState, RTCIceTransport,
};

use crate::{
    control_protocol::{
        new_ice_connection, on_peer_connection_state_change_handler, IceConnection,
    },
    peer_handler, PEER_QUEUE_SIZE,
};
use crate::{peer::Peer, ClientState, ConnectedPeer, Error, Request, Result, Tunnel};

#[tracing::instrument(level = "trace", skip(tunnel, ice))]
fn set_connection_state_update<CB>(
    tunnel: &Arc<Tunnel<CB, ClientState>>,
    ice: &Arc<RTCIceTransport>,
    gateway_id: GatewayId,
    resource_id: ResourceId,
) where
    CB: Callbacks + 'static,
{
    let tunnel = Arc::clone(tunnel);
    ice.on_connection_state_change(Box::new(move |state| {
        let tunnel = Arc::clone(&tunnel);
        tracing::trace!(%state, "peer_state");
        Box::pin(async move {
            if state == RTCIceTransportState::Failed {
                // There's a really unlikely race condition but this line needs to be before on_connection_failed.
                // if we clear up the gateway awaiting flag before removing the connection a new connection could be
                // established that replaces this one and this line removes it.
                let ice = tunnel.peer_connections.lock().remove(&gateway_id);

                if let Some(ice) = ice {
                    if let Err(err) = ice.stop().await {
                        tracing::warn!(%err, "couldn't stop ice transport: {err:#}");
                    }
                }

                tunnel.role_state.lock().on_connection_failed(resource_id);
            }
        })
    }));
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

        if let Some(connection) = self.role_state.lock().attempt_to_reuse_connection(
            resource_id,
            gateway_id,
            reference,
            &mut self.peers_by_ip.write(),
        )? {
            return Ok(Request::ReuseConnection(connection));
        }

        let IceConnection {
            ice_params,
            ice_transport,
            ice_candidate_rx,
        } = new_ice_connection(&self.webrtc_api, relays).await?;
        self.role_state
            .lock()
            .add_waiting_ice_receiver(gateway_id, ice_candidate_rx);
        {
            let mut peer_connections = self.peer_connections.lock();
            peer_connections.insert(gateway_id, Arc::clone(&ice_transport));
        }

        set_connection_state_update(self, &ice_transport, gateway_id, resource_id);
        let preshared_key = StaticSecret::random_from_rng(OsRng);
        self.role_state
            .lock()
            .gateway_preshared_keys
            .insert(gateway_id, preshared_key.clone());

        Ok(Request::NewConnection(RequestConnection {
            resource_id,
            gateway_id,
            client_preshared_key: Secret::new(Key(preshared_key.to_bytes())),
            client_rtc_session_description: ice_params,
        }))
    }

    async fn new_tunnel(
        self: &Arc<Self>,
        resource_id: ResourceId,
        gateway_id: GatewayId,
        ice: &RTCIceTransport,
    ) -> Result<()> {
        let p_key = self
            .role_state
            .lock()
            .gateway_preshared_keys
            .get(&gateway_id)
            .ok_or(Error::ControlProtocolError)?
            .clone();
        let index = self.next_index();

        let peer_config = self
            .role_state
            .lock()
            .create_peer_config_for_new_connection(resource_id, gateway_id, p_key)?;

        let peer = Arc::new(Peer::new(
            self.private_key.clone(),
            index,
            peer_config.clone(),
            gateway_id,
            None,
            self.rate_limiter.clone(),
        ));

        let ep = ice
            .new_endpoint(Box::new(|_| true))
            .await
            .ok_or(Error::ControlProtocolError)?;

        let (peer_sender, peer_receiver) = tokio::sync::mpsc::channel(PEER_QUEUE_SIZE);

        tokio::spawn({
            let ep = ep.clone();
            async move {
                peer_handler::handle_packet(ep, peer_receiver).await;
            }
        });

        ice.on_connection_state_change(on_peer_connection_state_change_handler(
            gateway_id,
            self.stop_peer_command_sender.clone(),
        ));

        self.role_state
            .lock()
            .peer_queue
            .insert(gateway_id, peer_sender);

        {
            let mut peers_by_ip = self.peers_by_ip.write();

            for ip in peer_config.ips {
                peers_by_ip.insert(
                    ip,
                    ConnectedPeer {
                        inner: peer.clone(),
                        channel: ep.clone(),
                    },
                );
            }

            self.role_state
                .lock()
                .gateway_awaiting_connection
                .remove(&gateway_id);
        }

        tokio::spawn(self.start_peer_handler(peer, ep));

        self.role_state
            .lock()
            .awaiting_connection
            .remove(&resource_id);

        Ok(())
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
        rtc_ice_params: RTCIceParameters,
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
            .get(&gateway_id)
            .ok_or(Error::UnknownResource)?
            .clone();

        self.role_state
            .lock()
            .activate_ice_candidate_receiver(gateway_id, gateway_public_key);
        let tunnel = self.clone();
        // RTCIceTransport::start blocks until there's an ice connection.
        tokio::spawn(async move {
            if let Err(e) = peer_connection
                .start(&rtc_ice_params, Some(RTCIceRole::Controlling))
                .await
            {
                tracing::warn!(%gateway_id, err = ?e, "Can't start ice connection: {e:#}")
            }

            if let Err(e) = tunnel
                .new_tunnel(resource_id, gateway_id, &peer_connection)
                .await
            {
                tracing::warn!(%gateway_id, err = ?e, "Can't start tunnel: {e:#}")
            }
        });

        Ok(())
    }
}
