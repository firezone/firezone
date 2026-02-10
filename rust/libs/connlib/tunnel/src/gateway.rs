mod client_on_gateway;
mod filter_engine;
mod flow_tracker;
mod nat_table;
mod unroutable_packet;

pub use crate::gateway::unroutable_packet::UnroutablePacket;

pub(crate) use crate::gateway::client_on_gateway::ClientOnGateway;
pub(crate) use crate::gateway::unroutable_packet::RoutingError;

use crate::gateway::client_on_gateway::TranslateOutboundResult;
use crate::gateway::flow_tracker::FlowTracker;
use crate::messages::gateway::{Client, ResourceDescription, Subject};
use crate::messages::{IceCredentials, ResolveRequest};
use crate::peer_store::PeerStore;
use crate::{FailedToDecapsulate, GatewayEvent, IpConfig, p2p_control, packet_kind};
use anyhow::{Context, ErrorExt, Result};
use boringtun::x25519::{self, PublicKey};
use chrono::{DateTime, Utc};
use connlib_model::{ClientId, IceCandidate, RelayId, ResourceId};
use dns_types::DomainName;
use ip_packet::{FzP2pControlSlice, IpPacket};
use secrecy::ExposeSecret as _;
use snownet::{Credentials, IceRole, NoTurnServers, RelaySocket, ServerNode, Transmit};
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::iter;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::{Duration, Instant};

pub const TUN_DNS_PORT: u16 = 53535;

const EXPIRE_RESOURCES_INTERVAL: Duration = Duration::from_secs(1);

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

    flow_tracker: FlowTracker,

    /// When to next check whether a resource-access policy has expired.
    next_expiry_resources_check: Option<Instant>,

    tun_ip_config: Option<IpConfig>,

    buffered_events: VecDeque<GatewayEvent>,
    buffered_transmits: VecDeque<Transmit>,
}

#[derive(Debug)]
pub struct DnsResourceNatEntry {
    domain: DomainName,
    proxy_ips: Vec<IpAddr>,
    resolved_ips: Vec<IpAddr>,
}

impl DnsResourceNatEntry {
    pub fn new(request: ResolveRequest, resolved_ips: Vec<IpAddr>) -> Self {
        Self {
            domain: request.name,
            proxy_ips: request.proxy_ips,
            resolved_ips,
        }
    }
}

impl GatewayState {
    pub(crate) fn new(flow_logs: bool, seed: [u8; 32], now: Instant, unix_ts: Duration) -> Self {
        Self {
            peers: Default::default(),
            node: ServerNode::new(seed, now, unix_ts),
            next_expiry_resources_check: Default::default(),
            buffered_events: VecDeque::default(),
            buffered_transmits: VecDeque::default(),
            flow_tracker: FlowTracker::new(flow_logs, now),
            tun_ip_config: None,
        }
    }

    #[cfg(all(test, feature = "proptest"))]
    pub(crate) fn tunnel_ip_config(&self) -> Option<IpConfig> {
        self.tun_ip_config
    }

    pub(crate) fn public_key(&self) -> PublicKey {
        self.node.public_key()
    }

    pub fn shut_down(&mut self, now: Instant) {
        tracing::info!("Initiating graceful shutdown");

        self.peers.clear();
        self.node.close_all(p2p_control::goodbye(), now);
    }

    /// Handles packets received on the TUN device.
    pub(crate) fn handle_tun_input(
        &mut self,
        packet: IpPacket,
        now: Instant,
    ) -> Result<Option<snownet::Transmit>> {
        let _guard = self.flow_tracker.new_inbound_tun(&packet, now);

        if packet.is_fz_p2p_control() {
            tracing::warn!("Packet matches heuristics of FZ p2p control protocol");
        }

        let dst = packet.destination();

        anyhow::ensure!(crate::is_peer(dst), UnroutablePacket::not_a_peer(&packet));

        let peer = self
            .peers
            .peer_by_ip_mut(dst)
            .with_context(|| UnroutablePacket::no_peer_state(&packet))?;

        let cid = peer.id();

        flow_tracker::inbound_tun::record_client(cid);

        let packet = peer
            .translate_inbound(packet, now)
            .context("Failed to translate inbound packet")?;

        let encrypted_packet = match self.node.encapsulate(cid, &packet, now) {
            Ok(Some(encrypted_packet)) => encrypted_packet,
            Ok(None) => return Ok(None),
            Err(e) if e.any_is::<snownet::UnknownConnection>() => {
                return Err(e.context(UnroutablePacket::not_connected(&packet)));
            }
            Err(e) => return Err(e),
        };

        flow_tracker::inbound_tun::record_wireguard_packet(
            encrypted_packet.src,
            encrypted_packet.dst,
        );

        Ok(Some(encrypted_packet))
    }

