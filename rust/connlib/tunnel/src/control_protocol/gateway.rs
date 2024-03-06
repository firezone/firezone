use crate::{
    dns::is_subdomain,
    peer::{PacketTransformGateway, Peer},
    utils::{stun, turn},
    Error, GatewayState, Tunnel,
};
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

impl<CB> Tunnel<CB, GatewayState, Server, ClientId>
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

    fn new_peer(
        &mut self,
        ips: Vec<IpNetwork>,
        client_id: ClientId,
        resource: ResourceDescription,
        expires_at: Option<DateTime<Utc>>,
        resource_addresses: Vec<IpNetwork>,
    ) -> Result<()> {
        tracing::trace!(?ips, "new_data_channel_open");

        let mut peer = Peer::new(client_id, PacketTransformGateway::default(), &ips, ());

        for address in resource_addresses {
            peer.transform
                .add_resource(address, resource.clone(), expires_at);
        }

        self.role_state.peers.insert(peer, &ips);

        Ok(())
    }
}
