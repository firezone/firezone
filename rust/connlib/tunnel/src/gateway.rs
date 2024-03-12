use crate::ip_packet::MutableIpPacket;
use crate::peer::{PacketTransformGateway, Peer};
use crate::peer_store::PeerStore;
use crate::utils::{stun, turn};
use crate::Tunnel;
use boringtun::x25519::PublicKey;
use chrono::{DateTime, Utc};
use connlib_shared::messages::{
    Answer, ClientId, ConnectionAccepted, DomainResponse, Interface as InterfaceConfig, Key, Offer,
    Relay, ResourceId,
};
use connlib_shared::{Callbacks, Dname, Error, Result};
use ip_network::IpNetwork;
use secrecy::{ExposeSecret as _, Secret};
use snownet::Server;
use std::collections::HashSet;
use std::task::{ready, Context, Poll};
use std::time::{Duration, Instant};
use tokio::time::{interval, Interval, MissedTickBehavior};

const PEERS_IPV4: &str = "100.64.0.0/11";
const PEERS_IPV6: &str = "fd00:2021:1111::/107";

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
    /// Sets the interface configuration and starts background tasks.
    #[tracing::instrument(level = "trace", skip(self))]
    pub fn set_interface(&mut self, config: &InterfaceConfig) -> connlib_shared::Result<()> {
        // Note: the dns fallback strategy is irrelevant for gateways
        let callbacks = self.callbacks().clone();
        self.io
            .device_mut()
            .initialize(config, vec![], &callbacks)?;
        self.io.device_mut().set_routes(
            HashSet::from([PEERS_IPV4.parse().unwrap(), PEERS_IPV6.parse().unwrap()]),
            &callbacks,
        )?;

        let name = self.io.device_mut().name().to_owned();

        tracing::debug!(ip4 = %config.ipv4, ip6 = %config.ipv6, %name, "TUN device initialized");

        Ok(())
    }

    /// Accept a connection request from a client.
    ///
    /// Sets a connection to a remote SDP, creates the local SDP
    /// and returns it.
    ///
    /// # Returns
    /// The connection details
    #[allow(clippy::too_many_arguments)]
    pub fn accept(
        &mut self,
        client_id: ClientId,
        key: Secret<Key>,
        offer: Offer,
        client: PublicKey,
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

                if !crate::dns::is_subdomain(&domain, &r.domain) {
                    return Err(Error::InvalidResource);
                }

                r.addresses.clone()
            }
            ResourceDescription::Cidr(ref cidr) => vec![cidr.address],
        };

        let answer = self.node.accept_connection(
            client_id,
            snownet::Offer {
                session_key: key.expose_secret().0.into(),
                credentials: snownet::Credentials {
                    username: offer.username,
                    password: offer.password,
                },
            },
            client,
            stun(&relays, |addr| self.io.sockets_ref().can_handle(addr)),
            turn(&relays, |addr| self.io.sockets_ref().can_handle(addr)),
            Instant::now(),
        );

        self.new_peer(
            ips,
            client_id,
            resource,
            expires_at,
            resource_addresses.clone(),
        )?;

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

    /// Clean up a connection to a resource.
    pub fn cleanup_connection(&mut self, id: &ClientId) {
        self.role_state.peers.remove(id);
    }

    pub fn allow_access(
        &mut self,
        resource: ResourceDescription,
        client: ClientId,
        expires_at: Option<DateTime<Utc>>,
        domain: Option<Dname>,
    ) -> Option<DomainResponse> {
        let peer = self.role_state.peers.get_mut(&client)?;

        let (addresses, resource_id) = match &resource {
            ResourceDescription::Dns(r) => {
                let Some(domain) = domain.clone() else {
                    return None;
                };

                if !crate::dns::is_subdomain(&domain, &r.domain) {
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

    pub fn remove_access(&mut self, id: &ClientId, resource_id: &ResourceId) {
        let Some(peer) = self.role_state.peers.get_mut(id) else {
            return;
        };

        peer.transform.remove_resource(resource_id);
        if peer.transform.is_emptied() {
            self.role_state.peers.remove(id);
        }
    }

    pub fn add_ice_candidate(&mut self, conn_id: ClientId, ice_candidate: String) {
        self.node
            .add_remote_candidate(conn_id, ice_candidate, Instant::now());
    }

    fn new_peer(
        &mut self,
        ips: Vec<IpNetwork>,
        client_id: ClientId,
        resource: ResourceDescription,
        expires_at: Option<DateTime<Utc>>,
        resource_addresses: Vec<IpNetwork>,
    ) -> Result<()> {
        let mut peer = Peer::new(client_id, PacketTransformGateway::default(), &ips, ());

        for address in resource_addresses {
            peer.transform
                .add_resource(address, resource.clone(), expires_at);
        }

        self.role_state.peers.insert(peer, &ips);

        Ok(())
    }
}

/// [`Tunnel`] state specific to gateways.
pub struct GatewayState {
    pub peers: PeerStore<ClientId, PacketTransformGateway, ()>,
    expire_interval: Interval,
}

impl GatewayState {
    pub(crate) fn encapsulate<'a>(
        &mut self,
        packet: MutableIpPacket<'a>,
    ) -> Option<(ClientId, MutableIpPacket<'a>)> {
        let dest = packet.destination();

        let peer = self.peers.peer_by_ip_mut(dest)?;
        let packet = peer.transform(packet)?;

        Some((peer.conn_id, packet))
    }

    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        ready!(self.expire_interval.poll_tick(cx));
        self.expire_resources();
        Poll::Ready(())
    }

    fn expire_resources(&mut self) {
        self.peers
            .iter_mut()
            .for_each(|p| p.transform.expire_resources());
        self.peers.retain(|_, p| !p.transform.is_emptied());
    }
}

impl Default for GatewayState {
    fn default() -> Self {
        let mut expire_interval = interval(Duration::from_secs(1));
        expire_interval.set_missed_tick_behavior(MissedTickBehavior::Delay);
        Self {
            peers: Default::default(),
            expire_interval,
        }
    }
}
