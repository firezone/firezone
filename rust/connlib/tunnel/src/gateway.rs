use crate::peer::ClientOnGateway;
use crate::peer_store::PeerStore;
use crate::utils::earliest;
use crate::{GatewayEvent, GatewayTunnel, BUF_SIZE};
use anyhow::bail;
use boringtun::x25519::PublicKey;
use chrono::{DateTime, Utc};
use connlib_shared::messages::{
    gateway::ResolvedResourceDescriptionDns, gateway::ResourceDescription, Answer, ClientId, Key,
    Offer, RelayId, ResourceId,
};
use connlib_shared::{DomainName, StaticSecret};
use ip_network::{Ipv4Network, Ipv6Network};
use ip_packet::IpPacket;
use secrecy::{ExposeSecret as _, Secret};
use snownet::{EncryptBuffer, RelaySocket, ServerNode};
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::time::{Duration, Instant};
use tun::Tun;

pub const IPV4_PEERS: Ipv4Network = match Ipv4Network::new(Ipv4Addr::new(100, 64, 0, 0), 11) {
    Ok(n) => n,
    Err(_) => unreachable!(),
};
pub const IPV6_PEERS: Ipv6Network =
    match Ipv6Network::new(Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 0), 107) {
        Ok(n) => n,
        Err(_) => unreachable!(),
    };

const EXPIRE_RESOURCES_INTERVAL: Duration = Duration::from_secs(1);

impl GatewayTunnel {
    pub fn set_tun(&mut self, tun: Box<dyn Tun>) {
        self.io.device_mut().set_tun(tun);
    }

