pub(crate) mod nat_table;

use crate::authorization_rejections::AuthorizationRejections;
use crate::messages::gateway::{Client, ResourceDescription};
use crate::messages::{IceCredentials, IngestToken, ResolveRequest};
use crate::peer_inbound::{PeerInbound, TranslateOutboundResult};
use crate::peer_store::PeerStore;
use crate::portal_connection::PortalConnection;
use crate::unix_ts::UnixTsClock;
use crate::unroutable_packet::UnroutablePacket;
use crate::{FailedToDecapsulate, GatewayEvent, IpConfig, p2p_control, packet_kind};
use anyhow::{Context, ErrorExt, Result};
use connlib_model::{ClientId, IceCandidate, RelayId, ResourceId};
use dns_types::DomainName;
use fast_random_state::FastRandomState;
use ip_packet::{FzP2pControlSlice, IpPacket};
use secrecy::ExposeSecret as _;
use snownet::{IceConfig, Node, RelaySocket};
use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};
use std::iter;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::{Duration, Instant};
use zeroize::Zeroizing;

pub const TUN_DNS_PORT: u16 = 53535;

/// A SANS-IO implementation of a gateway's functionality.
///
/// Internally, this composes a [`snownet::Node`] with firezone's policy engine around resources.
pub struct GatewayState {
    /// Manages wireguard tunnels to clients.
    node: Node<ClientId, RelayId>,
    /// All clients we are connected to and the associated, connection-specific state.
    peers: PeerStore<ClientId, PeerInbound>,

    /// Tracks the flows tunneled through this Gateway.
    flow_tracker: flow_tracker::Tracker<(ClientId, ResourceId)>,
    authorization_rejections: AuthorizationRejections,

    tun_ip_config: Option<IpConfig>,

    unix_ts_clock: UnixTsClock,

    /// Drives a 1 Hz wake-up so test harnesses (and any callers without
    /// other near-term work) pump the gateway's internal subsystems
    /// (NAT/flow tracking eviction etc.) at a regular cadence. Lazily
    /// initialised on the first `handle_timeout` call.
    next_periodic_tick: Option<Instant>,

    buffered_events: VecDeque<GatewayEvent>,
    buffered_transmits: VecDeque<snownet::Transmit>,

    /// Our connection to the portal, holding back ICE candidates while it is down.
    portal: PortalConnection<ClientId>,
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
    pub fn new(seed: [u8; 32], now: Instant, unix_ts: Duration) -> Self {
        Self {
            peers: Default::default(),
            node: Node::new(seed, now, unix_ts),
            portal: Default::default(),
            buffered_events: VecDeque::default(),
            buffered_transmits: VecDeque::default(),
            flow_tracker: flow_tracker::Tracker::new(now, unix_ts),
            authorization_rejections: Default::default(),
            tun_ip_config: None,
            unix_ts_clock: UnixTsClock::new(now, unix_ts),
            next_periodic_tick: None,
        }
    }

    pub fn set_flow_logs_enabled(&mut self, enabled: bool) {
        self.flow_tracker.set_enabled(enabled);
    }

    pub fn tunnel_ip_config(&self) -> Option<IpConfig> {
        self.tun_ip_config
    }

    pub fn public_key(&self) -> sanstun::PublicKey {
        self.node.public_key()
    }

    pub fn shut_down(&mut self, now: Instant) {
        tracing::info!("Initiating graceful shutdown");

        self.flow_tracker.close_all(now);
        self.peers.clear();
        self.node.close_all(p2p_control::goodbye(), now);
    }

    /// Handles packets received on the TUN device.
    ///
    /// The returned [`snownet::PendingEncapsulate`] is for `packet` as this call leaves it.
    pub fn handle_tun_input(
        &mut self,
        packet: &mut IpPacket,
        now: Instant,
    ) -> Result<Option<snownet::PendingEncapsulate>> {
        let _guard = self.flow_tracker.begin_tun_packet(packet, now);

        if packet.is_fz_p2p_control() {
            tracing::warn!("Packet matches heuristics of FZ p2p control protocol");
        }

        let dst = packet.destination();

        anyhow::ensure!(crate::is_peer(dst), UnroutablePacket::not_a_peer(packet));

        let (cid, peer) = self
            .peers
            .peer_by_ip_mut(dst)
            .with_context(|| UnroutablePacket::no_peer_state(packet))?;

        flow_tracker::record_peer(cid, flow_tracker::Role::Responder);

        if let Err(e) = peer.translate_inbound(packet, now) {
            return Err(e.context("Failed to translate inbound packet"));
        }

        let Some(encapsulation) = encapsulate(packet, cid, &mut self.node, now)? else {
            return Ok(None);
        };

        flow_tracker::record_transmit(encapsulation.src(), encapsulation.dst());

        Ok(Some(encapsulation))
    }

