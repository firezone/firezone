use crate::{
    peer::Peer, peer_handler, ConnectedPeer, GatewayState, PeerConfig, Tunnel, PEER_QUEUE_SIZE,
};

use chrono::{DateTime, Utc};
use connlib_shared::{
    messages::{ClientId, Relay, ResourceDescription},
    Callbacks, Error, Result,
};
use std::sync::Arc;
use webrtc::ice_transport::{
    ice_parameters::RTCIceParameters, ice_role::RTCIceRole, RTCIceTransport,
};

use super::{new_ice_connection, IceConnection};

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

        self.peer_connections
            .lock()
            .insert(client_id, Arc::clone(&ice));

        ice.on_connection_state_change(Box::new(|_| Box::pin(async {})));

        let tunnel = self.clone();
        tokio::spawn(async move {
            if let Err(e) = ice
                .start(&remote_params, Some(RTCIceRole::Controlled))
                .await
            {
                tracing::warn!(%client_id, err = ?e, "Can't start ice connection: {e:#}");
                tunnel.peer_connections.lock().remove(&client_id);
                let _ = ice.stop().await;
                return;
            }

            if let Err(e) = tunnel
                .new_tunnel(peer, client_id, resource, expires_at, ice)
                .await
            {
                // TODO: cleanup
                tracing::warn!(%client_id, err = ?e, "Can't start tunnel: {e:#}")
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

    async fn new_tunnel(
        self: Arc<Self>,
        peer_config: PeerConfig,
        client_id: ClientId,
        resource: ResourceDescription,
        expires_at: DateTime<Utc>,
        ice: Arc<RTCIceTransport>,
    ) -> Result<()> {
        tracing::trace!(?peer_config.ips, "new_data_channel_open");
        {
            let device = self.device.load().clone().ok_or(Error::NoIface)?;
            for &ip in &peer_config.ips {
                assert!(device.add_route(ip, self.callbacks()).await?.is_none(),  "gateway does not run on android and thus never produces a new device upon `add_route`");
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

        // Holding two mutexes here
        let ep = ice
            .new_endpoint(Box::new(|_| true))
            .await
            .ok_or(Error::ControlProtocolError)?;
        let (peer_queue, peer_receiver) = tokio::sync::mpsc::channel(PEER_QUEUE_SIZE);
        self.role_state
            .lock()
            .peer_queue
            .insert(client_id, peer_queue);

        tokio::spawn({
            let ep = ep.clone();
            async move {
                peer_handler::handle_packet(ep, peer_receiver).await;
            }
        });

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
        }

        tokio::spawn(self.clone().start_peer_handler(peer, ep));
        Ok(())
    }
}
