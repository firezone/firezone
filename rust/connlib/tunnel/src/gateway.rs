use crate::peer::ClientOnGateway;
use crate::peer_store::PeerStore;
use crate::utils::{earliest, stun, turn};
use crate::{GatewayEvent, GatewayTunnel};
use boringtun::x25519::PublicKey;
use chrono::{DateTime, Utc};
use connlib_shared::messages::{
    gateway::ResolvedResourceDescriptionDns, gateway::ResourceDescription, Answer, ClientId,
    Interface as InterfaceConfig, Key, Offer, Relay, RelayId, ResourceId,
};
use connlib_shared::{Callbacks, DomainName, Error, Result, StaticSecret};
use ip_packet::{IpPacket, MutableIpPacket};
use secrecy::{ExposeSecret as _, Secret};
use snownet::{RelaySocket, ServerNode};
use std::collections::{HashSet, VecDeque};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::time::{Duration, Instant};

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
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        relays: Vec<Relay>,
        domain: Option<(DomainName, Vec<IpAddr>)>,
        expires_at: Option<DateTime<Utc>>,
        resource: ResourceDescription<ResolvedResourceDescriptionDns>,
    ) -> Result<Answer> {
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
            ipv4,
            ipv6,
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
        domain: Option<(DomainName, Vec<IpAddr>)>,
    ) -> Result<()> {
        self.role_state
            .allow_access(resource, client, expires_at, domain, Instant::now())
    }

    pub fn refresh_translation(
        &mut self,
        client: ClientId,
        resource_id: ResourceId,
        name: DomainName,
        resolved_ips: Vec<IpAddr>,
    ) {
        self.role_state
            .refresh_translation(client, resource_id, name, resolved_ips, Instant::now())
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
    pub(crate) fn new(private_key: impl Into<StaticSecret>) -> Self {
        Self {
            peers: Default::default(),
            node: ServerNode::new(private_key.into()),
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
        now: Instant,
    ) -> Option<snownet::Transmit<'s>> {
        let dest = packet.destination();

        let peer = self.peers.peer_by_ip_mut(dest)?;

        let packet = peer
            .encapsulate(packet, now)
            .inspect_err(|e| tracing::debug!("Failed to encapsulate: {e}"))
            .ok()??;

        let transmit = self
            .node
            .encapsulate(peer.id(), packet.as_immutable(), now)
            .inspect_err(|e| tracing::debug!("Failed to encapsulate: {e}"))
            .ok()??;

        Some(transmit)
    }

    #[tracing::instrument(level = "trace", skip_all, fields(src, dst))]
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
        .inspect_err(|e| tracing::debug!(%local, %from, num_bytes = %packet.len(), "Failed to decapsulate incoming packet: {e}"))
        .ok()??;

        tracing::Span::current().record("src", tracing::field::display(packet.source()));
        tracing::Span::current().record("dst", tracing::field::display(packet.destination()));

        let Some(peer) = self.peers.get_mut(&conn_id) else {
            tracing::error!(%conn_id, %local, %from, "Couldn't find connection");

            return None;
        };

        let packet = peer
            .decapsulate(packet, now)
            .inspect_err(|e| tracing::debug!(%conn_id, %local, %from, "Invalid packet: {e}"))
            .ok()?;

        tracing::trace!("Decapsulated packet");

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
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        stun_servers: HashSet<SocketAddr>,
        turn_servers: HashSet<(RelayId, RelaySocket, String, String, String)>,
        domain: Option<(DomainName, Vec<IpAddr>)>,
        expires_at: Option<DateTime<Utc>>,
        resource: ResourceDescription<ResolvedResourceDescriptionDns>,
        now: Instant,
    ) -> Result<Answer> {
        match (&domain, &resource) {
            (Some((domain, _)), ResourceDescription::Dns(r)) => {
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

        let mut peer = ClientOnGateway::new(client_id, ipv4, ipv6);

        peer.add_resource(
            resource.addresses(),
            resource.id(),
            resource.filters(),
            expires_at,
            domain.clone().map(|(n, _)| n),
        );

        peer.assign_proxies(&resource, domain, now)?;

        self.peers.insert(peer, &[ipv4.into(), ipv6.into()]);

        Ok(Answer {
            username: answer.credentials.username,
            password: answer.credentials.password,
        })
    }

    pub fn refresh_translation(
        &mut self,
        client: ClientId,
        resource_id: ResourceId,
        name: DomainName,
        resolved_ips: Vec<IpAddr>,
        now: Instant,
    ) {
        let Some(peer) = self.peers.get_mut(&client) else {
            return;
        };

        peer.refresh_translation(name, resource_id, resolved_ips, now);
    }

    pub fn allow_access(
        &mut self,
        resource: ResourceDescription<ResolvedResourceDescriptionDns>,
        client: ClientId,
        expires_at: Option<DateTime<Utc>>,
        domain: Option<(DomainName, Vec<IpAddr>)>,
        now: Instant,
    ) -> Result<()> {
        match (&domain, &resource) {
            (Some((domain, _)), ResourceDescription::Dns(r)) => {
                if !crate::dns::is_subdomain(domain, &r.domain) {
                    return Err(Error::InvalidResource);
                }
            }
            (None, ResourceDescription::Dns(_)) => return Err(Error::InvalidResource),
            _ => {}
        }

        let Some(peer) = self.peers.get_mut(&client) else {
            return Err(Error::ControlProtocolError);
        };

        peer.assign_proxies(&resource, domain.clone(), now)?;

        peer.add_resource(
            resource.addresses(),
            resource.id(),
            resource.filters(),
            expires_at,
            domain.map(|(n, _)| n),
        );

        tracing::info!(%client, resource = %resource.id(), expires = ?expires_at.map(|e| e.to_rfc3339()), "Allowing access to resource");
        Ok(())
    }

    pub fn poll_timeout(&mut self) -> Option<Instant> {
        // TODO: This should check when the next resource actually expires instead of doing it at a fixed interval.
        earliest(self.next_expiry_resources_check, self.node.poll_timeout())
    }

    pub fn handle_timeout(&mut self, now: Instant, utc_now: DateTime<Utc>) {
        self.node.handle_timeout(now);

        match self.next_expiry_resources_check {
            Some(next_expiry_resources_check) if now >= next_expiry_resources_check => {
                self.peers.iter_mut().for_each(|p| {
                    p.expire_resources(utc_now);
                    p.handle_timeout(now)
                });
                self.peers.retain(|_, p| !p.is_emptied());

                self.next_expiry_resources_check = Some(now + EXPIRE_RESOURCES_INTERVAL);
            }
            None => self.next_expiry_resources_check = Some(now + EXPIRE_RESOURCES_INTERVAL),
            Some(_) => {}
        }

        while let Some(event) = self.node.poll_event() {
            match event {
                snownet::Event::ConnectionFailed(id) | snownet::Event::ConnectionClosed(id) => {
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
                snownet::Event::ConnectionEstablished(_) => {}
            }
        }
    }

    pub(crate) fn poll_transmit(&mut self) -> Option<snownet::Transmit<'static>> {
        self.node.poll_transmit()
    }

    pub(crate) fn poll_event(&mut self) -> Option<GatewayEvent> {
        if let Some(ev) = self.buffered_events.pop_front() {
            return Some(ev);
        }

        for peer in self.peers.iter_mut() {
            if let Some(ev) = peer.poll_event() {
                return Some(ev);
            }
        }

        None
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
