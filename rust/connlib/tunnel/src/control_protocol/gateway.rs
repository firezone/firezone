use crate::{
    control_protocol::{insert_peers, start_handlers},
    dns::is_subdomain,
    peer::{PacketTransformGateway, Peer},
    ConnectedPeer, Error, GatewayState, PeerConfig, Tunnel, PEER_QUEUE_SIZE,
};

use chrono::{DateTime, Utc};
use connlib_shared::{
    messages::{ClientId, ConnectionAccepted, DomainResponse, Relay, ResourceId},
    Callbacks, Dname, Result,
};
use ip_network::IpNetwork;
use std::sync::Arc;
use webrtc::ice_transport::{
    ice_parameters::RTCIceParameters, ice_role::RTCIceRole,
    ice_transport_state::RTCIceTransportState, RTCIceTransport,
};

/// Description of a resource that maps to a DNS record which had its domain already resolved.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ResolvedResourceDescriptionDns {
    pub id: ResourceId,
    /// Internal resource's domain name.
    pub domain: String,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,

    pub addresses: Vec<IpNetwork>,
}

pub type ResourceDescription =
    connlib_shared::messages::ResourceDescription<ResolvedResourceDescriptionDns>;

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
    /// The connection details
    #[allow(clippy::too_many_arguments)]
    pub async fn set_peer_connection_request(
        self: &Arc<Self>,
        ice_parameters: RTCIceParameters,
        peer: PeerConfig,
        relays: Vec<Relay>,
        client_id: ClientId,
        domain: Option<Dname>,
        expires_at: Option<DateTime<Utc>>,
        resource: ResourceDescription,
    ) -> Result<ConnectionAccepted> {
        let IceConnection {
            ice_parameters: local_params,
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

        let resource_addresses = match &resource {
            ResourceDescription::Dns(r) => {
                let Some(domain) = domain.clone() else {
                    return Err(Error::ControlProtocolError);
                };

                if !is_subdomain(&domain, &r.domain) {
                    let _ = ice.stop().await;
                    return Err(Error::InvalidResource);
                }

                r.addresses.clone()
            }
            ResourceDescription::Cidr(ref cidr) => vec![cidr.address],
        };

        {
            let resource_addresses = resource_addresses.clone();
            let tunnel = self.clone();
            tokio::spawn(async move {
                if let Err(e) = ice
                    .start(&ice_parameters, Some(RTCIceRole::Controlled))
                    .await
                    .map_err(Into::into)
                    .and_then(|_| {
                        tunnel.new_tunnel(
                            peer,
                            client_id,
                            resource,
                            expires_at,
                            ice.clone(),
                            resource_addresses,
                        )
                    })
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
        }

        Ok(ConnectionAccepted {
            ice_parameters: local_params,
            domain_response: domain.map(|domain| DomainResponse {
                domain,
                address: resource_addresses
                    .into_iter()
                    .map(|ip| ip.network_address())
                    .collect(),
            }),
        })
    }

    pub fn allow_access(
        &self,
        resource: ResourceDescription,
        client_id: ClientId,
        expires_at: Option<DateTime<Utc>>,
        domain: Option<Dname>,
    ) -> Option<DomainResponse> {
        let Some(peer) = self
            .role_state
            .lock()
            .peers_by_ip
            .iter_mut()
            .find_map(|(_, p)| (p.inner.conn_id == client_id).then_some(p.inner.clone()))
        else {
            return None;
        };

        let addresses = match &resource {
            ResourceDescription::Dns(r) => {
                let Some(domain) = domain.clone() else {
                    return None;
                };

                if !is_subdomain(&domain, &r.domain) {
                    return None;
                }

                r.addresses.clone()
            }
            ResourceDescription::Cidr(cidr) => vec![cidr.address],
        };

        for address in &addresses {
            peer.transform
                .add_resource(*address, resource.clone(), expires_at);
        }

        if let Some(domain) = domain {
            return Some(DomainResponse {
                domain,
                address: addresses.iter().map(|i| i.network_address()).collect(),
            });
        }

        None
    }

    fn new_tunnel(
        self: &Arc<Self>,
        peer_config: PeerConfig,
        client_id: ClientId,
        resource: ResourceDescription,
        expires_at: Option<DateTime<Utc>>,
        ice: Arc<RTCIceTransport>,
        resource_addresses: Vec<IpNetwork>,
    ) -> Result<()> {
        tracing::trace!(?peer_config.ips, "new_data_channel_open");

        let peer = Arc::new(Peer::new(
            self.private_key.clone(),
            self.next_index(),
            peer_config.clone(),
            client_id,
            self.rate_limiter.clone(),
            PacketTransformGateway::default(),
        ));

        for address in resource_addresses {
            peer.transform
                .add_resource(address, resource.clone(), expires_at);
        }

        let (peer_sender, peer_receiver) = tokio::sync::mpsc::channel(PEER_QUEUE_SIZE);

        start_handlers(
            Arc::clone(self),
            Arc::clone(&self.device),
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