    /// Handles UDP packets received on the network interface.
    ///
    /// Most of these packets will be WireGuard data messages and will thus yield a [`snownet::PendingDecapsulate`].
    /// Decrypt it from `packet` and pass the result to [`GatewayState::handle_peer_input`].
    /// Some of them will however be handled internally, for example, TURN control packets exchanged with relays.
    ///
    /// In case this function returns `None`, you should call [`GatewayState::handle_timeout`] next to fully advance the internal state.
    pub fn handle_network_input(
        &mut self,
        local: SocketAddr,
        from: SocketAddr,
        packet: &[u8],
        now: Instant,
    ) -> Result<Option<snownet::PendingDecapsulate>> {
        match self.node.begin_decapsulate(local, from, packet, now) {
            Ok(decapsulation) => Ok(decapsulation),
            Err(e) => Err(e.context(FailedToDecapsulate(packet_kind::classify(packet)))),
        }
    }

    /// Handles a WireGuard data message decrypted from a [`snownet::PendingDecapsulate`].
    ///
    /// `local` and `from` are the addresses the message was received on and from.
    ///
    /// In case this function returns `None`, you should call [`GatewayState::handle_timeout`] next to fully advance the internal state.
    pub fn handle_peer_input(
        &mut self,
        local: SocketAddr,
        from: SocketAddr,
        packet: snownet::DecryptedIpPacket,
        now: Instant,
    ) -> Result<Option<IpPacket>> {
        let _guard = self.flow_tracker.begin_network_packet(local, from, now);

        let decrypted = match self.node.commit_decrypted(packet, now) {
            Ok(decrypted) => decrypted,
            Err(e) => return Err(e.context(FailedToDecapsulate(packet_kind::Kind::Wireguard))),
        };
        let Some((cid, packet)) = decrypted else {
            return Ok(None);
        };

        if packet.destination().is_multicast() {
            return Ok(None);
        }

        flow_tracker::record_decrypted_packet(&packet);

        let peer = self
            .peers
            .peer_by_id_mut(&cid)
            .with_context(|| format!("No peer for connection {cid}"))?;

        flow_tracker::record_peer(cid, flow_tracker::Role::Responder);

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

            if let Some(transmit) = encrypt_packet(immediate_response, cid, &mut self.node, now)? {
                self.buffered_transmits.push_back(transmit);
            }

            return Ok(None);
        }

        let translated = match peer.translate_outbound(packet, now) {
            Ok(translated) => translated,
            Err(e) => return Err(e.context("Failed to translate outbound packet")),
        };

