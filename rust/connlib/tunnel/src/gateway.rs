use crate::peer::ClientOnGateway;
use crate::peer_store::PeerStore;
use crate::utils::{earliest, stun, turn};
use crate::{GatewayEvent, GatewayTunnel};
use boringtun::x25519::PublicKey;
use chrono::{DateTime, Utc};
use connlib_shared::messages::{
    gateway::ResolvedResourceDescriptionDns, gateway::ResourceDescription, Answer, ClientId,
    ConnectionAccepted, DomainResponse, Interface as InterfaceConfig, Key, Offer, Relay, RelayId,
    ResourceId,
};
use connlib_shared::{Callbacks, DomainName, Error, Result, StaticSecret};
use ip_network::IpNetwork;
use ip_packet::{IpPacket, MutableIpPacket};
use secrecy::{ExposeSecret as _, Secret};
use snownet::{RelaySocket, ServerNode};
use std::collections::{HashSet, VecDeque};
use std::net::SocketAddr;
use std::time::{Duration, Instant};

const PEERS_IPV4: &str = "100.64.0.0/11";
const PEERS_IPV6: &str = "fd00:2021:1111::/107";

const EXPIRE_RESOURCES_INTERVAL: Duration = Duration::from_secs(1);

impl<CB> GatewayTunnel<CB>
where
    CB: Callbacks + 'static,
{
    #[tracing::instrument(level = "trace", skip(self))]
    pub fn set_interface(&mut self, config: &InterfaceConfig) -> connlib_shared::Result<()> {
        // Note: the dns fallback strategy is irrelevant for gateways
        let callbacks = self.callbacks.clone();
        self.io
            .device_mut()
            .set_config(config, vec![], &callbacks)?;
        self.io.device_mut().set_routes(
            HashSet::from([PEERS_IPV4.parse().unwrap(), PEERS_IPV6.parse().unwrap()]),
            &callbacks,
        )?;

        let name = self.io.device_mut().name().to_owned();

        tracing::debug!(ip4 = %config.ipv4, ip6 = %config.ipv6, %name, "TUN device initialized");

        Ok(())
    }

    /// Accept a connection request from a client.
    #[allow(clippy::too_many_arguments)]
    pub fn accept(
        &mut self,
        client_id: ClientId,
        key: Secret<Key>,
        offer: Offer,
        client: PublicKey,
        ips: Vec<IpNetwork>,
        relays: Vec<Relay>,
        domain: Option<DomainName>,
        expires_at: Option<DateTime<Utc>>,
        resource: ResourceDescription<ResolvedResourceDescriptionDns>,
    ) -> Result<ConnectionAccepted> {
        self.role_state.accept(
            client_id,
            snownet::Offer {
                session_key: key.expose_secret().0.into(),
                credentials: snownet::Credentials {
                    username: offer.username,
                    password: offer.password,
                },
            },
            client,
            ips,
            stun(&relays, |addr| self.io.sockets_ref().can_handle(addr)),
            turn(&relays),
            domain,
            expires_at,
            resource,
            Instant::now(),
        )
    }

    pub fn cleanup_connection(&mut self, id: &ClientId) {
        self.role_state.peers.remove(id);
    }

    pub fn allow_access(
        &mut self,
        resource: ResourceDescription<ResolvedResourceDescriptionDns>,
        client: ClientId,
        expires_at: Option<DateTime<Utc>>,
        domain: Option<DomainName>,
    ) -> Option<DomainResponse> {
        self.role_state
            .allow_access(resource, client, expires_at, domain)
    }

    pub fn update_resource(&mut self, resource: ResourceDescription) {
        for peer in self.role_state.peers.iter_mut() {
            peer.update_resource(&resource);
        }
    }

    #[tracing::instrument(level = "debug", skip_all, fields(%resource, %client))]
    pub fn remove_access(&mut self, client: &ClientId, resource: &ResourceId) {
        let Some(peer) = self.role_state.peers.get_mut(client) else {
            return;
        };

        peer.remove_resource(resource);
        if peer.is_emptied() {
            self.role_state.peers.remove(client);
        }

        tracing::debug!("Access removed");
    }

    pub fn add_ice_candidate(&mut self, conn_id: ClientId, ice_candidate: String) {
        self.role_state
            .add_ice_candidate(conn_id, ice_candidate, Instant::now());
    }

    pub fn remove_ice_candidate(&mut self, conn_id: ClientId, ice_candidate: String) {
        self.role_state.remove_ice_candidate(conn_id, ice_candidate);
    }
}

