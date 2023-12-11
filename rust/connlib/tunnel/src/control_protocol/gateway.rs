use crate::{
    control_protocol::{insert_peers, start_handlers},
    peer::Peer,
    ConnectedPeer, GatewayState, PeerConfig, Tunnel, PEER_QUEUE_SIZE,
};

use chrono::{DateTime, Utc};
use connlib_shared::{
    messages::{ClientId, Relay, ResourceDescription},
    Callbacks, Error, Result,
};
use std::sync::Arc;
use webrtc::ice_transport::{
    ice_parameters::RTCIceParameters, ice_role::RTCIceRole,
    ice_transport_state::RTCIceTransportState, RTCIceTransport,
};

use super::{new_ice_connection, IceConnection};

#[tracing::instrument(level = "trace", skip(ice))]
fn set_connection_state_update(ice: &Arc<RTCIceTransport>, client_id: ClientId) {
    let ice = ice.clone();
    ice.on_connection_state_change({
        let ice = ice.clone();
        Box::new(move |state| {
            tracing::trace!(%state, "peer_state");
            let ice = ice.clone();
            Box::pin(async move {
                if state == RTCIceTransportState::Failed {
                    if let Err(e) = ice.stop().await {
                        tracing::warn!(err = ?e, "Couldn't stop ice client: {e:#}");
                    }
                }
            })
        })
    });
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
    /// An [RTCIceParameters] of the local sdp, with candidates gathered.
    pub async fn set_peer_connection_request(
        self: &Arc<Self>,
        remote_params: RTCIceParameters,
        peer: PeerConfig,
        relays: Vec<Relay>,
        client_id: ClientId,
        expires_at: DateTime<Utc>,
        resource: ResourceDescription,
    ) -> Result<RTCIceParameters> {
        let IceConnection {
            ice_params: local_params,
            ice_transport: ice,
            ice_candidate_rx,
        } = new_ice_connection(&self.webrtc_api, relays).await?;
        self.role_state
            .lock()
            .add_new_ice_receiver(client_id, ice_candidate_rx);

        set_connection_state_update(&ice, client_id);

        let previous_ice = self
            .peer_connections
            .lock()
            .insert(client_id, Arc::clone(&ice));

        if let Some(ice) = previous_ice {
            // If we had a previous on-going connection we stop it.
            // Note that ice.stop also closes the gatherer.
            // we only have to do this on the gateway because clients can query
            // twice for initiating connections since they can close/reopen suddenly
            // however, gateways never initiate connection requests
            let _ = ice.stop().await;
        }

        let tunnel = self.clone();
        tokio::spawn(async move {
            if let Err(e) = ice
                .start(&remote_params, Some(RTCIceRole::Controlled))
                .await
                .map_err(Into::into)
                .and_then(|_| tunnel.new_tunnel(peer, client_id, resource, expires_at, ice.clone()))
            {
                tracing::warn!(%client_id, err = ?e, "Can't start tunnel: {e:#}");
                {
                    let mut peer_connections = tunnel.peer_connections.lock();
                    if let Some(peer_connection) = peer_connections.get(&client_id).cloned() {
                        // We need to re-check this since it might have been replaced in between.
                        if matches!(
                            peer_connection.state(),
                            RTCIceTransportState::Failed
                                | RTCIceTransportState::Disconnected
                                | RTCIceTransportState::Closed
                        ) {
                            peer_connections.remove(&client_id);
                        }
                    }
                }
                // We only need to stop here because in case tunnel.new_tunnel failed.
                let _ = ice.stop().await;
            }
        });

        Ok(local_params)
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

    fn new_tunnel(
        &self,
        peer_config: PeerConfig,
        client_id: ClientId,
        resource: ResourceDescription,
        expires_at: DateTime<Utc>,
        ice: Arc<RTCIceTransport>,
    ) -> Result<()> {
        tracing::trace!(?peer_config.ips, "new_data_channel_open");
        let device = self.device.load().clone().ok_or(Error::NoIface)?;
        let callbacks = self.callbacks.clone();
        for ip in &peer_config.ips {
            if let Ok(res) = device.add_route(*ip, &callbacks) {
                assert!(res.is_none(),  "gateway does not run on android and thus never produces a new device upon `add_route`");
            }
        }

        let peer = Arc::new(Peer::new(
            self.private_key.clone(),
            self.next_index(),
            peer_config.clone(),
            client_id,
            Some((resource, expires_at)),
            self.rate_limiter.clone(),
        ));

        let (peer_sender, peer_receiver) = tokio::sync::mpsc::channel(PEER_QUEUE_SIZE);

        start_handlers(
            Arc::clone(&self.device),
            self.callbacks.clone(),
            peer.clone(),
            ice,
            peer_receiver,
        );

        insert_peers(
            &mut self.peers_by_ip.write(),
            &peer_config.ips,
            ConnectedPeer {
                inner: peer,
                channel: peer_sender,
            },
        );

        Ok(())
    }
}
