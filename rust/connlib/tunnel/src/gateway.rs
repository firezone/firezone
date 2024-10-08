use crate::utils::earliest;
use crate::{messages::gateway::ResourceDescription, peer_store::PeerStore};
use crate::{
    messages::{IceCredentials, SecretKey},
    peer::ClientOnGateway,
};
use crate::{p2p_control, GatewayEvent, GatewayTunnel};
use boringtun::x25519::PublicKey;
use chrono::{DateTime, Utc};
use connlib_model::{ClientId, DomainName, RelayId, ResourceId};
use ip_network::{Ipv4Network, Ipv6Network};
use ip_packet::{FzP2pControlSlice, IpPacket};
use secrecy::{ExposeSecret as _, Secret};
use snownet::{Credentials, EncryptBuffer, RelaySocket, ServerNode, Transmit};
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
        self.io.set_tun(tun);
    }

    #[expect(clippy::too_many_arguments)]
    pub fn authorize_flow(
        &mut self,
        client_id: ClientId,
        client_key: PublicKey,
        preshared_key: SecretKey,
        client_ice: IceCredentials,
        gateway_ice: IceCredentials,
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        expires_at: Option<DateTime<Utc>>,
        resource: ResourceDescription,
    ) {
        self.role_state.authorize_flow(
            client_id,
            client_key,
            preshared_key,
            client_ice,
            gateway_ice,
            ipv4,
            ipv6,
            expires_at,
            resource,
            Instant::now(),
        )
    }

    pub fn cleanup_connection(&mut self, id: &ClientId) {
        self.role_state.peers.remove(id);
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

    pub fn setup_dns_resource_nat(
        &mut self,
        request: PendingSetupNatRequest,
        resolved_ips: Vec<IpAddr>,
    ) {
        self.role_state
            .setup_dns_resource_nat(request, resolved_ips, Instant::now())
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
        self.role_state
            .remove_ice_candidate(conn_id, ice_candidate, Instant::now());
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
    buffered_transmits: VecDeque<Transmit<'static>>,
}

impl GatewayState {
    pub(crate) fn new(seed: [u8; 32]) -> Self {
        Self {
            peers: Default::default(),
            node: ServerNode::new(seed),
            next_expiry_resources_check: Default::default(),
            buffered_events: VecDeque::default(),
            buffered_transmits: VecDeque::default(),
        }
    }

    pub(crate) fn public_key(&self) -> PublicKey {
        self.node.public_key()
    }

    pub(crate) fn encapsulate(
        &mut self,
        packet: IpPacket,
        now: Instant,
        buffer: &mut EncryptBuffer,
    ) -> Option<snownet::EncryptedPacket> {
        let dst = packet.destination();

        if !is_client(dst) {
            return None;
        }

        let Some(peer) = self.peers.peer_by_ip_mut(dst) else {
            tracing::trace!(%dst, "Couldn't find connection by IP");

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

    pub(crate) fn decapsulate(
        &mut self,
        local: SocketAddr,
        from: SocketAddr,
        packet: &[u8],
        now: Instant,
    ) -> Option<IpPacket> {
        let (cid, packet) = self.node.decapsulate(
            local,
            from,
            packet,
            now,
        )
        .inspect_err(|e| tracing::debug!(%from, num_bytes = %packet.len(), "Failed to decapsulate incoming packet: {e}"))
        .ok()??;

        let Some(peer) = self.peers.get_mut(&cid) else {
            tracing::warn!(%cid, "Couldn't find connection by ID");

            return None;
        };

        if let Some(fz_p2p_control) = packet.as_fz_p2p_control() {
            handle_p2p_control_packet(peer, fz_p2p_control, &mut self.buffered_events);
            return None;
        }

        let packet = peer
            .decapsulate(packet, now)
            .inspect_err(|e| tracing::debug!(%cid, "Invalid packet: {e:#}"))
            .ok()?;

        Some(packet)
    }

    pub fn add_ice_candidate(&mut self, conn_id: ClientId, ice_candidate: String, now: Instant) {
        self.node.add_remote_candidate(conn_id, ice_candidate, now);
    }

    pub fn remove_ice_candidate(&mut self, conn_id: ClientId, ice_candidate: String, now: Instant) {
        self.node
            .remove_remote_candidate(conn_id, ice_candidate, now);
    }

    #[tracing::instrument(level = "debug", skip_all, fields(%client_id))]
    #[expect(clippy::too_many_arguments)] // TODO: Silence this one across the codebase.
    pub fn authorize_flow(
        &mut self,
        client_id: ClientId,
        client_key: PublicKey,
        preshared_key: SecretKey,
        client_ice: IceCredentials,
        gateway_ice: IceCredentials,
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        expires_at: Option<DateTime<Utc>>,
        resource: ResourceDescription,
        now: Instant,
    ) {
        self.node.upsert_connection(
            client_id,
            client_key,
            Secret::new(preshared_key.expose_secret().0),
            Credentials {
                username: gateway_ice.username,
                password: gateway_ice.password,
            },
            Credentials {
                username: client_ice.username,
                password: client_ice.password,
            },
            now,
        );

        self.allow_access(client_id, ipv4, ipv6, expires_at, resource);
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

        if let Err(e) = peer.refresh_translation(name.clone(), resource_id, resolved_ips, now) {
            tracing::warn!(rid = %resource_id, %name, "Failed to refresh DNS resource IP translations: {e:#}");
        };
    }

    pub fn setup_dns_resource_nat(
        &mut self,
        request: PendingSetupNatRequest,
        resolved_ips: Vec<IpAddr>,
        now: Instant,
    ) {
        let mut buffer = EncryptBuffer::new(1500);

        let PendingSetupNatRequest {
            domain,
            client: cid,
            resource,
            proxy_ips,
        } = request;

        let Some(peer) = self.peers.get_mut(&cid) else {
            tracing::debug!(%cid, "Unknown peer");
            return;
        };
        let result =
            peer.assign_translations(domain.clone(), resource, &resolved_ips, proxy_ips, now);

        let response = match &result {
            Ok(()) => {
                tracing::debug!(%domain, rid = %resource, "Successfully setup DNS resource NAT");

                p2p_control::setup_dns_resource_nat::response(resource, domain, 200)
            }
            Err(e) => {
                tracing::debug!(%domain, rid = %resource, "Failed to setup DNS resource NAT: {e:#}");

                p2p_control::setup_dns_resource_nat::response(resource, domain, 500)
            }
        };

        let transmit = match self.node.encapsulate(peer.id(), response, now, &mut buffer) {
            Ok(Some(packet)) => packet.to_transmit(&buffer).into_owned(),
            Ok(None) => {
                tracing::debug!(
                    "Encapsulating p2p control protocol packet did not yield a transmit"
                );
                return;
            }
            Err(e) => {
                tracing::debug!("Failed to encapsulate: {e}");
                return;
            }
        };

        self.buffered_transmits.push_back(transmit);
    }

    fn allow_access(
        &mut self,
        client: ClientId,
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        expires_at: Option<DateTime<Utc>>,
        resource: ResourceDescription,
    ) {
        let peer = self
            .peers
            .entry(client)
            .or_insert_with(|| ClientOnGateway::new(client, ipv4, ipv6));

        peer.add_resource(resource.clone(), expires_at);
        self.peers.add_ip(&client, &ipv4.into());
        self.peers.add_ip(&client, &ipv6.into());

        tracing::info!(%client, resource = %resource.id(), expires = ?expires_at.map(|e| e.to_rfc3339()), "Allowing access to resource");
    }

    pub fn poll_timeout(&mut self) -> Option<Instant> {
        // TODO: This should check when the next resource actually expires instead of doing it at a fixed interval.
        earliest(self.next_expiry_resources_check, self.node.poll_timeout())
    }

    pub fn handle_timeout(&mut self, now: Instant, utc_now: DateTime<Utc>) {
        self.node.handle_timeout(now);
        self.drain_node_events();

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
    }

    fn drain_node_events(&mut self) {
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
        if let Some(transmit) = self.buffered_transmits.pop_front() {
            return Some(transmit);
        }

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
        self.drain_node_events()
    }
}

fn handle_p2p_control_packet(
    peer: &ClientOnGateway,
    fz_p2p_control: FzP2pControlSlice,
    buffered_events: &mut VecDeque<GatewayEvent>,
) {
    use p2p_control::setup_dns_resource_nat;

    match fz_p2p_control.message_type() {
        setup_dns_resource_nat::REQ_CODE => {
            let Ok(req) = setup_dns_resource_nat::decode_request(fz_p2p_control)
                .inspect_err(|e| tracing::debug!("{e:#}"))
            else {
                return;
            };

            if !peer.is_allowed(req.resource) {
                tracing::debug!(cid = %peer.id(), resource = %req.resource, "Rejecting DNS resource NAT setup request; resource not allowed");

                // TODO: Send back 403 response.
                return;
            }

            buffered_events.push_back(GatewayEvent::ResolveDns(PendingSetupNatRequest {
                domain: req.domain,
                client: peer.id(),
                resource: req.resource,
                proxy_ips: req.proxy_ips,
            }));
        }
        code => {
            tracing::debug!(%code, "Unknown control protocol");
        }
    }
}

#[derive(Debug, Clone)]
pub struct PendingSetupNatRequest {
    domain: DomainName,
    client: ClientId,
    resource: ResourceId,
    proxy_ips: Vec<IpAddr>,
}

impl PendingSetupNatRequest {
    pub fn domain(&self) -> &DomainName {
        &self.domain
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