    /// Handles UDP packets received on the network interface.
    ///
    /// Most of these packets will be WireGuard encrypted IP packets and will thus yield an [`IpPacket`].
    /// Some of them will however be handled internally, for example, TURN control packets exchanged with relays.
    ///
    /// In case this function returns `None`, you should call [`GatewayState::handle_timeout`] next to fully advance the internal state.
    pub(crate) fn handle_network_input(
        &mut self,
        local: SocketAddr,
        from: SocketAddr,
        packet: &[u8],
        now: Instant,
    ) -> Result<Option<IpPacket>> {
        let _guard = self.flow_tracker.new_inbound_wireguard(local, from, now);

        let Some((cid, packet)) = self
            .node
            .decapsulate(local, from, packet, now)
            .context(FailedToDecapsulate(packet_kind::classify(packet)))?
        else {
            return Ok(None);
        };

        flow_tracker::inbound_wg::record_decrypted_packet(&packet);

        let peer = self
            .peers
            .get_mut(&cid)
            .with_context(|| format!("No peer for connection {cid}"))?;

        flow_tracker::inbound_wg::record_client(cid, peer.client_flow_properties());

        if let Some(fz_p2p_control) = packet.as_fz_p2p_control() {
            let immediate_response = match fz_p2p_control.event_type() {
                p2p_control::ASSIGNED_IPS_EVENT => {
                    handle_assigned_ips_event(fz_p2p_control, peer, &mut self.buffered_events)
                }
                p2p_control::GOODBYE_EVENT => {
                    self.peers.remove(&cid);
                    self.node.remove_connection(cid, "received `goodbye`", now);

                    None
                }
                code => {
                    tracing::debug!(code = %code.into_u8(), "Unknown control protocol event");

                    None
                }
            };

            let Some(immediate_response) = immediate_response else {
                return Ok(None);
            };

            let Some(transmit) = encrypt_packet(immediate_response, cid, &mut self.node, now)?
            else {
                return Ok(None);
            };

            self.buffered_transmits.push_back(transmit);

            return Ok(None);
        }

        match peer
            .translate_outbound(packet, now)
            .context("Failed to translate outbound packet")?
        {
            TranslateOutboundResult::Send(packet) => {
                flow_tracker::inbound_wg::record_translated_packet(&packet);

                Ok(Some(packet))
            }
            TranslateOutboundResult::DestinationUnreachable(reply)
            | TranslateOutboundResult::Filtered(reply) => {
                flow_tracker::inbound_wg::record_icmp_error(&reply);

                let Some(transmit) = encrypt_packet(reply, cid, &mut self.node, now)? else {
                    return Ok(None);
                };

                self.buffered_transmits.push_back(transmit);

                Ok(None)
            }
        }
    }

    pub fn cleanup_connection(&mut self, id: &ClientId, now: Instant) {
        self.peers.remove(id);
        self.node.close_connection(*id, p2p_control::goodbye(), now);
    }

    pub fn add_ice_candidate(
        &mut self,
        conn_id: ClientId,
        ice_candidate: IceCandidate,
        now: Instant,
    ) {
        self.node
            .add_remote_candidate(conn_id, ice_candidate.into(), now);
        self.node.handle_timeout(now);
        self.drain_node_events();
    }

    pub fn remove_ice_candidate(
        &mut self,
        conn_id: ClientId,
        ice_candidate: IceCandidate,
        now: Instant,
    ) {
        self.node
            .remove_remote_candidate(conn_id, ice_candidate.into(), now);
        self.node.handle_timeout(now);
        self.drain_node_events();
    }

    #[tracing::instrument(level = "debug", skip_all, fields(%rid, %cid))]
    pub fn remove_access(&mut self, cid: &ClientId, rid: &ResourceId, now: Instant) {
        let Some(peer) = self.peers.get_mut(cid) else {
            return;
        };

        peer.remove_resource(rid);
        if peer.is_empty() {
            self.peers.remove(cid);
            self.node
                .close_connection(*cid, p2p_control::goodbye(), now);
        }

        tracing::debug!("Access removed");
    }

    pub fn update_resource(&mut self, resource: ResourceDescription) {
        for peer in self.peers.iter_mut() {
            peer.update_resource(&resource);
        }
    }