        match translated {
            TranslateOutboundResult::Send(packet) => Ok(Some(packet)),
            TranslateOutboundResult::IcmpError {
                reply,
                no_authorization,
            } => {
                flow_tracker::record_icmp_error(&reply);

                if let Some(transmit) = encrypt_packet(reply, cid, &mut self.node, now)? {
                    self.buffered_transmits.push_back(transmit);
                }

                if let Some(event) = no_authorization.and_then(|rejection| {
                    self.authorization_rejections
                        .on_rejected(cid, rejection, now)
                }) && let Some(transmit) = encrypt_packet(event, cid, &mut self.node, now)?
                {
                    self.buffered_transmits.push_back(transmit);
                }

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
    }

    pub fn remove_ice_candidate(
        &mut self,
        conn_id: ClientId,
        ice_candidate: IceCandidate,
        now: Instant,
    ) {
        self.node
            .remove_remote_candidate(conn_id, ice_candidate.into(), now);
    }

    #[tracing::instrument(level = "debug", skip_all, fields(%rid, %cid))]
    pub fn remove_access(&mut self, cid: &ClientId, rid: &ResourceId, now: Instant) {
        let Some(peer) = self.peers.peer_by_id_mut(cid) else {
            return;
        };

        peer.revoke(rid);
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
    pub fn create_authorization(
        &mut self,
        client: Client,
        client_ice: IceCredentials,
        gateway_ice: IceCredentials,
        expires_at: Option<Duration>,
        resource: ResourceDescription,
        use_iceless: bool,
        ice_role: crate::messages::IceRole,
        now: Instant,
        flow_logs_ingest_token: IngestToken,
    ) {
        self.node.upsert_connection(
            client.id,
            client.public_key.into(),
            sanstun::StaticSecret::from(Zeroizing::new(client.preshared_key.expose_secret().0)),
            gateway_ice.into(),
            client_ice.into(),
            ice_role.into(),
            IceConfig::server_default(),
            IceConfig::server_idle(),
            use_iceless,
            now,
        );

        let result = self.allow_access(
            client.id,
            IpConfig {
                v4: client.ipv4,
                v6: client.ipv6,
            },
            flow_logs_ingest_token,
            expires_at,
            resource,
            None,
            now,
        );
        debug_assert!(
            result.is_ok(),
            "`allow_access` should never fail without a `DnsResourceEntry`"
        );
    }

    pub fn allow_access(
        &mut self,
        client: ClientId,
        client_tun: IpConfig,
        flow_logs_ingest_token: IngestToken,
        expires_at: Option<Duration>,
        resource: ResourceDescription,
        dns_resource_nat: Option<DnsResourceNatEntry>,
        now: Instant,
    ) -> Result<()> {
        let gateway_tun = self.tun_ip_config.context("TUN device not configured")?;

        let expires_at = expires_at.map(|d| self.unix_ts_clock.instant_at(d, now));
        let expires_in = expires_at.map(|e| e.saturating_duration_since(now));

        tracing::info!(
            cid = %client,
            rid = %resource.id(),
            expires_in = expires_in.map(tracing::field::debug),
            "Allowing access to resource",
        );

        let peer = self.peers.upsert(client, || {
            PeerInbound::new(
                client,
                client_tun,
                gateway_tun,
                String::new(),
                String::new(),
            )
        });

        peer.add_resource(resource.clone(), expires_at, now);
        peer.set_ingest_token(resource.id(), flow_logs_ingest_token);

        if let Some(entry) = dns_resource_nat {
            peer.setup_nat(
                entry.domain,
                resource.id(),
                BTreeSet::from_iter(entry.resolved_ips),
                BTreeSet::from_iter(entry.proxy_ips),
            )?;
        }

        Ok(())
    }

    pub fn update_access_authorization_expiry(
        &mut self,
        client: ClientId,
        resource: ResourceId,
        expires_at: Duration,
        now: Instant,
    ) -> Result<()> {
        let new_expiry = self.unix_ts_clock.instant_at(expires_at, now);
        let expires_in = new_expiry.saturating_duration_since(now);

        tracing::info!(
            cid = %client,
            rid = %resource,
            expires_in = ?expires_in,
            "Updating resource expiry",
        );

        self.peers
            .peer_by_id_mut(&client)
            .context("No peer state")?
            .update_expiry(resource, new_expiry, now);

        Ok(())
    }

    pub fn handle_domain_resolved(
        &mut self,
        req: ResolveDnsRequest,
        resolve_result: Result<Vec<IpAddr>, Arc<anyhow::Error>>,
        now: Instant,
    ) -> Result<()> {
        use p2p_control::dns_resource_nat;

        let nat_status = resolve_result
            .and_then(|addresses| {
                self.peers
                    .peer_by_id_mut(&req.client)
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

        if let Some(transmit) = encrypt_packet(packet, req.client, &mut self.node, now)? {
            self.buffered_transmits.push_back(transmit);
        }

        Ok(())
    }

    pub fn poll_timeout(&mut self) -> Option<(Instant, &'static str)> {
        iter::empty()
            .chain(
                self.authorization_rejections
                    .poll_timeout()
                    .map(|instant| (instant, "Authorization rejection expiry")),
            )
            .chain(self.node.poll_timeout())
            .chain(
                self.next_periodic_tick
                    .map(|instant| (instant, "periodic tick")),
            )
            .min_by_key(|(instant, _)| *instant)
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.node.handle_timeout(now);
        self.drain_node_events();

        self.flow_tracker.handle_timeout(now);
        self.authorization_rejections.handle_timeout(now);

        self.peers.iter_mut().for_each(|p| {
            p.handle_timeout(now);
        });
        let removed_peers = self.peers.extract_if(|_, p| p.is_empty());

        for (id, _) in removed_peers {
            tracing::debug!(cid = %id, "Access to last resource for Client removed");

            self.node.close_connection(id, p2p_control::goodbye(), now);
        }

        self.next_periodic_tick = Some(now + Duration::from_secs(1));
    }

    fn drain_node_events(&mut self) {
        let mut added_ice_candidates =
            HashMap::<ClientId, BTreeSet<IceCandidate>, FastRandomState>::default();
        let mut removed_ice_candidates =
            HashMap::<ClientId, BTreeSet<IceCandidate>, FastRandomState>::default();

        while let Some(event) = self.node.poll_event() {
            match event {
                snownet::Event::ConnectionFailed(id) | snownet::Event::ConnectionClosed(id) => {
                    // We purposely don't clear the peer-state here.
                    // The Client might re-establish the connection but if it hasn't cleared its local state too,
                    // it will consider all its access authorizations to be still valid.
                    self.portal.forget(&id);
                }
                snownet::Event::NewIceCandidate {
                    connection,
                    candidate,
                } if !self.portal.is_connected() => {
                    self.portal.hold_added(connection, candidate.into());
                }
                snownet::Event::InvalidateIceCandidate {
                    connection,
                    candidate,
                } if !self.portal.is_connected() => {
                    self.portal.hold_removed(connection, candidate.into());
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
                snownet::Event::NoRelays { blocked } => {
                    self.buffered_events.push_back(GatewayEvent::NoRelays {
                        excluded_relay_ids: blocked,
                    });
                }
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

    /// How many transmits the state itself has queued for [`Self::poll_transmit`].
    #[cfg(debug_assertions)]
    pub fn num_buffered_transmits(&self) -> usize {
        self.buffered_transmits.len()
    }

    pub fn poll_transmit(&mut self) -> Option<snownet::Transmit> {
        self.buffered_transmits
            .pop_front()
            .or_else(|| self.node.poll_transmit())
    }

    pub fn poll_event(&mut self) -> Option<GatewayEvent> {
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

    /// Records whether we currently have a live connection to the portal.
    ///
    /// While disconnected, ICE candidate changes are held back. On the disconnected ->
    /// connected edge, the held changes are flushed to their clients, one batch per
    /// connection.
    pub fn set_portal_connected(&mut self, connected: bool) {
        if !connected {
            self.portal.disconnect();
            return;
        }

        let held = self.portal.connect();

        for (conn_id, candidates) in held.added {
            if candidates.is_empty() {
                continue;
            }

            self.buffered_events
                .push_back(GatewayEvent::AddedIceCandidates {
                    conn_id,
                    candidates,
                });
        }

        for (conn_id, candidates) in held.removed {
            if candidates.is_empty() {
                continue;
            }

            self.buffered_events
                .push_back(GatewayEvent::RemovedIceCandidates {
                    conn_id,
                    candidates,
                });
        }
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
        mut authorizations: BTreeMap<ClientId, BTreeSet<ResourceId>>,
    ) {
        for client in self.peers.iter_mut() {
            let resources = authorizations.remove(&client.id()).unwrap_or_default();

            client.retain(&resources);
        }
    }
}

fn handle_assigned_ips_event(
    fz_p2p_control: FzP2pControlSlice,
    peer: &PeerInbound,
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
    node: &mut Node<ClientId, RelayId>,
    now: Instant,
) -> Result<Option<snownet::Transmit>> {
    let Some(encapsulation) = encapsulate(&packet, cid, node, now)? else {
        return Ok(None);
    };

    Ok(Some(encapsulation.encrypt(&packet)?))
}

fn encapsulate(
    packet: &IpPacket,
    cid: ClientId,
    node: &mut Node<ClientId, RelayId>,
    now: Instant,
) -> Result<Option<snownet::PendingEncapsulate>> {
    match node.encapsulate(cid, packet, now) {
        Ok(encapsulation) => Ok(encapsulation),
        // The Gateway does not buffer: it only sends in response to Client traffic.
        Err(e) if e.any_is::<snownet::StillConnecting>() => {
            tracing::debug!(%cid, "Connection is still establishing; dropping packet");
            Ok(None)
        }
        Err(e) if e.any_is::<snownet::UnknownConnection>() => {
            Err(e.context(UnroutablePacket::not_connected(packet)))
        }
        Err(e) => Err(e).context("Failed to encapsulate"),
    }
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

    pub fn proxy_ips(&self) -> &[IpAddr] {
        &self.proxy_ips
    }
}
