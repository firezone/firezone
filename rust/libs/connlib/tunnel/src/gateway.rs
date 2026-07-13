mod client_on_gateway;
mod nat_table;

pub(crate) use crate::gateway::client_on_gateway::ClientOnGateway;

use crate::gateway::client_on_gateway::TranslateOutboundResult;
use crate::messages::gateway::{Client, ResourceDescription};
use crate::messages::{IceCredentials, IngestToken, ResolveRequest};
use crate::peer_store::PeerStore;
use crate::unix_ts::UnixTsClock;
use crate::unroutable_packet::UnroutablePacket;
use crate::{FailedToDecapsulate, GatewayEvent, IpConfig, p2p_control, packet_kind};
use anyhow::{Context, ErrorExt, Result};
use boringtun::x25519::{self, PublicKey};
use connlib_model::{ClientId, IceCandidate, RelayId, ResourceId};
use dns_types::DomainName;
use ip_packet::{FzP2pControlSlice, IpPacket};
use secrecy::ExposeSecret as _;
use snownet::{IceConfig, IceRole, NoTurnServers, Node, RelaySocket};
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::iter;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::{Duration, Instant};

pub const TUN_DNS_PORT: u16 = 53535;

/// A SANS-IO implementation of a gateway's functionality.
///
/// Internally, this composes a [`snownet::Node`] with firezone's policy engine around resources.
pub struct GatewayState {
    /// Manages wireguard tunnels to clients.
    node: Node<ClientId, RelayId>,
    /// All clients we are connected to and the associated, connection-specific state.
    peers: PeerStore<ClientId, ClientOnGateway>,

    /// Tracks the flows tunneled through this Gateway.
    flow_tracker: flow_tracker::Tracker<(ClientId, ResourceId)>,

    tun_ip_config: Option<IpConfig>,

    unix_ts_clock: UnixTsClock,

    /// Drives a 1 Hz wake-up so test harnesses (and any callers without
    /// other near-term work) pump the gateway's internal subsystems
    /// (NAT/flow tracking eviction etc.) at a regular cadence. Lazily
    /// initialised on the first `handle_timeout` call.
    next_periodic_tick: Option<Instant>,

    buffered_events: VecDeque<GatewayEvent>,
    buffered_transmits: snownet::TransmitBuffer,
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
    #[cfg_attr(feature = "test-util", visibility::make(pub))]
    pub(crate) fn new(seed: [u8; 32], now: Instant, unix_ts: Duration) -> Self {
        Self {
            peers: Default::default(),
            node: Node::new(seed, now, unix_ts),
            buffered_events: VecDeque::default(),
            buffered_transmits: snownet::TransmitBuffer::default(),
            flow_tracker: flow_tracker::Tracker::new(now, unix_ts),
            tun_ip_config: None,
            unix_ts_clock: UnixTsClock::new(now, unix_ts),
            next_periodic_tick: None,
        }
    }

    pub fn set_flow_logs_enabled(&mut self, enabled: bool) {
        self.flow_tracker.set_enabled(enabled);
    }

    #[cfg(feature = "test-util")]
    #[cfg_attr(feature = "test-util", visibility::make(pub))]
    pub(crate) fn tunnel_ip_config(&self) -> Option<IpConfig> {
        self.tun_ip_config
    }

    #[cfg_attr(feature = "test-util", visibility::make(pub))]
    pub(crate) fn public_key(&self) -> PublicKey {
        self.node.public_key()
    }

    pub fn shut_down(&mut self, now: Instant) {
        tracing::info!("Initiating graceful shutdown");
        coverage::cov!("tunnel.graceful_shutdown");

        self.flow_tracker.close_all(now);
        self.peers.clear();
        self.node.close_all(p2p_control::goodbye(), now);
    }

    /// Handles packets received on the TUN device.
    #[cfg_attr(feature = "test-util", visibility::make(pub))]
    pub(crate) fn handle_tun_input(
        &mut self,
        packet: IpPacket,
        now: Instant,
        provider: &mut impl snownet::BufferProvider,
    ) -> Result<()> {
        let _guard = self.flow_tracker.begin_tun_packet(&packet, now);

        if packet.is_fz_p2p_control() {
            tracing::warn!("Packet matches heuristics of FZ p2p control protocol");
        }

        let dst = packet.destination();

        anyhow::ensure!(crate::is_peer(dst), UnroutablePacket::not_a_peer(&packet));

        let (cid, peer) = self
            .peers
            .peer_by_ip_mut(dst)
            .with_context(|| UnroutablePacket::no_peer_state(&packet))?;

        flow_tracker::record_peer(cid, flow_tracker::Role::Responder);

        let packet = peer
            .translate_inbound(packet, now)
            .context("Failed to translate inbound packet")?;

        let Some(info) = encrypt_packet(packet, cid, &mut self.node, provider, now)? else {
            return Ok(());
        };

        flow_tracker::record_transmit(info.src, info.dst);

        Ok(())
    }

