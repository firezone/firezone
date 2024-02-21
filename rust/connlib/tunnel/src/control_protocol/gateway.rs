use crate::{
    control_protocol::insert_peers,
    dns::is_subdomain,
    peer::{PacketTransformGateway, Peer},
    Error, GatewayState, Tunnel,
};

use super::{stun, turn};
use boringtun::x25519::PublicKey;
use chrono::{DateTime, Utc};
use connlib_shared::{
    messages::{
        Answer, ClientId, ConnectionAccepted, DomainResponse, Key, Offer, Relay, ResourceId,
    },
    Callbacks, Dname, Result,
};
use ip_network::IpNetwork;
use secrecy::{ExposeSecret as _, Secret};
use snownet::{Credentials, Server};
use std::sync::Arc;

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

impl<CB> Tunnel<CB, GatewayState, Server, ClientId, PacketTransformGateway>
where
    CB: Callbacks + 'static,
{
    /// Accept a connection request from a client.
    ///
    /// Sets a connection to a remote SDP, creates the local SDP
    /// and returns it.
    ///
    /// # Returns
    /// The connection details
    #[allow(clippy::too_many_arguments)]
    pub fn set_peer_connection_request(
        &mut self,
        client: ClientId,
        key: Secret<Key>,
        offer: Offer,
        gateway: PublicKey,
        ips: Vec<IpNetwork>,
        relays: Vec<Relay>,
        domain: Option<Dname>,
        expires_at: Option<DateTime<Utc>>,
        resource: ResourceDescription,
    ) -> Result<ConnectionAccepted> {
        let resource_addresses = match &resource {
            ResourceDescription::Dns(r) => {
                let Some(domain) = domain.clone() else {
                    return Err(Error::ControlProtocolError);
                };

                if !is_subdomain(&domain, &r.domain) {
                    return Err(Error::InvalidResource);
                }

                r.addresses.clone()
            }
            ResourceDescription::Cidr(ref cidr) => vec![cidr.address],
        };

        let answer = self.connections_state.node.accept_connection(
            client,
            snownet::Offer {
                session_key: key.expose_secret().0.into(),
                credentials: Credentials {
                    username: offer.username,
                    password: offer.password,
                },
            },
            gateway,
            stun(&relays, |addr| {
                self.connections_state.sockets.can_handle(addr)
            }),
            turn(&relays, |addr| {
                self.connections_state.sockets.can_handle(addr)
            }),
        );

        self.new_peer(
            ips,
            client,
            resource,
            expires_at,
            resource_addresses.clone(),
        )?;

        tracing::info!(%client, gateway = %hex::encode(gateway.as_bytes()), "Connection is ready");

        Ok(ConnectionAccepted {
            ice_parameters: Answer {
                username: answer.credentials.username,
                password: answer.credentials.password,
            },
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
        &mut self,
        resource: ResourceDescription,
        client: ClientId,
        expires_at: Option<DateTime<Utc>>,
        domain: Option<Dname>,
    ) -> Option<DomainResponse> {
        let Some(peer) = self
            .role_state
            .peers_by_ip
            .iter_mut()
            .find_map(|(_, p)| (p.conn_id == client).then_some(p.clone()))
        else {
            return None;
        };

        let (addresses, resource_id) = match &resource {
            ResourceDescription::Dns(r) => {
                let Some(domain) = domain.clone() else {
                    return None;
                };

                if !is_subdomain(&domain, &r.domain) {
                    return None;
                }

                (r.addresses.clone(), r.id)
            }
            ResourceDescription::Cidr(cidr) => (vec![cidr.address], cidr.id),
        };

        for address in &addresses {
            peer.transform
                .add_resource(*address, resource.clone(), expires_at);
        }

        tracing::info!(%client, resource = %resource_id, expires = ?expires_at.map(|e| e.to_rfc3339()), "Allowing access to resource");

        if let Some(domain) = domain {
            return Some(DomainResponse {
                domain,
                address: addresses.iter().map(|i| i.network_address()).collect(),
            });
        }

        None
    }

    fn new_peer(
        &mut self,
        ips: Vec<IpNetwork>,
        client_id: ClientId,
        resource: ResourceDescription,
        expires_at: Option<DateTime<Utc>>,
        resource_addresses: Vec<IpNetwork>,
    ) -> Result<()> {
        tracing::trace!(?ips, "new_data_channel_open");

        let peer = Arc::new(Peer::new(
            ips.clone(),
            client_id,
            PacketTransformGateway::default(),
        ));

        for address in resource_addresses {
            peer.transform
                .add_resource(address, resource.clone(), expires_at);
        }

        // cleaning up old state
        self.role_state
            .peers_by_ip
            .retain(|_, p| p.conn_id != client_id);
        self.connections_state
            .peers_by_id
            .insert(client_id, Arc::clone(&peer));
        insert_peers(&mut self.role_state.peers_by_ip, &ips, peer);

        Ok(())
    }
}