    /// Accept a connection request from a client.
    pub fn accept(
        &mut self,
        client_id: ClientId,
        key: Secret<Key>,
        offer: Offer,
        client: PublicKey,
    ) -> Answer {
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
            Instant::now(),
        )
    }

    pub fn cleanup_connection(&mut self, id: &ClientId) {
        self.role_state.peers.remove(id);
    }

    pub fn allow_access(
        &mut self,
        client: ClientId,
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        domain: Option<(DomainName, Vec<IpAddr>)>,
        expires_at: Option<DateTime<Utc>>,
        resource: ResourceDescription<ResolvedResourceDescriptionDns>,
    ) -> anyhow::Result<()> {
        self.role_state.allow_access(
            client,
            ipv4,
            ipv6,
            domain,
            expires_at,
            resource,
            Instant::now(),
        )
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
    pub(crate) fn new(private_key: impl Into<StaticSecret>, seed: [u8; 32]) -> Self {
        Self {
            peers: Default::default(),
            node: ServerNode::new(private_key.into(), BUF_SIZE, seed),
            next_expiry_resources_check: Default::default(),
            buffered_events: VecDeque::default(),
        }
    }

    #[cfg(all(feature = "proptest", test))]
    pub(crate) fn public_key(&self) -> PublicKey {
        self.node.public_key()
    }

    pub(crate) fn encapsulate(
        &mut self,
        packet: IpPacket<'_>,
        now: Instant,
        buffer: &mut EncryptBuffer,
    ) -> Option<snownet::EncryptedPacket> {
        let dst = packet.destination();

        if !is_client(dst) {
            return None;
        }

        let Some(peer) = self.peers.peer_by_ip_mut(dst) else {
            tracing::warn!(%dst, "Couldn't find connection by IP");

            return None;
        };
        let cid = peer.id();

        let packet = peer
            .encapsulate(packet, now)
            .inspect_err(|e| tracing::debug!(%cid, "Failed to encapsulate: {e:#}"))
            .ok()??;

        let transmit = self
            .node
            .encapsulate(peer.id(), packet, now, buffer)
            .inspect_err(|e| tracing::debug!(%cid, "Failed to encapsulate: {e}"))
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
        let (cid, packet) = self.node.decapsulate(
            local,
            from,
            packet,
            now,
            buffer,
        )
        .inspect_err(|e| tracing::debug!(%from, num_bytes = %packet.len(), "Failed to decapsulate incoming packet: {e}"))
        .ok()??;

        let Some(peer) = self.peers.get_mut(&cid) else {
            tracing::warn!(%cid, "Couldn't find connection by ID");

            return None;
        };

        let packet = peer
            .decapsulate(packet, now)
            .inspect_err(|e| tracing::debug!(%cid, "Invalid packet: {e:#}"))
            .ok()?;

        Some(packet)
    }

    pub fn add_ice_candidate(&mut self, conn_id: ClientId, ice_candidate: String, now: Instant) {
        self.node.add_remote_candidate(conn_id, ice_candidate, now);
    }

    pub fn remove_ice_candidate(&mut self, conn_id: ClientId, ice_candidate: String) {
        self.node.remove_remote_candidate(conn_id, ice_candidate);
    }

    /// Accept a connection request from a client.
    pub fn accept(
        &mut self,
        client_id: ClientId,
        offer: snownet::Offer,
        client: PublicKey,
        now: Instant,
    ) -> Answer {
        let answer = self.node.accept_connection(client_id, offer, client, now);

        Answer {
            username: answer.credentials.username,
            password: answer.credentials.password,
        }
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

    #[allow(clippy::too_many_arguments)]
    pub fn allow_access(
        &mut self,
        client: ClientId,
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        domain: Option<(DomainName, Vec<IpAddr>)>,
        expires_at: Option<DateTime<Utc>>,
        resource: ResourceDescription<ResolvedResourceDescriptionDns>,
        now: Instant,
    ) -> anyhow::Result<()> {
        match (&domain, &resource) {
            (Some((domain, _)), ResourceDescription::Dns(r)) => {
                if !crate::dns::is_subdomain(domain, &r.domain) {
                    bail!(
                        "Requested domain '{domain}' isn't a sub-domain of resource address '{}'",
                        r.domain
                    );
                }
            }
            (None, ResourceDescription::Dns(_)) => {
                bail!("Cannot setup connection for DNS resource without domain")
            }
            _ => {}
        }

        let peer = self
            .peers
            .entry(client)
            .or_insert_with(|| ClientOnGateway::new(client, ipv4, ipv6));

        peer.assign_proxies(&resource, domain.clone(), now)?;
        peer.add_resource(
            resource.addresses(),
            resource.id(),
            resource.filters(),
            expires_at,
            domain.map(|(n, _)| n),
        );
        self.peers.add_ip(&client, &ipv4.into());
        self.peers.add_ip(&client, &ipv6.into());

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

        let mut added_ice_candidates = BTreeMap::<ClientId, BTreeSet<String>>::default();
        let mut removed_ice_candidates = BTreeMap::<ClientId, BTreeSet<String>>::default();

        while let Some(event) = self.node.poll_event() {
            match event {
                snownet::Event::ConnectionFailed(id) | snownet::Event::ConnectionClosed(id) => {
                    self.peers.remove(&id);
                }
                snownet::Event::NewIceCandidate {
                    connection,
                    candidate,
                } => {
                    added_ice_candidates
                        .entry(connection)
                        .or_default()
                        .insert(candidate);
                }
                snownet::Event::InvalidateIceCandidate {
                    connection,
                    candidate,
                } => {
                    removed_ice_candidates
                        .entry(connection)
                        .or_default()
                        .insert(candidate);
                }
                snownet::Event::ConnectionEstablished(_) => {}
            }
        }

        for (conn_id, candidates) in added_ice_candidates.into_iter() {
            self.buffered_events
                .push_back(GatewayEvent::AddedIceCandidates {
                    conn_id,
                    candidates,
                })
        }

        for (conn_id, candidates) in removed_ice_candidates.into_iter() {
            self.buffered_events
                .push_back(GatewayEvent::RemovedIceCandidates {
                    conn_id,
                    candidates,
                })
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
        to_remove: BTreeSet<RelayId>,
        to_add: BTreeSet<(RelayId, RelaySocket, String, String, String)>,
        now: Instant,
    ) {
        self.node.update_relays(to_remove, &to_add, now);
    }
}

fn is_client(dst: IpAddr) -> bool {
    match dst {
        IpAddr::V4(v4) => IPV4_PEERS.contains(v4),
        IpAddr::V6(v6) => IPV6_PEERS.contains(v6),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mldv2_routers_are_not_clients() {
        assert!(!is_client("ff02::16".parse().unwrap()))
    }
}