    /// Handles UDP packets received on the network interface.
    ///
    /// Most of these packets will be WireGuard encrypted IP packets and will thus yield an [`IpPacket`].
    /// Some of them will however be handled internally, for example, TURN control packets exchanged with relays.
    ///
    /// In case this function returns `None`, you should call [`GatewayState::handle_timeout`] next to fully advance the internal state.
    #[cfg_attr(feature = "test-util", visibility::make(pub))]
    pub(crate) fn handle_network_input(
        &mut self,
        local: SocketAddr,
        from: SocketAddr,
        packet: &[u8],
        now: Instant,
    ) -> Result<Option<IpPacket>> {
        let _guard = self.flow_tracker.begin_network_packet(local, from, now);

        let Some((cid, packet)) = self
            .node
            .decapsulate(local, from, packet, now)
            .with_context(|| FailedToDecapsulate(packet_kind::classify(packet)))?
        else {
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

            encrypt_packet(
                immediate_response,
                cid,
                &mut self.node,
                &mut self.buffered_transmits,
                now,
            )?;

            return Ok(None);
        }

        match peer
            .translate_outbound(packet, now)
            .context("Failed to translate outbound packet")?
        {
            TranslateOutboundResult::Send(packet) => {
                flow_tracker::record_translated_packet(&packet);

                Ok(Some(packet))
            }
            TranslateOutboundResult::DestinationUnreachable(reply)
            | TranslateOutboundResult::Filtered(reply) => {
                flow_tracker::record_icmp_error(&reply);

                encrypt_packet(
                    reply,
                    cid,
                    &mut self.node,
                    &mut self.buffered_transmits,
                    now,
                )?;

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
        client_ice: IceCredentials,
        gateway_ice: IceCredentials,
        expires_at: Option<Duration>,
        resource: ResourceDescription,
        use_iceless: bool,
        now: Instant,
        flow_logs_ingest_token: IngestToken,
    ) -> Result<(), NoTurnServers> {
        self.node.upsert_connection(
            client.id,
            client.public_key.into(),
            x25519::StaticSecret::from(client.preshared_key.expose_secret().0),
            gateway_ice.into(),
            client_ice.into(),
            IceRole::Controlled,
            IceConfig::server_default(),
            IceConfig::server_idle(),
            use_iceless,
            now,
        )?;

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

        Ok(())
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
    ) -> anyhow::Result<()> {
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
            ClientOnGateway::new(client, client_tun, gateway_tun)
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
    ) -> anyhow::Result<()> {
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
            .update_resource_expiry(resource, new_expiry, now);

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

        encrypt_packet(
            packet,
            req.client,
            &mut self.node,
            &mut self.buffered_transmits,
            now,
        )?;

        Ok(())
    }

    pub fn poll_timeout(&mut self) -> Option<(Instant, &'static str)> {
        iter::empty()
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
                snownet::Event::NoRelays => {
                    self.buffered_events.push_back(GatewayEvent::NoRelays);
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

    #[cfg_attr(feature = "test-util", visibility::make(pub))]
    pub(crate) fn poll_transmit(&mut self) -> Option<snownet::Transmit> {
        self.buffered_transmits
            .poll_transmit()
            .or_else(|| self.node.poll_transmit())
    }

    #[cfg_attr(feature = "test-util", visibility::make(pub))]
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
            let Some(client) = self.peers.peer_by_id_mut(&client) else {
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
    node: &mut Node<ClientId, RelayId>,
    provider: &mut impl snownet::BufferProvider,
    now: Instant,
) -> Result<Option<snownet::EncapsulateInfo>> {
    match node.encapsulate(cid, &packet, now, provider) {
        Ok(info) => Ok(info),
        // The Gateway does not buffer: it only sends in response to Client traffic.
        Err(e) if e.any_is::<snownet::StillConnecting>() => {
            tracing::debug!(%cid, "Connection is still establishing; dropping packet");
            Ok(None)
        }
        Err(e) if e.any_is::<snownet::UnknownConnection>() => {
            Err(e.context(UnroutablePacket::not_connected(&packet)))
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
}
