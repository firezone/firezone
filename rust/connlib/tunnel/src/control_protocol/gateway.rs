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
    /// An [RTCIceParameters] of the local sdp, with candidates gathered.
    pub async fn set_peer_connection_request(
        self: &Arc<Self>,
        remote_params: RTCIceParameters,
        domain: Option<String>,
        peer: PeerConfig,
        relays: Vec<Relay>,
        client_id: ClientId,
        expires_at: DateTime<Utc>,
        resource: ResourceDescription,
    ) -> Result<RTCIceParameters> {
        let IceConnection {
            ice_parameters: local_params,
            ice_transport: ice,
            ice_candidate_rx,
        } = new_ice_connection(&self.webrtc_api, relays).await?;
        self.role_state
            .lock()
            .add_new_ice_receiver(client_id, ice_candidate_rx);

        self.peer_connections
            .lock()
            .insert(client_id, Arc::clone(&ice));

        let tunnel = self.clone();
        tokio::spawn(async move {
            if let Err(e) = ice
                .start(&remote_params, Some(RTCIceRole::Controlled))
                .await
                .map_err(Into::into)
                .and_then(|_| tunnel.new_tunnel(peer, client_id, resource, expires_at, ice))
            {
                tracing::warn!(%client_id, err = ?e, "Can't start tunnel: {e:#}");
                let peer_connection = tunnel.peer_connections.lock().remove(&client_id);
                if let Some(peer_connection) = peer_connection {
                    let _ = peer_connection.stop().await;
                }
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
            peer.inner.add_resource(todo!(), resource, expires_at);
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
        let ips = peer_config.ips.clone();
        // Worst thing if this is not run before peers_by_ip is that some packets are lost to the default route
        tokio::spawn(async move {
            for ip in ips {
                if let Ok(res) = device.add_route(ip, &callbacks).await {
                    assert!(res.is_none(),  "gateway does not run on android and thus never produces a new device upon `add_route`");
                }
            }
        });

        let peer = Arc::new(Peer::new(
            self.private_key.clone(),
            self.next_index(),
            peer_config.clone(),
            client_id,
            self.rate_limiter.clone(),
        ));

        peer.add_resource(todo!(), resource, expires_at);

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