    #[tracing::instrument(level = "debug", skip_all, fields(cid = %client.id))]
    pub fn authorize_flow(
        &mut self,
        client: Client,
        subject: Subject,
        client_ice: IceCredentials,
        gateway_ice: IceCredentials,
        expires_at: Option<DateTime<Utc>>,
        resource: ResourceDescription,
        now: Instant,
    ) -> Result<(), NoTurnServers> {
        self.node.upsert_connection(
            client.id,
            client.public_key.into(),
            x25519::StaticSecret::from(client.preshared_key.expose_secret().0),
            Credentials {
                username: gateway_ice.username,
                password: gateway_ice.password,
            },
            Credentials {
                username: client_ice.username,
                password: client_ice.password,
            },
            IceRole::Controlled,
            now,
        )?;

        let result = self.allow_access(
            client.id,
            IpConfig {
                v4: client.ipv4,
                v6: client.ipv6,
            },
            flow_tracker::ClientProperties {
                version: client.version,
                device_os_name: client.device_os_name,
                device_os_version: client.device_os_version,
                device_serial: client.device_serial,
                device_uuid: client.device_uuid,
                identifier_for_vendor: client.identifier_for_vendor,
                firebase_installation_id: client.firebase_installation_id,
                auth_provider_id: subject.auth_provider_id,
                actor_name: subject.actor_name,
                actor_id: subject.actor_id,
                actor_email: subject.actor_email,
            },
            expires_at,
            resource,
            None,
        );
        debug_assert!(
            result.is_ok(),
            "`allow_access` should never fail without a `DnsResourceEntry`"
        );

        Ok(())
    }

    pub fn allow_access(
        &mut self,
        client: ClientId,
        client_tun: IpConfig,
        client_props: flow_tracker::ClientProperties,
        expires_at: Option<DateTime<Utc>>,
        resource: ResourceDescription,
        dns_resource_nat: Option<DnsResourceNatEntry>,
    ) -> anyhow::Result<()> {
        let gateway_tun = self.tun_ip_config.context("TUN device not configured")?;

        let peer = self
            .peers
            .entry(client)
            .or_insert_with(|| ClientOnGateway::new(client, client_tun, gateway_tun, client_props));

        peer.add_resource(resource.clone(), expires_at);

        if let Some(entry) = dns_resource_nat {
            peer.setup_nat(
                entry.domain,
                resource.id(),
                BTreeSet::from_iter(entry.resolved_ips),
                BTreeSet::from_iter(entry.proxy_ips),
            )?;
        }

        self.peers.add_ip(&client, &client_tun.v4.into());
        self.peers.add_ip(&client, &client_tun.v6.into());

        Ok(())
    }

    pub fn update_access_authorization_expiry(
        &mut self,
        client: ClientId,
        resource: ResourceId,
        expires_at: DateTime<Utc>,
    ) -> anyhow::Result<()> {
        self.peers
            .get_mut(&client)
            .context("No peer state")?
            .update_resource_expiry(resource, expires_at);

        Ok(())
    }

    pub fn handle_domain_resolved(
        &mut self,
        req: ResolveDnsRequest,
        resolve_result: Result<Vec<IpAddr>, Arc<anyhow::Error>>,
        now: Instant,
    ) -> anyhow::Result<()> {
        use p2p_control::dns_resource_nat;

        let nat_status = resolve_result
            .and_then(|addresses| {
                self.peers
                    .get_mut(&req.client)
                    .context("Unknown peer")?
                    .setup_nat(
                        req.domain.clone(),
                        req.resource,
                        BTreeSet::from_iter(addresses),
                        BTreeSet::from_iter(req.proxy_ips),
                    )?;

                Ok(dns_resource_nat::NatStatus::Active)
            })
            .unwrap_or_else(|e| {
                tracing::warn!("Failed to setup DNS resource NAT: {e:#}");

                dns_resource_nat::NatStatus::Inactive
            });

        let packet = dns_resource_nat::domain_status(req.resource, req.domain, nat_status)?;

        let Some(transmit) = encrypt_packet(packet, req.client, &mut self.node, now)? else {
            return Ok(());
        };

        self.buffered_transmits.push_back(transmit);

        Ok(())
    }

    pub fn poll_timeout(&mut self) -> Option<(Instant, &'static str)> {
        iter::empty()
            // TODO: This should check when the next resource actually expires instead of doing it at a fixed interval.
            .chain(
                self.next_expiry_resources_check
                    .map(|instant| (instant, "resource expiry")),
            )
            .chain(self.node.poll_timeout())
            .min_by_key(|(instant, _)| *instant)
    }