/// A SANS-IO implementation of a gateway's functionality.
///
/// Internally, this composes a [`snownet::ServerNode`] with firezone's policy engine around resources.
pub struct GatewayState {
    /// The [`snownet::ClientNode`].
    ///
    /// Manages wireguard tunnels to clients.
    node: ServerNode<ClientId, RelayId>,
    /// All clients we are connected to and the associated, connection-specific state.
    peers: PeerStore<ClientId, ClientOnGateway>,

    /// When to next check whether a resource-access policy has expired.
    next_expiry_resources_check: Option<Instant>,

    buffered_events: VecDeque<GatewayEvent>,
}

impl GatewayState {
    pub(crate) fn new(private_key: StaticSecret) -> Self {
        Self {
            peers: Default::default(),
            node: ServerNode::new(private_key),
            next_expiry_resources_check: Default::default(),
            buffered_events: VecDeque::default(),
        }
    }

    #[cfg(all(feature = "proptest", test))]
    pub(crate) fn public_key(&self) -> PublicKey {
        self.node.public_key()
    }

    pub(crate) fn encapsulate<'s>(
        &'s mut self,
        packet: MutableIpPacket<'_>,
    ) -> Option<snownet::Transmit<'s>> {
        let dest = packet.destination();

        let peer = self.peers.peer_by_ip_mut(dest)?;

        let transmit = self
            .node
            .encapsulate(peer.id(), packet.as_immutable(), Instant::now())
            .inspect_err(|e| tracing::debug!("Failed to encapsulate: {e}"))
            .ok()??;

        Some(transmit)
    }

    pub(crate) fn decapsulate<'b>(
        &mut self,
        local: SocketAddr,
        from: SocketAddr,
        packet: &[u8],
        now: Instant,
        buffer: &'b mut [u8],
    ) -> Option<IpPacket<'b>> {
        let (conn_id, packet) = self.node.decapsulate(
            local,
            from,
            packet,
            now,
            buffer,
        )
        .inspect_err(|e| tracing::warn!(%local, %from, num_bytes = %packet.len(), "Failed to decapsulate incoming packet: {e}"))
        .ok()??;

        let Some(peer) = self.peers.get_mut(&conn_id) else {
            tracing::error!(%conn_id, %local, %from, "Couldn't find connection");

            return None;
        };

        if let Err(e) = peer.ensure_allowed(&packet) {
            // Note: this can happen with apps such as cURL that if started before the tunnel routes are address
            // source ips can be sticky.
            tracing::warn!(%conn_id, %local, %from, "Packet not allowed: {e}");

            return None;
        }

        Some(packet.into_immutable())
    }

    pub fn add_ice_candidate(&mut self, conn_id: ClientId, ice_candidate: String, now: Instant) {
        self.node.add_remote_candidate(conn_id, ice_candidate, now);
    }

    pub fn remove_ice_candidate(&mut self, conn_id: ClientId, ice_candidate: String) {
        self.node.remove_remote_candidate(conn_id, ice_candidate);
    }

    /// Accept a connection request from a client.
    #[allow(clippy::too_many_arguments)]
    pub fn accept(
        &mut self,
        client_id: ClientId,
        offer: snownet::Offer,
        client: PublicKey,
        ips: Vec<IpNetwork>,
        stun_servers: HashSet<SocketAddr>,
        turn_servers: HashSet<(RelayId, RelaySocket, String, String, String)>,
        domain: Option<DomainName>,
        expires_at: Option<DateTime<Utc>>,
        resource: ResourceDescription<ResolvedResourceDescriptionDns>,
        now: Instant,
    ) -> Result<ConnectionAccepted> {
        match (&domain, &resource) {
            (Some(domain), ResourceDescription::Dns(r)) => {
                if !crate::dns::is_subdomain(domain, &r.domain) {
                    return Err(Error::InvalidResource);
                }
            }
            (None, ResourceDescription::Dns(_)) => return Err(Error::ControlProtocolError),
            _ => {}
        }

        let answer =
            self.node
                .accept_connection(client_id, offer, client, stun_servers, turn_servers, now);

        let mut peer = ClientOnGateway::new(client_id, &ips);

        peer.add_resource(
            resource.addresses(),
            resource.id(),
            resource.filters(),
            expires_at,
        );

        self.peers.insert(peer, &ips);

        Ok(ConnectionAccepted {
            ice_parameters: Answer {
                username: answer.credentials.username,
                password: answer.credentials.password,
            },
            domain_response: domain.map(|domain| DomainResponse {
                domain,
                address: resource
                    .addresses()
                    .into_iter()
                    .map(|ip| ip.network_address())
                    .collect(),
            }),
        })
    }

    pub fn allow_access(
        &mut self,
        resource: ResourceDescription<ResolvedResourceDescriptionDns>,
        client: ClientId,
        expires_at: Option<DateTime<Utc>>,
        domain: Option<DomainName>,
    ) -> Option<DomainResponse> {
        match (&domain, &resource) {
            (Some(domain), ResourceDescription::Dns(r)) => {
                if !crate::dns::is_subdomain(domain, &r.domain) {
                    return None;
                }
            }
            (None, ResourceDescription::Dns(_)) => return None,
            _ => {}
        }

        let peer = self.peers.get_mut(&client)?;

        let (addresses, resource_id) = match &resource {
            ResourceDescription::Dns(r) => {
                let domain = domain.clone()?;

                if !crate::dns::is_subdomain(&domain, &r.domain) {
                    return None;
                }

                (r.addresses.clone(), r.id)
            }
            ResourceDescription::Cidr(cidr) => (vec![cidr.address], cidr.id),
        };

        peer.add_resource(
            resource.addresses(),
            resource.id(),
            resource.filters(),
            expires_at,
        );

        tracing::info!(%client, resource = %resource_id, expires = ?expires_at.map(|e| e.to_rfc3339()), "Allowing access to resource");

        if let Some(domain) = domain {
            return Some(DomainResponse {
                domain,
                address: addresses.iter().map(|i| i.network_address()).collect(),
            });
        }

        None
    }

    pub fn poll_timeout(&mut self) -> Option<Instant> {
        // TODO: This should check when the next resource actually expires instead of doing it at a fixed interval.
        earliest(self.next_expiry_resources_check, self.node.poll_timeout())
    }

    pub fn handle_timeout(&mut self, now: Instant, utc_now: DateTime<Utc>) {
        self.node.handle_timeout(now);

        match self.next_expiry_resources_check {
            Some(next_expiry_resources_check) if now >= next_expiry_resources_check => {
                self.peers
                    .iter_mut()
                    .for_each(|p| p.expire_resources(utc_now));
                self.peers.retain(|_, p| !p.is_emptied());

                self.next_expiry_resources_check = Some(now + EXPIRE_RESOURCES_INTERVAL);
            }
            None => self.next_expiry_resources_check = Some(now + EXPIRE_RESOURCES_INTERVAL),
            Some(_) => {}
        }

        while let Some(event) = self.node.poll_event() {
            match event {
                snownet::Event::ConnectionFailed(id) => {
                    self.peers.remove(&id);
                }
                snownet::Event::NewIceCandidate {
                    connection,
                    candidate,
                } => {
                    self.buffered_events
                        .push_back(GatewayEvent::NewIceCandidate {
                            conn_id: connection,
                            candidate,
                        });
                }
                snownet::Event::InvalidateIceCandidate {
                    connection,
                    candidate,
                } => {
                    self.buffered_events
                        .push_back(GatewayEvent::InvalidIceCandidate {
                            conn_id: connection,
                            candidate,
                        });
                }
                _ => {}
            }
        }
    }

    pub(crate) fn poll_transmit(&mut self) -> Option<snownet::Transmit<'static>> {
        self.node.poll_transmit()
    }

    pub(crate) fn poll_event(&mut self) -> Option<GatewayEvent> {
        self.buffered_events.pop_front()
    }

    pub fn update_relays(
        &mut self,
        to_remove: HashSet<RelayId>,
        to_add: HashSet<(RelayId, RelaySocket, String, String, String)>,
        now: Instant,
    ) {
        self.node.update_relays(to_remove, &to_add, now);
    }
}
