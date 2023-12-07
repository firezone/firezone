use crate::{
    control_protocol::{insert_peers, start_handlers},
    peer::{PacketTransformGateway, Peer},
    ConnectedPeer, GatewayState, PeerConfig, Tunnel, PEER_QUEUE_SIZE,
};

use chrono::{DateTime, Utc};
use connlib_shared::{
    messages::{
        ClientId, ConnectionAccepted, DomainResponse, Relay, ResourceAccepted, ResourceDescription,
    },
    Callbacks, Error, Result,
};
use ip_network::IpNetwork;
use std::{net::ToSocketAddrs, sync::Arc};
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
    ) -> Result<ConnectionAccepted> {
        tracing::trace!("domain: {domain:?}");
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
        let resource_addresses = match &resource {
            ResourceDescription::Dns(_) => {
                let Some(domain) = domain.clone() else {
                    return Err(Error::ControlProtocolError);
                };
                (domain, 0)
                    .to_socket_addrs()?
                    .map(|addrs| addrs.ip().into())
                    .collect()
            }
            ResourceDescription::Cidr(ref cidr) => vec![cidr.address],
        };
        {
            let resource_addresses = resource_addresses.clone();
            tokio::spawn(async move {
                if let Err(e) = ice
                    .start(&remote_params, Some(RTCIceRole::Controlled))
                    .await
                    .map_err(Into::into)
                    .and_then(|_| {
                        tunnel.new_tunnel(
                            peer,
                            client_id,
                            resource,
                            expires_at,
                            ice,
                            resource_addresses,
                        )
                    })
                {
                    tracing::warn!(%client_id, err = ?e, "Can't start tunnel: {e:#}");
                    let peer_connection = tunnel.peer_connections.lock().remove(&client_id);
                    if let Some(peer_connection) = peer_connection {
                        let _ = peer_connection.stop().await;
                    }
                }
            });
        }

        let response = ConnectionAccepted {
            ice_parameters: local_params,
            domain_response: domain.map(|domain| DomainResponse {
                domain,
                address: resource_addresses
                    .into_iter()
                    .map(|ip| ip.network_address())
                    .collect(),
            }),
        };
        Ok(response)
    }

    pub fn allow_access(
        &self,
        resource: ResourceDescription,
        client_id: ClientId,
        expires_at: DateTime<Utc>,
        // TODO: we could put the domain inside the ResourceDescription
        domain: Option<String>,
    ) -> Option<ResourceAccepted> {
        tracing::trace!(?resource);
        tracing::trace!(?domain);
        if let Some((_, peer)) = self
            .role_state
            .lock()
            .peers_by_ip
            .iter_mut()
            .find(|(_, p)| p.inner.conn_id == client_id)
        {
            tracing::trace!("found peer");
            let addresses = match &resource {
                ResourceDescription::Dns(_) => {
                    tracing::trace!("it's a dns resource");
                    let Some(ref domain) = domain else {
                        return None;
                    };

                    (domain.clone(), 0)
                        .to_socket_addrs()
                        .ok()?
                        .map(|a| a.ip())
                        .map(Into::into)
                        .collect()
                }
                ResourceDescription::Cidr(cidr) => vec![cidr.address],
            };
            tracing::trace!("{addresses:?}");
            for address in &addresses {
                tracing::trace!("adding address {address}");
                peer.inner
                    .transform
                    .add_resource(*address, resource.clone(), expires_at);
            }
            if let Some(domain) = domain {
                tracing::trace!("sending response");
                return Some(ResourceAccepted {
                    domain_response: DomainResponse {
                        domain,
                        address: addresses.iter().map(|i| i.network_address()).collect(),
                    },
                });
            }
        }
        None
    }

    fn new_tunnel(
        &self,
        peer_config: PeerConfig,
        client_id: ClientId,
        resource: ResourceDescription,
        expires_at: DateTime<Utc>,
        ice: Arc<RTCIceTransport>,
        resource_addresses: Vec<IpNetwork>,
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
            PacketTransformGateway::new(),
        ));

        for address in resource_addresses {
            peer.transform
                .add_resource(address, resource.clone(), expires_at);
        }

        let (peer_sender, peer_receiver) = tokio::sync::mpsc::channel(PEER_QUEUE_SIZE);

        start_handlers(
            Arc::clone(&self.device),
            self.callbacks.clone(),
            peer.clone(),
            ice,
            peer_receiver,
        );

        insert_peers(
            &mut self.role_state.lock().peers_by_ip,
            &peer_config.ips,
            ConnectedPeer {
                inner: peer,
                channel: peer_sender,
            },
        );

        Ok(())
    }
}