    pub fn handle_timeout(&mut self, now: Instant, utc_now: DateTime<Utc>) {
        self.node.handle_timeout(now);
        self.drain_node_events();
        self.flow_tracker.handle_timeout(now);

        match self.next_expiry_resources_check {
            Some(next_expiry_resources_check) if now >= next_expiry_resources_check => {
                self.peers.iter_mut().for_each(|p| {
                    p.expire_resources(utc_now);
                    p.handle_timeout(now)
                });
                let removed_peers = self.peers.extract_if(|_, p| p.is_empty());

                for (id, _) in removed_peers {
                    tracing::debug!(cid = %id, "Access to last resource for Client removed");

                    self.node.close_connection(id, p2p_control::goodbye(), now);
                }

                self.next_expiry_resources_check = Some(now + EXPIRE_RESOURCES_INTERVAL);
            }
            None => self.next_expiry_resources_check = Some(now + EXPIRE_RESOURCES_INTERVAL),
            Some(_) => {}
        }

        while let Some(flow) = self.flow_tracker.poll_completed_flow() {
            match flow {
                flow_tracker::CompletedFlow::Tcp(flow) => {
                    tracing::trace!(
                        target: "flow_logs::tcp",

                        client_id = %flow.client_id,
                        client_version = flow.client_version.map(tracing::field::display),

                        device_os_name = flow.device_os_name.map(tracing::field::display),
                        device_os_version = flow.device_os_version.map(tracing::field::display),
                        device_serial = flow.device_serial.map(tracing::field::display),
                        device_uuid = flow.device_uuid.map(tracing::field::display),
                        device_identifier_for_vendor = flow.device_identifier_for_vendor.map(tracing::field::display),
                        device_firebase_installation_id = flow.device_firebase_installation_id.map(tracing::field::display),

                        auth_provider_id = flow.auth_provider_id.map(tracing::field::display),
                        actor_name = flow.actor_name.map(tracing::field::display),
                        actor_id = flow.actor_id.map(tracing::field::display),
                        actor_email = flow.actor_email.map(tracing::field::display),

                        resource_id = %flow.resource_id,
                        resource_name = %flow.resource_name,
                        resource_address = %flow.resource_address,
                        start = ?flow.start,
                        end = ?flow.end,
                        last_packet = ?flow.last_packet,

                        inner_src_ip = %flow.inner_src_ip,
                        inner_dst_ip = %flow.inner_dst_ip,
                        inner_src_port = %flow.inner_src_port,
                        inner_dst_port = %flow.inner_dst_port,
                        inner_domain = flow.inner_domain.map(tracing::field::display),

                        outer_src_ip = %flow.outer_src_ip,
                        outer_dst_ip = %flow.outer_dst_ip,
                        outer_src_port = %flow.outer_src_port,
                        outer_dst_port = %flow.outer_dst_port,

                        rx_packets = %flow.rx_packets,
                        tx_packets = %flow.tx_packets,
                        rx_bytes = %flow.rx_bytes,
                        tx_bytes = %flow.tx_bytes,
                        "TCP flow completed"
                    );
                }
                flow_tracker::CompletedFlow::Udp(flow) => {
                    tracing::trace!(
                        target: "flow_logs::udp",

                        client_id = %flow.client_id,
                        client_version = flow.client_version.map(tracing::field::display),

                        device_os_name = flow.device_os_name.map(tracing::field::display),
                        device_os_version = flow.device_os_version.map(tracing::field::display),
                        device_serial = flow.device_serial.map(tracing::field::display),
                        device_uuid = flow.device_uuid.map(tracing::field::display),
                        device_identifier_for_vendor = flow.device_identifier_for_vendor.map(tracing::field::display),
                        device_firebase_installation_id = flow.device_firebase_installation_id.map(tracing::field::display),

                        auth_provider_id = flow.auth_provider_id.map(tracing::field::display),
                        actor_name = flow.actor_name.map(tracing::field::display),
                        actor_id = flow.actor_id.map(tracing::field::display),
                        actor_email = flow.actor_email.map(tracing::field::display),

                        resource_id = %flow.resource_id,
                        resource_name = %flow.resource_name,
                        resource_address = %flow.resource_address,
                        start = ?flow.start,
                        end = ?flow.end,
                        last_packet = ?flow.last_packet,

                        inner_src_ip = %flow.inner_src_ip,
                        inner_dst_ip = %flow.inner_dst_ip,
                        inner_src_port = %flow.inner_src_port,
                        inner_dst_port = %flow.inner_dst_port,
                        inner_domain = flow.inner_domain.map(tracing::field::display),

                        outer_src_ip = %flow.outer_src_ip,
                        outer_dst_ip = %flow.outer_dst_ip,
                        outer_src_port = %flow.outer_src_port,
                        outer_dst_port = %flow.outer_dst_port,

                        rx_packets = %flow.rx_packets,
                        tx_packets = %flow.tx_packets,
                        rx_bytes = %flow.rx_bytes,
                        tx_bytes = %flow.tx_bytes,
                        "UDP flow completed"
                    );
                }
            }
        }
    }

    fn drain_node_events(&mut self) {
        let mut added_ice_candidates = BTreeMap::<ClientId, BTreeSet<IceCandidate>>::default();
        let mut removed_ice_candidates = BTreeMap::<ClientId, BTreeSet<IceCandidate>>::default();

        while let Some(event) = self.node.poll_event() {
            match event {
                snownet::Event::ConnectionFailed(_) | snownet::Event::ConnectionClosed(_) => {
                    // We purposely don't clear the peer-state here.
                    // The Client might re-establish the connection but if it hasn't cleared its local state too,
                    // it will consider all its access authorizations to be still valid.
                }
                snownet::Event::NewIceCandidate {
                    connection,
                    candidate,
                } => {
                    added_ice_candidates
                        .entry(connection)
                        .or_default()
                        .insert(candidate.into());
                }
                snownet::Event::InvalidateIceCandidate {
                    connection,
                    candidate,
                } => {
                    removed_ice_candidates
                        .entry(connection)
                        .or_default()
                        .insert(candidate.into());
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

    pub(crate) fn poll_transmit(&mut self) -> Option<snownet::Transmit> {
        self.buffered_transmits
            .pop_front()
            .or_else(|| self.node.poll_transmit())
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

    pub fn update_tun_device(&mut self, config: IpConfig) {
        self.tun_ip_config = Some(config);
    }

    pub fn retain_authorizations(
        &mut self,
        authorizations: BTreeMap<ClientId, BTreeSet<ResourceId>>,
    ) {
        for (client, resources) in authorizations {
            let Some(client) = self.peers.get_mut(&client) else {
                continue;
            };

            client.retain_authorizations(resources);
        }
    }
}

fn handle_assigned_ips_event(
    fz_p2p_control: FzP2pControlSlice,
    peer: &ClientOnGateway,
    buffered_events: &mut VecDeque<GatewayEvent>,
) -> Option<IpPacket> {
    use p2p_control::dns_resource_nat;

    let Ok(req) = dns_resource_nat::decode_assigned_ips(fz_p2p_control)
        .inspect_err(|e| tracing::debug!("{e:#}"))
    else {
        return None;
    };

    if !peer.is_allowed(req.resource) {
        tracing::warn!(cid = %peer.id(), rid = %req.resource, domain = %req.domain, "Received `AssignedIpsEvent` for resource that is not allowed");

        let packet = dns_resource_nat::domain_status(
            req.resource,
            req.domain,
            dns_resource_nat::NatStatus::Inactive,
        )
        .inspect_err(|e| tracing::warn!("Failed to create `DomainStatus` packet: {e:#}"))
        .ok()?;

        return Some(packet);
    }

    // TODO: Should we throttle concurrent events for the same domain?

    buffered_events.push_back(GatewayEvent::ResolveDns(ResolveDnsRequest {
        domain: req.domain,
        client: peer.id(),
        resource: req.resource,
        proxy_ips: req.proxy_ips,
    }));

    None
}

fn encrypt_packet(
    packet: IpPacket,
    cid: ClientId,
    node: &mut ServerNode<ClientId, RelayId>,
    now: Instant,
) -> Result<Option<Transmit>> {
    let transmit = node
        .encapsulate(cid, &packet, now)
        .context("Failed to encapsulate")?;

    Ok(transmit)
}

/// Opaque request struct for when a domain name needs to be resolved.
#[derive(Debug)]
pub struct ResolveDnsRequest {
    domain: DomainName,
    client: ClientId,
    resource: ResourceId,
    proxy_ips: Vec<IpAddr>,
}

impl ResolveDnsRequest {
    pub fn domain(&self) -> &DomainName {
        &self.domain
    }

    pub fn client(&self) -> ClientId {
        self.client
    }
}
