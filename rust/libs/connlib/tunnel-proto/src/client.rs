pub(crate) mod dns_config;

mod client_on_client;
mod dns_cache;
mod dns_resource_nat;
mod gateway_on_client;
mod pending_authorizations;
pub(crate) mod resource;
mod routing;
mod tracked_state;

pub(crate) use crate::client::client_on_client::ClientOnClient;
pub(crate) use crate::client::gateway_on_client::GatewayOnClient;
use resource::{DevicePoolResource, InternetResource, Resource};

use crate::client::client_on_client::InboundResult;
use crate::client::dns_cache::DnsCache;
use crate::client::dns_config::DnsConfig;
use crate::client::pending_authorizations::{
    AuthorizationRequest, DnsQueryForSite, PendingAuthorizations,
};
use crate::client::routing::{MatchedRoutes, RoutingTables};
use crate::client::tracked_state::TrackedState;
use crate::conn_track::Originator;
use crate::dns::{
    DeviceStubResolver, DnsResourceRecord, ResourceStubResolver, device_stub_resolver,
    resource_stub_resolver,
};
use crate::filter_engine::FilterEngine;
use crate::messages::IngestToken;
use crate::messages::{
    Filter, IceCredentials, IceRole, Interface as InterfaceConfig, SecretKey, client::FailReason,
};
use crate::peer_store::{Peer, PeerStore};
use crate::portal_connection::PortalConnection;
use crate::unique_packet_buffer::UniquePacketBuffer;
use crate::unix_ts::UnixTsClock;
use crate::unroutable_packet::UnroutablePacket;
use crate::{ClientEvent, FailedToDecapsulate, otel, packet_kind};
use crate::{IPV4_TUNNEL, IPV6_TUNNEL, IpConfig, TunConfig, dns, p2p_control};
use anyhow::{Context, ErrorExt, Result};
use boringtun::x25519;
use connlib_model::{
    ClientId, ClientOrGatewayId, ConnectedDeviceView, GatewayId, IceCandidate, PublicKey, RelayId,
    ResourceId, ResourceList, ResourceStatus, ResourceView,
};
use connlib_model::{Site, SiteId};
use dns_resource_nat::DnsResourceNat;
use dns_types::DomainName;
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_packet::{IpPacket, MAX_UDP_PAYLOAD, Protocol};
use itertools::Itertools;
use logging::{unwrap_or_debug, unwrap_or_warn};
use secrecy::ExposeSecret as _;
use snownet::{NoTurnServers, Node, RelaySocket};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::ops::ControlFlow;
use std::time::{Duration, Instant};
use std::{io, iter};

pub const IPV4_RESOURCES: Ipv4Network = match Ipv4Network::new(Ipv4Addr::new(100, 96, 0, 0), 11) {
    Ok(n) => n,
    Err(_) => unreachable!(),
};
pub const IPV6_RESOURCES: Ipv6Network = match Ipv6Network::new(
    Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0x8000, 0, 0, 0, 0),
    107,
) {
    Ok(n) => n,
    Err(_) => unreachable!(),
};

const DNS_PORT: u16 = 53;

const LLMNR_PORT: u16 = 5355;
const LLMNR_IPV4: Ipv4Addr = Ipv4Addr::new(224, 0, 0, 252);
const LLMNR_IPV6: Ipv6Addr = Ipv6Addr::new(0xff02, 0, 0, 0, 0, 1, 0, 3);

pub const DNS_SENTINELS_V4: Ipv4Network =
    match Ipv4Network::new(Ipv4Addr::new(100, 100, 111, 0), 24) {
        Ok(n) => n,
        Err(_) => unreachable!(),
    };
pub const DNS_SENTINELS_V6: Ipv6Network = match Ipv6Network::new(
    Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0x8000, 0x0100, 0x0100, 0x0111, 0),
    120,
) {
    Ok(n) => n,
    Err(_) => unreachable!(),
};

/// How many concurrent TCP DNS clients we can server _per_ sentinel DNS server IP.
const NUM_CONCURRENT_TCP_DNS_CLIENTS: usize = 10;

/// How long after we reset a site status from "Offline" back to "Unknown".
const OFFLINE_SITE_STATUS_TIMEOUT: Duration = Duration::from_secs(5 * 60);

/// How long we track the DNS stream of a recursive query before we discard it.
///
/// Our DNS clients time out queries much earlier, so this only ever triggers if one of them drops a query without a result.
const DNS_STREAM_TIMEOUT: Duration = Duration::from_secs(60);

/// Identifies a recursive DNS query we issued to an upstream resolver.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum UpstreamQuery {
    Udp(l3_udp_dns_client::QueryToken),
    Tcp(dns_over_tcp::QueryToken),
}

/// A sans-IO implementation of a Client's functionality.
///
/// Internally, this composes a [`snownet::Node`] with firezone's policy engine around resources.
/// Clients differ from gateways in that they also implement a DNS resolver for DNS resources.
/// They also initiate connections to:
/// - Gateways based on packets sent to Resources
/// - Other clients based on packets to their TUN device IPs
///
/// Gateways only accept incoming connections.
pub struct ClientState {
    /// Manages wireguard tunnels to gateways and clients.
    node: Node<ClientOrGatewayId, RelayId>,
    /// All gateways we are connected to and the associated, connection-specific state.
    gateways: PeerStore<GatewayId, GatewayOnClient>,
    /// All clients we are connected to and the associated, connection-specific state.
    clients: PeerStore<ClientId, ClientOnClient>,

    /// Tracks the flows tunneled through this Client.
    flow_tracker: flow_tracker::Tracker<ClientOrGatewayId>,
    /// Tracks the authorizations we have requested but not yet been granted.
    pending_authorizations: PendingAuthorizations,

    /// Routed IP packets buffered per peer while its connection is still being established.
    ///
    /// These packets are replayed through normal routing when the connection is established so
    /// their route is validated again and the successful send is included in flow tracking.
    pending_routed_packets: BTreeMap<ClientOrGatewayId, UniquePacketBuffer>,

    /// IP packets whose destination peer was selected by protocol context rather than routing.
    ///
    /// These include peer-to-peer control packets and replies to filtered direct-client traffic.
    /// They retain their selected peer and bypass normal routing when the connection is
    /// established.
    pending_peer_packets: BTreeMap<ClientOrGatewayId, UniquePacketBuffer>,

    dns_resource_nat: DnsResourceNat,
    /// Outbound authorizations received from the portal.
    ///
    /// This state persists across `reset`s so we can re-attach to the same
    /// gateway / pool peers.
    outbound_authorizations: OutboundAuthorizations,
    /// Tracks which gateways are in a site.
    ///
    /// This state gets populated as we connect to various Gateways.
    /// Gateways are bound to a single site, hence this state is never cleaned up.
    /// An entry in this data structure does _not_ mean that we are connected to the Gateway / site.
    gateways_by_site: HashMap<SiteId, HashSet<GatewayId>>,
    /// The online/offline status of a site, together with the timestamp when we set it.
    sites_status: BTreeMap<SiteId, (ResourceStatus, Instant)>,

    routing_tables: RoutingTables,
    is_internet_resource_active: bool,
    /// All resources indexed by their ID.
    resources_by_id: BTreeMap<ResourceId, Resource>,

    /// Manages the DNS configuration.
    dns_config: DnsConfig,

    /// Resolves DNS queries for DNS resources by assigning proxy IPs and managing records.
    resource_stub_resolver: ResourceStubResolver,
    /// Resolves DNS queries for devices.
    device_stub_resolver: DeviceStubResolver,
    /// Caches responses from DNS servers.
    dns_cache: DnsCache,

    /// Configuration of the TUN device, when it is up.
    tun_config: TrackedState<TunConfig>,
    /// Cache of the resource list we emitted to the app.
    resource_list: TrackedState<ResourceList>,

    udp_dns_client: l3_udp_dns_client::Client,
    tcp_dns_client: dns_over_tcp::Client,
    tcp_dns_server: dns_over_tcp::Server,
    /// Tracks the UDP/TCP stream (i.e. socket-pair) on which we received a DNS query by the token of the recursive DNS query we issued.
    dns_streams_by_upstream_query: HashMap<UpstreamQuery, (SocketAddr, SocketAddr, Instant)>,

    buffered_events: VecDeque<ClientEvent>,
    buffered_packets: VecDeque<IpPacket>,
    buffered_transmits: snownet::TransmitBuffer,

    /// Our connection to the portal, holding back ICE candidates while it is down.
    portal: PortalConnection<ClientOrGatewayId>,

    unix_ts_clock: UnixTsClock,
    buffered_dns_queries: VecDeque<dns::RecursiveQuery>,
    dns_lookup_duration: opentelemetry::metrics::Histogram<f64>,
}

impl ClientState {
    pub fn new(
        seed: [u8; 32],
        records: BTreeSet<DnsResourceRecord>,
        is_internet_resource_active: bool,
        now: Instant,
        unix_ts: Duration,
    ) -> Self {
        Self {
            outbound_authorizations: Default::default(),
            routing_tables: RoutingTables::default(),
            resources_by_id: Default::default(),
            gateways: Default::default(),
            clients: Default::default(),
            dns_config: Default::default(),
            buffered_events: Default::default(),
            tun_config: Default::default(),
            buffered_packets: Default::default(),
            node: Node::new(seed, now, unix_ts),
            flow_tracker: flow_tracker::Tracker::new(now, unix_ts),
            portal: Default::default(),
            sites_status: Default::default(),
            gateways_by_site: Default::default(),
            resource_stub_resolver: ResourceStubResolver::new(records),
            device_stub_resolver: Default::default(),
            dns_cache: Default::default(),
            buffered_transmits: Default::default(),
            is_internet_resource_active,
            buffered_dns_queries: Default::default(),
            udp_dns_client: l3_udp_dns_client::Client::new(seed),
            tcp_dns_client: dns_over_tcp::Client::new(now, Duration::from_secs(10), seed),
            tcp_dns_server: dns_over_tcp::Server::new(now),
            dns_streams_by_upstream_query: Default::default(),
            pending_authorizations: Default::default(),
            pending_routed_packets: Default::default(),
            pending_peer_packets: Default::default(),
            dns_resource_nat: Default::default(),
            resource_list: Default::default(),
            unix_ts_clock: UnixTsClock::new(now, unix_ts),
            dns_lookup_duration: otel_instruments::dns_lookup_duration(),
        }
    }

    pub fn tunnel_ip_config(&self) -> Option<crate::IpConfig> {
        Some(self.tun_config.current()?.ip)
    }

    pub fn tunnel_ip_for(&self, dst: IpAddr) -> Option<IpAddr> {
        Some(match dst {
            IpAddr::V4(_) => self.tunnel_ip_config()?.v4.into(),
            IpAddr::V6(_) => self.tunnel_ip_config()?.v6.into(),
        })
    }

    pub(crate) fn resources(&self) -> Vec<ResourceView> {
        self.resources_by_id
            .values()
            .cloned()
            .filter_map(|r| {
                let status = self.resource_status(&r);
                r.with_status(status)
            })
            .sorted()
            .collect_vec()
    }

    /// Builds the list of currently-connected device peers. The name and tunnel
    /// IPs are taken from the live connection state; the pools we reach the device
    /// through, or it reaches us through, label it.
    pub(crate) fn connected_devices(&self) -> Vec<ConnectedDeviceView> {
        self.clients
            .iter()
            .filter_map(|peer| {
                let client_id = peer.id();

                if !self
                    .node
                    .is_connected(&ClientOrGatewayId::Client(client_id))
                {
                    return None;
                }

                let tun_ipv4 = peer.tun_ipv4();
                let tun_ipv6 = peer.tun_ipv6();
                let name = peer.remote_name().to_owned();

                let pool_names = self.pool_names_for(peer).sorted().collect_vec();

                if pool_names.is_empty() {
                    return None;
                }

                Some(ConnectedDeviceView {
                    id: client_id,
                    name,
                    tun_ipv4,
                    tun_ipv6,
                    pools: pool_names,
                })
            })
            .collect_vec()
    }

    /// The names of the pools that authorise flows between us and `peer`, either way.
    fn pool_names_for<'a>(&'a self, peer: &'a ClientOnClient) -> impl Iterator<Item = String> + 'a {
        let inbound = peer.inbound_resource_ids().collect::<BTreeSet<_>>();

        self.resources_by_id
            .iter()
            .filter_map(move |(rid, resource)| {
                let Resource::DevicePool(pool) = resource else {
                    return None;
                };

                let outbound = self
                    .outbound_authorizations
                    .client_token(*rid, peer.id())
                    .is_some();

                (outbound || inbound.contains(rid)).then(|| pool.name.clone())
            })
    }

    fn resource_list_snapshot(&self) -> ResourceList {
        ResourceList {
            resources: self.resources(),
            connected_devices: self.connected_devices(),
        }
    }

    fn resource_status(&self, resource: &Resource) -> ResourceStatus {
        // `all()` over an empty site set is vacuously true.
        if resource.sites().is_empty() {
            return ResourceStatus::Unknown;
        }

        if resource.sites().iter().any(|s| {
            self.sites_status
                .get(&s.id)
                .is_some_and(|(s, _)| *s == ResourceStatus::Online)
        }) {
            return ResourceStatus::Online;
        }

        if resource.sites().iter().all(|s| {
            self.sites_status
                .get(&s.id)
                .is_some_and(|(s, _)| *s == ResourceStatus::Offline)
        }) {
            return ResourceStatus::Offline;
        }

        ResourceStatus::Unknown
    }

    pub fn set_resource_offline(&mut self, id: ResourceId, now: Instant) {
        let Some(resource) = self.resources_by_id.get(&id).cloned() else {
            return;
        };

        for Site { id, .. } in resource.sites() {
            self.sites_status
                .insert(*id, (ResourceStatus::Offline, now));
        }

        self.on_resource_connection_failed(id, now);
        self.resource_list.update(self.resource_list_snapshot());
    }

    /// Handles cases where access to a device is denied.
    ///
    /// The portal denied the address we asked about: answer the buffered packets with an
    /// ICMP error so the application fails fast. The next packet asks again.
    pub fn handle_client_device_access_denied(
        &mut self,
        ipv4: Option<Ipv4Addr>,
        ipv6: Option<Ipv6Addr>,
        reason: FailReason,
    ) {
        tracing::debug!(?ipv4, ?ipv6, "Device access denied: {reason:?}");

        let pending = self
            .pending_authorizations
            .remove_device_authorizations(|addr| {
                ipv4.map(IpAddr::V4) == Some(addr) || ipv6.map(IpAddr::V6) == Some(addr)
            })
            .collect_vec();

        for pending in pending {
            let (packets, _) = pending.into_buffers();

            for packet in packets {
                reply_with_icmp_prohibited(&mut self.buffered_packets, packet);
            }
        }
    }

    /// Abandons the pending authorizations and any connection to an offline device.
    pub fn set_device_offline(&mut self, cid: ClientId, now: Instant) {
        if let Some(peer) = self.clients.peer_by_id(&cid) {
            let tun = peer.remote_tun();

            for _ in self
                .pending_authorizations
                .remove_device_authorizations(|addr| tun.is_ip(addr))
            {}
        }

        self.forget_outbound_authorizations(cid);

        if self.clients.remove(&cid).is_some() {
            self.node
                .close_connection(ClientOrGatewayId::Client(cid), p2p_control::goodbye(), now);
        }
    }

    /// Handles the portal's answer to a device name.
    pub fn handle_device_domain_resolved(
        &mut self,
        domain: DomainName,
        result: Result<(Ipv4Addr, Ipv6Addr), FailReason>,
    ) {
        self.device_stub_resolver
            .handle_device_domain_resolved(domain, result);
        self.drain_device_stub_resolver_events();
    }

    pub fn public_key(&self) -> PublicKey {
        self.node.public_key()
    }

    pub fn set_flow_logs_enabled(&mut self, enabled: bool) {
        self.flow_tracker.set_enabled(enabled);
    }

    pub fn shut_down(&mut self, now: Instant) {
        tracing::info!("Initiating graceful shutdown");

        self.flow_tracker.close_all(now);

        self.clients.clear();
        self.gateways.clear();
        self.node.close_all(p2p_control::goodbye(), now);
    }

    /// Updates the NAT for all domains resolved by the stub resolver on the corresponding gateway.
    ///
    /// In order to route traffic for DNS resources, the designated gateway needs to set up NAT from
    /// the IPs assigned by the client's stub resolver and the actual IPs the domains resolve to.
    ///
    /// The corresponding control message containing the domain and IPs is sent over UDP through the tunnel.
    /// UDP is unreliable, even through the WG tunnel, meaning we need our own way of making reliable.
    /// The algorithm for that is simple:
    /// 1. We track the timestamp when we've last sent the setup message.
    /// 2. The message is designed to be idempotent on the gateway.
    /// 3. If we don't receive a response within 2s and this function is called again, we send another message.
    ///
    /// The complexity of this function is O(N) with the number of resolved DNS resources.
    fn update_dns_resource_nat(
        &mut self,
        now: Instant,
        buffered_packets: impl Iterator<Item = IpPacket>,
    ) {
        // Organise all buffered packets by gateway + domain + resource.
        // A single domain can map to multiple resources, hence we need to key by the resource ID as well.
        let mut buffered_packets_by_gateway_domain_and_resource = buffered_packets
            .map(|packet| {
                let proto = packet.destination_protocol();
                let (gateway_id, resource, domain) = self
                    .routing_tables
                    .dns_resources(packet.destination(), proto)
                    .into_iter()
                    .find_map(|(resource, domain)| {
                        let gateway_id =
                            self.outbound_authorizations.gateway_by_resource(resource)?;
                        Some((gateway_id, resource, domain))
                    })
                    .context("IP is not associated with an authorized DNS resource")?;

                anyhow::Ok((gateway_id, resource, domain, packet))
            })
            .filter_map(|res| {
                res.inspect_err(|e| tracing::debug!("Dropping buffered packet: {e}"))
                    .ok()
            })
            .fold(
                BTreeMap::<_, VecDeque<IpPacket>>::new(),
                |mut map, (gid, resource, domain, packet)| {
                    map.entry((gid, domain, resource))
                        .or_default()
                        .push_back(packet);

                    map
                },
            );

        for (domain, rid, proxy_ips, gid) in
            self.resource_stub_resolver
                .resolved_resources()
                .map(|(domain, resource, proxy_ips)| {
                    let gateway = self.outbound_authorizations.gateway_by_resource(*resource);

                    (domain, resource, proxy_ips, gateway)
                })
        {
            let Some(gid) = gid else {
                tracing::trace!(
                    %domain, %rid,
                    "No gateway connected for resource, skipping DNS resource NAT setup"
                );
                continue;
            };

            let packets_for_domain = buffered_packets_by_gateway_domain_and_resource
                .remove(&(gid, domain.clone(), *rid))
                .unwrap_or_default();

            match self.dns_resource_nat.update(
                domain.clone(),
                *gid,
                *rid,
                &proxy_ips,
                packets_for_domain,
                now,
            ) {
                Ok(()) => {}
                Err(e) => {
                    tracing::warn!("Failed to update DNS resource NAT state: {e:#}");
                    continue;
                }
            }

            if let Some(peer) = self.gateways.peer_by_id_mut(gid) {
                for ip in proxy_ips {
                    peer.allow_ip_for_resource(ip, *rid);
                }
            }
        }
    }

    /// Handles an IP packet through the TUN input path.
    ///
    /// Most packets originate from the TUN device, but internally-produced and previously-buffered
    /// packets also re-enter through this path. Sentinel DNS queries may be consumed locally; all
    /// other packets are routed and either sent or buffered here.
    pub fn handle_tun_input(
        &mut self,
        packet: IpPacket,
        now: Instant,
        provider: &mut impl snownet::BufferProvider,
    ) -> Result<()> {
        if packet.is_fz_p2p_control() {
            tracing::warn!("Packet matches heuristics of FZ p2p control protocol");
        }

        if packet.destination().is_multicast() {
            return Ok(());
        }

        let tun_config = self
            .tun_config
            .current()
            .context("TUN device not configured")?;

        anyhow::ensure!(
            tun_config.ip.is_ip(packet.source()),
            UnroutablePacket::not_tunnel_source_ip(&packet)
        );
        anyhow::ensure!(
            !tun_config.ip.is_ip(packet.destination()),
            UnroutablePacket::packet_to_self(&packet)
        );

        // DNS packets to our sentinel resolvers never become flows.
        let packet = match self.try_handle_dns(packet, now) {
            ControlFlow::Break(()) => return Ok(()),
            ControlFlow::Continue(non_dns_packet) => non_dns_packet,
        };

        let internet_resource = self.active_internet_resource().map(|resource| resource.id);
        let _guard = self.flow_tracker.begin_tun_packet(&packet, now);

        // Recursive DNS queries we tunnel to upstream resolvers are internal
        // traffic and never become flows either; dropping the guard before any
        // fact is recorded discards the packet's flow data.
        if self.udp_dns_client.owns_outbound(&packet) || self.tcp_dns_client.owns_outbound(&packet)
        {
            drop(_guard);
        }

        let dst = packet.destination();
        let dst_proto = match packet.destination_protocol() {
            Ok(dst_proto) => dst_proto,
            // An ICMP error has no port or echo identifier of its own and so fails to
            // classify. It belongs to the flow of the packet that failed, and that
            // flow decides where it goes.
            Err(e) => {
                let Some(cid) = client_for_icmp_error(&self.clients, &packet) else {
                    return Err(e.into());
                };

                // The peer opened the flow the error refers to, so we are its responder.
                flow_tracker::record_peer(cid, flow_tracker::Role::Responder);

                encapsulate_or_buffer(
                    packet,
                    cid.into(),
                    now,
                    &mut self.node,
                    provider,
                    &mut self.pending_routed_packets,
                )?;

                return Ok(());
            }
        };
        let direct_gateway = self.gateways.peer_by_ip(dst).map(|(gid, _)| gid);
        let peer_originated_client_flow = self.clients.peer_by_ip(dst).and_then(|(cid, peer)| {
            (peer.outbound_flow_originator(&packet) == Some(Originator::Peer)).then_some(cid)
        });
        let routes = self
            .routing_tables
            .resolve(dst, dst_proto, internet_resource);

        let (packet, peer) = match (direct_gateway, peer_originated_client_flow, routes) {
            (None, None, Err(routing::Denied)) => {
                reply_with_icmp_prohibited(&mut self.buffered_packets, packet);
                return Ok(());
            }
            (None, None, Ok(routes)) if routes.is_empty() => {
                return Err(UnroutablePacket::unknown_resource(&packet).into());
            }
            (Some(gid), _, _) => {
                // A Gateway's TUN IP takes precedence over resource matches.
                flow_tracker::record_peer(gid, flow_tracker::Role::Initiator);

                (packet, gid.into())
            }
            (None, Some(cid), _) => {
                // A reply follows its peer-originated flow even if we have no outbound route to
                // that peer.
                flow_tracker::record_peer(cid, flow_tracker::Role::Responder);

                (packet, cid.into())
            }
            (None, None, Ok(MatchedRoutes::DevicePools(pools))) => {
                let mut authorized = None;
                if let Some((cid, _)) = self.clients.peer_by_ip(dst) {
                    for &resource_id in &pools {
                        let Some(token) =
                            self.outbound_authorizations.client_token(resource_id, cid)
                        else {
                            continue;
                        };

                        authorized = Some((cid, token.clone()));
                        break;
                    }
                }

                let Some((cid, token)) = authorized else {
                    let pools = pools.into_iter().unique().collect_vec();
                    self.pending_authorizations.on_not_authorized(
                        AuthorizationRequest::Device { addr: dst, pools },
                        packet,
                        now,
                    );
                    return Ok(());
                };

                flow_tracker::record_peer(cid, flow_tracker::Role::Initiator);
                flow_tracker::record_ingest_token(Some(token));

                self.clients
                    .peer_by_id_mut(&cid)
                    .with_context(|| UnroutablePacket::no_peer_state(&packet))?
                    .record_outbound_as_originator(&packet, now);

                (packet, cid.into())
            }
            (None, None, Ok(MatchedRoutes::Gateways(routes))) => {
                let mut authorized = None;
                for route in &routes {
                    let Some(authorization) =
                        self.outbound_authorizations.gateway(route.resource_id)
                    else {
                        continue;
                    };

                    authorized = Some((
                        authorization.gateway_id,
                        route.resource_id,
                        route.domain.clone(),
                        authorization.ingest_token.clone(),
                    ));
                    break;
                }

                let Some((gid, resource_id, domain, token)) = authorized else {
                    let resource_ids = routes
                        .into_iter()
                        .map(|route| route.resource_id)
                        .unique()
                        .collect_vec();
                    self.pending_authorizations.on_not_authorized(
                        AuthorizationRequest::Resources(resource_ids),
                        packet,
                        now,
                    );
                    return Ok(());
                };

                flow_tracker::record_peer(gid, flow_tracker::Role::Initiator);
                flow_tracker::record_ingest_token(Some(token));

                let packet = if let Some(domain) = domain {
                    flow_tracker::record_domain(domain.clone());

                    let Some(packet) = self.dns_resource_nat.handle_outgoing(
                        gid,
                        &domain,
                        resource_id,
                        packet,
                        now,
                    ) else {
                        return Ok(());
                    };

                    packet
                } else {
                    packet
                };

                (packet, gid.into())
            }
        };

        encapsulate_or_buffer(
            packet,
            peer,
            now,
            &mut self.node,
            provider,
            &mut self.pending_routed_packets,
        )?;

        Ok(())
    }

    /// Feed an internally-produced or previously-buffered IP packet through normal TUN routing
    /// and flow tracking, queueing any resulting network transmit.
    fn handle_out_of_band_ip_packet(&mut self, packet: IpPacket, now: Instant) -> Result<()> {
        let mut buffered_transmits = std::mem::take(&mut self.buffered_transmits);
        let result = self.handle_tun_input(packet, now, &mut buffered_transmits);
        self.buffered_transmits = buffered_transmits;

        result?;

        Ok(())
    }

    /// Handles UDP packets received on the network interface.
    ///
    /// Most of these packets will be WireGuard encrypted IP packets and will thus yield an [`IpPacket`].
    /// Some of them will however be handled internally, for example, TURN control packets exchanged with relays.
    ///
    /// In case this function returns `None`, you should call [`ClientState::handle_timeout`] next to fully advance the internal state.
    pub fn handle_network_input(
        &mut self,
        local: SocketAddr,
        from: SocketAddr,
        packet: &[u8],
        now: Instant,
    ) -> Result<Option<IpPacket>> {
        let _guard = self.flow_tracker.begin_network_packet(local, from, now);

        let Some((pid, packet)) = self
            .node
            .decapsulate(local, from, packet.as_ref(), now)
            .with_context(|| FailedToDecapsulate(packet_kind::classify(packet)))?
        else {
            return Ok(None);
        };

        flow_tracker::record_decrypted_packet(&packet);

        if matches!(pid, ClientOrGatewayId::Gateway(_)) && self.udp_dns_client.accepts(&packet) {
            self.udp_dns_client.handle_inbound(packet);
            return Ok(None);
        }

        if matches!(pid, ClientOrGatewayId::Gateway(_)) && self.tcp_dns_client.accepts(&packet) {
            self.tcp_dns_client.handle_inbound(packet);
            return Ok(None);
        }

        if let Some(fz_p2p_control) = packet.as_fz_p2p_control() {
            // Control traffic is not a flow; release the tracker borrow for
            // the `&mut self` calls below.
            drop(_guard);

            match (fz_p2p_control.event_type(), pid) {
                (p2p_control::DOMAIN_STATUS_EVENT, ClientOrGatewayId::Gateway(gid)) => {
                    let res = p2p_control::dns_resource_nat::decode_domain_status(fz_p2p_control)
                        .context("Failed to decode `DomainStatus`")?;

                    let buffered_packets = self
                        .dns_resource_nat
                        .on_domain_status(gid, res)
                        .into_iter()
                        .collect::<Vec<_>>();

                    for packet in buffered_packets {
                        if let Err(e) = self.handle_out_of_band_ip_packet(packet, now) {
                            tracing::debug!(%gid, "Failed to route buffered DNS resource packet: {e:#}");
                        }
                    }
                }
                (p2p_control::GOODBYE_EVENT, pid) => {
                    self.node.remove_connection(pid, "received `goodbye`", now);

                    match pid {
                        ClientOrGatewayId::Client(cid) => self.cleanup_connected_client(&cid),
                        ClientOrGatewayId::Gateway(gid) => {
                            self.cleanup_connected_gateway(&gid, now)
                        }
                    }
                }
                (code, pid) => {
                    tracing::debug!(code = %code.into_u8(), %pid, "Unknown / unsupported control protocol");
                }
            };

            return Ok(None);
        }

        match pid {
            ClientOrGatewayId::Client(cid) => {
                let Some(peer) = self.clients.peer_by_id_mut(&cid) else {
                    tracing::error!(%cid, "Couldn't find connection by ID");

                    return Ok(None);
                };

                let packet = match peer.ensure_allowed_inbound(packet, now)? {
                    InboundResult::Send(p) => p,
                    InboundResult::Filtered(reply) => {
                        encapsulate_and_queue(
                            reply,
                            ClientOrGatewayId::Client(cid),
                            now,
                            &mut self.node,
                            &mut self.buffered_transmits,
                            &mut self.pending_peer_packets,
                        );
                        return Ok(None);
                    }
                };

                return Ok(Some(packet));
            }
            ClientOrGatewayId::Gateway(gid) => {
                let Some(peer) = self.gateways.peer_by_id_mut(&gid) else {
                    tracing::error!(%gid, "Couldn't find connection by ID");

                    return Ok(None);
                };

                peer.ensure_allowed_src(&packet)?;

                // To a gateway we are always the one who opened the flow;
                // this packet is a reply.
                flow_tracker::record_peer(gid, flow_tracker::Role::Initiator);

                // All facts are recorded; commit the flow so the tracker
                // borrow is free for the `&mut self` calls below.
                drop(_guard);

                #[cfg(feature = "telemetry")]
                if telemetry::feature_flags::icmp_error_unreachable_prohibited_create_new_flow()
                    && let Ok(Some((failed_packet, error))) = packet.icmp_error()
                    && error.is_unreachable_prohibited()
                    && let internet_resource = self.active_internet_resource().map(|r| r.id)
                    && let Ok(routes) = self.routing_tables.resolve_resource(
                        failed_packet.dst(),
                        failed_packet.dst_proto(),
                        internet_resource,
                    )
                    && let resources = routes
                        .iter()
                        .map(|route| route.resource_id)
                        .unique()
                        .collect_vec()
                    && !resources.is_empty()
                {
                    telemetry::analytics::feature_flag_called(
                        "icmp-error-unreachable-prohibited-create-new-flow",
                    );

                    self.pending_authorizations.on_not_authorized(
                        AuthorizationRequest::Resources(resources),
                        pending_authorizations::Trigger::IcmpDestinationUnreachableProhibited,
                        now,
                    );
                }
            }
        }

        Ok(Some(packet))
    }

    pub fn handle_dns_response(&mut self, response: dns::RecursiveResponse, now: Instant) {
        let mut attributes = vec![
            match response.recursion {
                dns::Recursion::Local => otel::attr::dns_recursion_local(),
                dns::Recursion::Tunnel => otel::attr::dns_recursion_tunnel(),
            },
            otel::attr::dns_question_type(response.query.qtype()),
            otel::attr::network_transport(response.transport),
        ];
        match &response.message {
            Ok(message) => attributes.push(otel::attr::dns_response_code(message.response_code())),
            Err(e) => attributes.extend(otel_attributes::error_layers(e)),
        }
        self.dns_lookup_duration.record(
            now.saturating_duration_since(response.started_at)
                .as_secs_f64(),
            &attributes,
        );

        let qid = response.query.id();
        let server = response.server;
        let domain = response.query.domain();

        let _span = tracing::debug_span!("handle_dns_response", %qid, %server, local = %response.local, %domain).entered();

        let message = match response.message {
            Ok(response) => {
                tracing::trace!("Received recursive DNS response");

                if response.truncated() {
                    tracing::debug!("Upstream DNS server had to truncate response");
                }

                response
            }
            Err(e)
                if response.transport == dns::Transport::Udp
                    && e.any_downcast_ref::<io::Error>()
                        .is_some_and(|e| e.kind() == io::ErrorKind::TimedOut) =>
            {
                tracing::debug!("Recursive UDP DNS query timed out");

                return; // Our UDP DNS query timeout is likely longer than the one from the OS, so don't bother sending a response.
            }
            Err(e) => {
                tracing::debug!("Recursive DNS query failed: {e:#}");

                dns_types::Response::servfail(&response.query)
            }
        };

        // Ensure the response we are sending back has the original query ID.
        // Recursive DoH queries set the ID to 0.
        let message = message.with_id(qid);

        self.dns_cache.insert(domain, &message, now);
        self.send_dns_response(response.local, response.remote, response.transport, message);
    }

    fn send_dns_response(
        &mut self,
        local: SocketAddr,
        remote: SocketAddr,
        transport: dns::Transport,
        response: dns_types::Response,
    ) {
        match transport {
            dns::Transport::Udp => {
                self.buffered_packets
                    .extend(into_udp_dns_packet(local, remote, response));
            }
            dns::Transport::Tcp => {
                unwrap_or_warn!(
                    self.tcp_dns_server.send_message(local, remote, response),
                    "Failed to send TCP DNS response: {}"
                );
            }
        }
    }

    /// Flush all packets buffered for `pid` now that its connection is established.
    fn flush_pending_packets(&mut self, pid: ClientOrGatewayId, now: Instant) {
        let routed_packets = self.pending_routed_packets.remove(&pid);
        let peer_packets = self.pending_peer_packets.remove(&pid);

        let num_routed_packets = routed_packets.as_ref().map_or(0, UniquePacketBuffer::len);
        let num_peer_packets = peer_packets.as_ref().map_or(0, UniquePacketBuffer::len);

        if num_routed_packets + num_peer_packets == 0 {
            return;
        }

        tracing::debug!(%pid, %num_routed_packets, %num_peer_packets, "Flushing buffered packets");

        for packet in routed_packets.into_iter().flatten() {
            if let Err(e) = self.handle_out_of_band_ip_packet(packet, now) {
                tracing::debug!(%pid, "Failed to route buffered packet: {e:#}");
            }
        }

        let node = &mut self.node;
        let buffered_transmits = &mut self.buffered_transmits;
        let pending_packets = &mut self.pending_peer_packets;

        for packet in peer_packets.into_iter().flatten() {
            encapsulate_and_queue(packet, pid, now, node, buffered_transmits, pending_packets);
        }
    }

    pub fn add_ice_candidate(
        &mut self,
        conn_id: impl Into<ClientOrGatewayId>,
        ice_candidate: IceCandidate,
        now: Instant,
    ) {
        self.node
            .add_remote_candidate(conn_id.into(), ice_candidate.into(), now);
    }

    pub fn remove_ice_candidate(
        &mut self,
        conn_id: impl Into<ClientOrGatewayId>,
        ice_candidate: IceCandidate,
        now: Instant,
    ) {
        self.node
            .remove_remote_candidate(conn_id.into(), ice_candidate.into(), now);
    }

    #[tracing::instrument(level = "debug", skip_all, fields(%rid))]
    pub fn handle_resource_access_authorized(
        &mut self,
        rid: ResourceId,
        gid: GatewayId,
        gateway_key: PublicKey,
        gateway_tun: IpConfig,
        site_id: SiteId,
        preshared_key: SecretKey,
        client_ice: IceCredentials,
        gateway_ice: IceCredentials,
        use_iceless: bool,
        flow_logs_ingest_token: IngestToken,
        now: Instant,
    ) -> anyhow::Result<Result<(), NoTurnServers>> {
        tracing::debug!(%gid, "New resource access authorized");

        let resource = self.resources_by_id.get(&rid).context("Unknown resource")?;
        anyhow::ensure!(
            !matches!(resource, Resource::DevicePool(_)),
            "Device pool cannot be authorized through a gateway"
        );

        let pending_authorizations = self
            .pending_authorizations
            .remove_resource_authorizations(rid);
        if pending_authorizations.is_empty() {
            tracing::debug!("No pending authorization");

            return Ok(Ok(()));
        }

        match self.node.upsert_connection(
            ClientOrGatewayId::Gateway(gid),
            gateway_key,
            x25519::StaticSecret::from(preshared_key.expose_secret().0),
            client_ice.into(),
            gateway_ice.into(),
            snownet::IceRole::Controlling,
            snownet::IceConfig::client_default(),
            snownet::IceConfig::client_idle(),
            use_iceless,
            now,
        ) {
            Ok(()) => {}
            Err(e) => return Ok(Err(e)),
        };
        self.outbound_authorizations
            .authorize_gateway(rid, gid, flow_logs_ingest_token);
        self.gateways_by_site
            .entry(site_id)
            .or_default()
            .insert(gid);

        let peer = self
            .gateways
            .upsert(gid, || GatewayOnClient::new(gateway_tun));

        // Deal with buffered packets

        let (packet_buffers, query_buffers) = pending_authorizations
            .into_iter()
            .map(|pending| pending.into_buffers())
            .unzip::<_, _, Vec<_>, Vec<_>>();
        let buffered_resource_packets = packet_buffers.into_iter().flatten();
        let dns_queries = query_buffers.into_iter().flatten().collect_vec();

        // If we are making this connection because we want to send a DNS query to the Gateway,
        // mark it as "used" through the DNS resource ID.
        if !dns_queries.is_empty() {
            peer.allow_ip_for_resource(gateway_tun.v4, rid);
            peer.allow_ip_for_resource(gateway_tun.v6, rid);
        }

        // 1. Buffered packets for resources
        match resource {
            Resource::Cidr(_) => {
                for address in resource.addresses() {
                    peer.allow_ip_for_resource(address, rid);
                }

                for packet in buffered_resource_packets {
                    if let Err(e) = self.handle_out_of_band_ip_packet(packet, now) {
                        tracing::debug!(%rid, %gid, "Failed to route buffered resource packet: {e:#}");
                    }
                }
            }
            Resource::Internet(_) => {
                for address in resource.addresses() {
                    peer.allow_ip_for_resource(address, rid);
                }

                for packet in buffered_resource_packets {
                    if let Err(e) = self.handle_out_of_band_ip_packet(packet, now) {
                        tracing::debug!(%rid, %gid, "Failed to route buffered resource packet: {e:#}");
                    }
                }
            }
            Resource::Dns(_) => self.update_dns_resource_nat(now, buffered_resource_packets),
            Resource::DevicePool(_) => {}
        }

        // 2. Buffered UDP DNS queries for the Gateway
        for query in dns_queries {
            let gateway = self.gateways.peer_by_id(&gid).context("Unknown peer")?; // If this error happens we have a bug: We just inserted it above.

            let upstream = gateway.tun_dns_server_endpoint(query.local.ip());

            self.forward_dns_query_to_new_upstream_via_tunnel(
                query.local,
                query.remote,
                upstream,
                query.message,
                query.transport,
                now,
            );
        }

        Ok(Ok(()))
    }

    pub fn handle_client_device_access_authorized(
        &mut self,
        cid: ClientId,
        client_key: PublicKey,
        client_tun: IpConfig,
        preshared_key: SecretKey,
        local_client_ice: IceCredentials,
        remote_client_ice: IceCredentials,
        ice_role: IceRole,
        use_iceless: bool,
        client_name: String,
        resource_id: Option<ResourceId>,
        authorization: Option<crate::messages::client::ResourceAuthorization>,
        flow_logs_ingest_token: IngestToken,
        now: Instant,
    ) -> Result<(), NoTurnServers> {
        tracing::debug!(%cid, "New device access authorized");

        let Some(local_tun) = self.tun_config.current().map(|c| c.ip) else {
            tracing::debug!("Ignoring device access authorization: no TUN configuration");

            return Ok(());
        };

        // A peer connecting to us anew may have reset since we were authorized to access it,
        // taking our inbound authorization with it, so our next flow asks the portal again.
        if authorization.is_some() {
            self.forget_outbound_authorizations(cid);
        }

        self.node.upsert_connection(
            ClientOrGatewayId::Client(cid),
            client_key,
            x25519::StaticSecret::from(preshared_key.expose_secret().0),
            local_client_ice.into(),
            remote_client_ice.into(),
            ice_role.into(),
            snownet::IceConfig::client_default(),
            snownet::IceConfig::client_default(),
            use_iceless,
            now,
        )?;

        let authorization = authorization.map(|auth| {
            let expires_at = auth
                .expires_at
                .map(|d| self.unix_ts_clock.instant_at(d, now));
            (auth.resource_id, auth.filters, expires_at)
        });

        let peer = self.clients.upsert(cid, || {
            ClientOnClient::new(cid, local_tun, client_tun, client_name.clone())
        });

        if peer.remote_name() != client_name {
            tracing::debug!(%cid, name = %client_name, "Updated client peer name");
            peer.set_remote_name(client_name);
        }

        // We only add the inbound resource and filters on the *target* side of the connection.
        // The initiating side does not request connections if the filters don't allow it.
        if let Some((resource_id, filters, expires_at)) = authorization {
            peer.add_resource(
                resource_id,
                filters,
                expires_at,
                flow_logs_ingest_token.clone(),
                now,
            );
        }

        let mut buffered_packets = Vec::new();

        for pending in self
            .pending_authorizations
            .remove_device_authorizations(|addr| client_tun.is_ip(addr))
        {
            let (packets, _) = pending.into_buffers();
            buffered_packets.extend(packets);
        }

        // We asked for this connection: from now on the pool the portal picked routes
        // flows to the peer, so later sends skip `pending_authorizations`.
        if let Some(resource_id) = resource_id {
            self.authorize_peer_through_pool(cid, resource_id, flow_logs_ingest_token);
        }

        for packet in buffered_packets {
            if let Err(e) = self.handle_out_of_band_ip_packet(packet, now) {
                tracing::debug!(%cid, "Failed to route buffered packet: {e:#}");
            }
        }

        Ok(())
    }

    fn authorize_peer_through_pool(
        &mut self,
        cid: ClientId,
        resource_id: ResourceId,
        ingest_token: IngestToken,
    ) {
        let Some(Resource::DevicePool(_)) = self.resources_by_id.get(&resource_id) else {
            tracing::debug!(%resource_id, "Portal authorised access through a pool we do not hold");
            return;
        };
        self.outbound_authorizations
            .authorize_client(resource_id, cid, ingest_token);
    }

    /// Update the inbound filter for any peer whose authorization references
    /// `resource_id`.
    pub fn handle_resource_filters_updated(
        &mut self,
        resource_id: ResourceId,
        filters: Vec<Filter>,
    ) {
        for peer in self.clients.iter_mut() {
            peer.update_resource(resource_id, filters.clone());
        }
    }

    /// Drop a previously-active authorization for the given peer, either way.
    pub fn handle_reject_client_device_access(&mut self, cid: ClientId, resource_id: ResourceId) {
        self.outbound_authorizations.remove_client(resource_id, cid);

        let Some(peer) = self.clients.peer_by_id_mut(&cid) else {
            return;
        };
        peer.remove_resource(&resource_id);
    }

    /// Resyncs inbound client-to-client authorizations from the portal's `init`.
    pub fn retain_authorizations(
        &mut self,
        authorizations: BTreeMap<ClientId, BTreeSet<ResourceId>>,
    ) {
        let no_authorizations = BTreeSet::new();

        for peer in self.clients.iter_mut() {
            let retain = authorizations.get(&peer.id()).unwrap_or(&no_authorizations);
            peer.retain_authorizations(retain);
        }
    }

    /// Updates the expiry of an existing inbound authorization from `init`.
    pub fn update_access_authorization_expiry(
        &mut self,
        cid: ClientId,
        resource_id: ResourceId,
        expires_at: Duration,
        now: Instant,
    ) {
        let Some(peer) = self.clients.peer_by_id_mut(&cid) else {
            return;
        };

        let new_expiry = self.unix_ts_clock.instant_at(expires_at, now);
        peer.update_resource_expiry(resource_id, new_expiry, now);
    }

    /// For DNS queries to IPs that are a CIDR resources we want to mangle and forward to the gateway that handles that resource.
    ///
    /// We only want to do this if the upstream DNS server is set by the portal, otherwise, the server might be a local IP.
    fn should_forward_dns_query_to_gateway(
        &mut self,
        dns_server: &dns::Upstream,
    ) -> Option<SocketAddr> {
        if !self.dns_config.has_custom_upstream() {
            return None;
        }

        let server = match dns_server {
            dns::Upstream::Do53 { server } => server,
            dns::Upstream::DoH { .. } => return None, // If DoH upstreams are in effect, we never forward queries to upstreams.
        };

        if self.active_internet_resource().is_some() {
            return Some(*server);
        }

        let allows_udp_port = self
            .routing_tables
            .has_cidr_route(server.ip(), Protocol::Udp(server.port()));
        let allows_tcp_port = self
            .routing_tables
            .has_cidr_route(server.ip(), Protocol::Tcp(server.port()));

        (allows_udp_port && allows_tcp_port).then_some(*server)
    }

    /// Handles UDP & TCP packets targeted at our stub resolver.
    fn try_handle_dns(&mut self, packet: IpPacket, now: Instant) -> ControlFlow<(), IpPacket> {
        let dst = packet.destination();

        if is_llmnr(dst) {
            self.handle_llmnr_dns_query(packet, now);
            return ControlFlow::Break(());
        }

        let Some(upstream) = self.dns_config.mapping().upstream_by_sentinel(dst) else {
            if is_dns_sentinel(dst) {
                return ControlFlow::Break(());
            }

            return ControlFlow::Continue(packet);
        };

        if self.tcp_dns_server.accepts(&packet) {
            self.tcp_dns_server.handle_inbound(packet);
            return ControlFlow::Break(());
        }

        self.handle_udp_dns_query(upstream, packet, now);

        ControlFlow::Break(())
    }

    pub fn on_resource_connection_failed(&mut self, resource: ResourceId, now: Instant) {
        self.pending_authorizations
            .remove_resource_authorizations(resource);

        // A pool's authorizations must survive a single member's failure.
        let Some(disconnected_gateway) = self.gateway_by_resource(&resource) else {
            return;
        };

        self.outbound_authorizations.remove_resource(resource);
        self.cleanup_connected_gateway(&disconnected_gateway, now);
    }

    fn preferred_gateways(&self, resource: ResourceId) -> Vec<GatewayId> {
        #[expect(clippy::disallowed_methods, reason = "We are sorting anyway")]
        self.gateways_by_site
            .values()
            .flatten()
            .copied()
            .unique()
            .sorted_by(|left, right| {
                let prefer_authorized = match self.gateway_by_resource(&resource) {
                    Some(g) if g == *left => Ordering::Less,
                    Some(g) if g == *right => Ordering::Greater,
                    Some(_) => Ordering::Equal,
                    None => Ordering::Equal,
                };
                let prefer_connected = match (
                    self.gateways.peer_by_id(left),
                    self.gateways.peer_by_id(right),
                ) {
                    (None, None) => Ordering::Equal,
                    (Some(_), Some(_)) => Ordering::Equal,
                    (None, Some(_)) => Ordering::Greater,
                    (Some(_), None) => Ordering::Less,
                };

                let default_ordering = left.cmp(right);

                prefer_authorized
                    .then(prefer_connected)
                    .then(default_ordering) // This makes it deterministic, even though we are using `HashSets
            })
            .collect()
    }

    pub fn gateway_by_resource(&self, resource: &ResourceId) -> Option<GatewayId> {
        let gid = self
            .outbound_authorizations
            .gateway_by_resource(*resource)?;

        Some(*gid)
    }

    fn initialise_tcp_dns_client(&mut self) {
        let Some(tun_config) = self.tun_config.current() else {
            return;
        };

        self.udp_dns_client
            .set_source_interface(tun_config.ip.v4, tun_config.ip.v6);
        self.tcp_dns_client
            .set_source_interface(tun_config.ip.v4, tun_config.ip.v6);
        self.tcp_dns_client.reset();
    }

    fn initialise_tcp_dns_server(&mut self) {
        let sentinel_sockets = self
            .dns_config
            .mapping()
            .sentinel_ips()
            .into_iter()
            .map(|ip| SocketAddr::new(ip, DNS_PORT))
            .collect();

        self.tcp_dns_server
            .set_listen_addresses::<NUM_CONCURRENT_TCP_DNS_CLIENTS>(sentinel_sockets);
    }

    /// Sets the Internet Resource state.
    ///
    /// In order for the Internet Resource to actually be active, the user must also have access to it.
    /// In other words, it needs to be present in the resources list provided by the portal.
    ///
    /// That list may be provided asynchronously to this call, which is why set it as active,
    /// regardless as to whether it is present or not.
    pub fn set_internet_resource_state(&mut self, active: bool, now: Instant) {
        // Be idempotent.
        if self.is_internet_resource_active == active {
            return;
        }

        let previous = std::mem::replace(&mut self.is_internet_resource_active, active);

        let resource = internet_resource(&self.resources_by_id);

        // If we are enabling a known Internet Resource, log it.
        if active && let Some(resource) = resource.cloned() {
            self.log_activating_resource(&Resource::Internet(resource));
        }

        // Check if we need to disable the current one.
        if previous && let Some(current) = resource {
            self.disable_resource(current.id, now);
        }

        self.maybe_update_tun_routes();
    }

    #[tracing::instrument(level = "debug", skip_all, fields(gateway = %disconnected_gateway))]
    fn cleanup_connected_gateway(&mut self, disconnected_gateway: &GatewayId, now: Instant) {
        self.pending_routed_packets
            .remove(&ClientOrGatewayId::Gateway(*disconnected_gateway));
        self.pending_peer_packets
            .remove(&ClientOrGatewayId::Gateway(*disconnected_gateway));
        self.portal
            .forget(&ClientOrGatewayId::Gateway(*disconnected_gateway));
        self.update_site_status_by_gateway(disconnected_gateway, ResourceStatus::Unknown, now);
        self.gateways.remove(disconnected_gateway);
        self.outbound_authorizations
            .forget_gateway(*disconnected_gateway);
        self.dns_resource_nat.clear_by_gateway(disconnected_gateway);
    }

    #[tracing::instrument(level = "debug", skip_all, fields(client = %disconnected_client))]
    fn cleanup_connected_client(&mut self, disconnected_client: &ClientId) {
        self.pending_routed_packets
            .remove(&ClientOrGatewayId::Client(*disconnected_client));
        self.pending_peer_packets
            .remove(&ClientOrGatewayId::Client(*disconnected_client));
        self.portal
            .forget(&ClientOrGatewayId::Client(*disconnected_client));
        self.forget_outbound_authorizations(*disconnected_client);

        if self.clients.remove(disconnected_client).is_some() {
            self.resource_list.update(self.resource_list_snapshot());
        }
    }

    /// Drops outbound authorizations towards `cid`, so the next flow asks again.
    fn forget_outbound_authorizations(&mut self, cid: ClientId) {
        self.outbound_authorizations.forget_client(cid);
    }

    fn routes(&self) -> impl Iterator<Item = IpNetwork> + '_ {
        iter::empty()
            .chain(self.routing_tables.cidr_networks())
            .chain(iter::once(IPV4_TUNNEL.into()))
            .chain(iter::once(IPV6_TUNNEL.into()))
            .chain(iter::once(IPV4_RESOURCES.into()))
            .chain(iter::once(IPV6_RESOURCES.into()))
            .chain(iter::once(DNS_SENTINELS_V4.into()))
            .chain(iter::once(DNS_SENTINELS_V6.into()))
            .chain(
                self.active_internet_resource()
                    .map(|_| Ipv4Network::DEFAULT_ROUTE.into()),
            )
            .chain(
                self.active_internet_resource()
                    .map(|_| Ipv6Network::DEFAULT_ROUTE.into()),
            )
    }

    fn active_internet_resource(&self) -> Option<&InternetResource> {
        if !self.is_internet_resource_active {
            return None;
        }

        internet_resource(&self.resources_by_id)
    }

    /// Update our list of known system DNS resolvers.
    ///
    /// Returns back the list of resolvers, sanitized from all unusable servers,
    /// i.e. all servers within the sentinel DNS range.
    ///
    /// Note: The returned list is not necessarily the list of DNS resolvers that is active.
    /// If DNS servers are defined in the portal, those will be preferred over the system defined ones.
    pub fn update_system_resolvers(&mut self, new_dns: Vec<IpAddr>) -> Vec<IpAddr> {
        let changed = self.dns_config.update_system_resolvers(new_dns);

        if !changed {
            return self.dns_config.system_dns_resolvers();
        }

        self.dns_cache.flush("DNS servers changed");

        let Some(config) = self.tun_config.current() else {
            tracing::debug!("Unable to update DNS servers without interface configuration");
            return self.dns_config.system_dns_resolvers();
        };

        let dns_by_sentinel = self.dns_config.mapping();

        self.maybe_update_tun_config(TunConfig {
            dns_by_sentinel,
            ..config.clone()
        });

        self.dns_config.system_dns_resolvers()
    }

    pub fn update_interface_config(&mut self, config: InterfaceConfig) {
        tracing::trace!(upstream_do53 = ?config.upstream_do53(), upstream_doh = ?config.upstream_doh(), search_domain = ?config.search_domain, ipv4 = %config.ipv4, ipv6 = %config.ipv6, "Received interface configuration from portal");

        let changed_do53 = self
            .dns_config
            .update_upstream_do53_resolvers(config.upstream_do53());
        let changed_doh = self
            .dns_config
            .update_upstream_doh_resolvers(config.upstream_doh());

        if changed_do53 || changed_doh {
            self.dns_cache.flush("DNS servers changed");
        }

        // Create a new `TunConfig` by patching the corresponding fields of the existing one.
        let new_tun_config = self
            .tun_config
            .current()
            .map(|existing| TunConfig {
                ip: IpConfig {
                    v4: config.ipv4,
                    v6: config.ipv6,
                },
                dns_by_sentinel: self.dns_config.mapping(),
                search_domain: config.search_domain.clone(),
                routes: existing.routes.clone(),
            })
            .unwrap_or_else(|| TunConfig {
                ip: IpConfig {
                    v4: config.ipv4,
                    v6: config.ipv6,
                },
                dns_by_sentinel: self.dns_config.mapping(),
                search_domain: config.search_domain.clone(),
                routes: BTreeSet::from_iter(self.routes()),
            });

        // Apply the new `TunConfig` if it differs from the existing one.
        self.maybe_update_tun_config(new_tun_config);
    }

    pub fn poll_packets(&mut self) -> Option<IpPacket> {
        self.buffered_packets
            .pop_front()
            .or_else(|| self.tcp_dns_server.poll_outbound())
    }

    pub fn poll_timeout(&mut self) -> Option<(Instant, &'static str)> {
        iter::empty()
            .chain(
                self.udp_dns_client
                    .poll_timeout()
                    .map(|instant| (instant, "UDP DNS client")),
            )
            .chain(
                self.dns_cache
                    .poll_timeout()
                    .map(|instant| (instant, "DNS cache")),
            )
            .chain(
                self.tcp_dns_client
                    .poll_timeout()
                    .map(|instant| (instant, "TCP DNS client")),
            )
            .chain(
                self.tcp_dns_server
                    .poll_timeout()
                    .map(|instant| (instant, "TCP DNS server")),
            )
            .chain(
                self.device_stub_resolver
                    .poll_timeout()
                    .map(|instant| (instant, "Device stub resolver")),
            )
            .chain(
                self.clients
                    .iter_mut()
                    .filter_map(|peer| peer.poll_timeout())
                    .min()
                    .map(|instant| (instant, "Client peer authorization expiry")),
            )
            .chain(
                self.sites_status
                    .values()
                    .filter_map(|(status, set_at)| match status {
                        ResourceStatus::Offline => Some(*set_at + OFFLINE_SITE_STATUS_TIMEOUT),
                        ResourceStatus::Unknown | ResourceStatus::Online => None,
                    })
                    .min()
                    .map(|instant| (instant, "Offline site status expiry")),
            )
            .chain(self.node.poll_timeout())
            .min_by_key(|(instant, _)| *instant)
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.node.handle_timeout(now);
        self.flow_tracker.handle_timeout(now);
        self.dns_cache.handle_timeout(now);
        self.device_stub_resolver.handle_timeout(now);

        for peer in self.clients.iter_mut() {
            peer.handle_timeout(now);
        }

        self.drain_node_events(now);
        self.drain_resource_stub_resolver_events();
        self.drain_device_stub_resolver_events();

        self.advance_dns_clients_and_servers(now);
        self.send_dns_resource_nat_packets(now);
        self.reset_offline_site_status(now);
        self.discard_stale_dns_streams(now);
    }

    /// Advance the DNS server and client state machines.
    ///
    /// Receiving something on a UDP/TCP server socket may trigger packets to be sent on the UDP/TCP client socket and vice versa.
    /// Therefore, we loop here until non of the `poll-X` functions return anything anymore.
    fn advance_dns_clients_and_servers(&mut self, now: Instant) {
        loop {
            self.tcp_dns_server.handle_timeout(now);
            self.tcp_dns_client.handle_timeout(now);
            self.udp_dns_client.handle_timeout(now);

            // Check if have any pending TCP DNS queries.
            if let Some(query) = self.tcp_dns_server.poll_queries() {
                let Some(upstream) = self
                    .dns_config
                    .mapping()
                    .upstream_by_sentinel(query.local.ip())
                else {
                    // This is highly-unlikely but might be possible if our DNS mapping changes whilst the TCP DNS server is processing a request.
                    continue;
                };

                if let Some(response) = self.handle_dns_query(
                    query.message,
                    query.local,
                    query.remote,
                    upstream,
                    dns::Transport::Tcp,
                    now,
                ) {
                    unwrap_or_debug!(
                        self.tcp_dns_server
                            .send_message(query.local, query.remote, response),
                        "Failed to send TCP DNS response: {}"
                    );
                }
                continue;
            }

            // Check if the clients wants to emit any packets.
            if let Some(packet) = self
                .tcp_dns_client
                .poll_outbound()
                .or_else(|| self.udp_dns_client.poll_outbound())
            {
                // All packets from the DNS clients _should_ go through the tunnel.
                if let Err(e) = self.handle_out_of_band_ip_packet(packet, now) {
                    tracing::debug!("{e:#}");
                }
                continue;
            }

            // Check if the UDP DNS client has assembled a response to a query.
            if let Some(query_result) = self.udp_dns_client.poll_query_result() {
                let server = query_result.server;
                let qid = query_result.query.id();

                let Some((local, remote, started_at)) = self
                    .dns_streams_by_upstream_query
                    .remove(&UpstreamQuery::Udp(query_result.token))
                else {
                    tracing::debug!(%server, %qid, "Failed to find UDP socket handle for query result");

                    continue;
                };

                self.handle_dns_response(
                    dns::RecursiveResponse {
                        server: dns::Upstream::Do53 { server },
                        local,
                        remote,
                        query: query_result.query,
                        message: query_result.result,
                        transport: dns::Transport::Udp,
                        started_at,
                        recursion: dns::Recursion::Tunnel,
                    },
                    now,
                );
                continue;
            }

            // Check if the TCP DNS client has assembled a response to a query.
            if let Some(query_result) = self.tcp_dns_client.poll_query_result() {
                let server = query_result.server;
                let qid = query_result.query.id();

                let Some((local, remote, started_at)) = self
                    .dns_streams_by_upstream_query
                    .remove(&UpstreamQuery::Tcp(query_result.token))
                else {
                    tracing::debug!(%server, %qid, "Failed to find TCP socket handle for query result");

                    continue;
                };

                self.handle_dns_response(
                    dns::RecursiveResponse {
                        server: dns::Upstream::Do53 { server },
                        local,
                        remote,
                        query: query_result.query,
                        message: query_result.result,
                        transport: dns::Transport::Tcp,
                        started_at,
                        recursion: dns::Recursion::Tunnel,
                    },
                    now,
                );
                continue;
            }

            break;
        }
    }

    fn discard_stale_dns_streams(&mut self, now: Instant) {
        for (query, (local, remote, _)) in
            self.dns_streams_by_upstream_query
                .extract_if(|_, (_, _, started_at)| {
                    now.saturating_duration_since(*started_at) >= DNS_STREAM_TIMEOUT
                })
        {
            tracing::debug!(?query, %local, %remote, "Discarding stale DNS stream");
        }
    }

    fn send_dns_resource_nat_packets(&mut self, now: Instant) {
        while let Some((gid, domain, rid, packet)) = self.dns_resource_nat.poll_packet() {
            tracing::debug!(%gid, %domain, %rid, "Setting up DNS resource NAT");

            encapsulate_and_queue(
                packet,
                ClientOrGatewayId::Gateway(gid),
                now,
                &mut self.node,
                &mut self.buffered_transmits,
                &mut self.pending_peer_packets,
            );
        }
    }

    fn reset_offline_site_status(&mut self, now: Instant) {
        let mut any_reset = false;

        for (site, (status, set_at)) in self.sites_status.iter_mut() {
            if *status != ResourceStatus::Offline {
                continue;
            };

            let offline_for = now.duration_since(*set_at);
            if offline_for < OFFLINE_SITE_STATUS_TIMEOUT {
                continue;
            };

            tracing::debug!(%site, ?offline_for, "Resetting offline site status back to unknown");

            *status = ResourceStatus::Unknown;
            *set_at = now;

            any_reset = true;
        }

        if any_reset {
            self.resource_list.update(self.resource_list_snapshot());
        }
    }

    fn handle_udp_dns_query(&mut self, upstream: dns::Upstream, packet: IpPacket, now: Instant) {
        let Some(datagram) = packet.as_udp() else {
            tracing::debug!(?packet, "Not a UDP packet");

            return;
        };

        if datagram.destination_port() != DNS_PORT {
            tracing::debug!(
                ?packet,
                "UDP DNS queries are only supported on port {DNS_PORT}"
            );
            return;
        }

        let message = match dns_types::Query::parse(datagram.payload()) {
            Ok(message) => message,
            Err(e) => {
                tracing::warn!(?packet, "Failed to parse DNS query: {e:#}");
                return;
            }
        };

        let local = SocketAddr::new(packet.destination(), datagram.destination_port());
        let remote = SocketAddr::new(packet.source(), datagram.source_port());

        if let Some(response) =
            self.handle_dns_query(message, local, remote, upstream, dns::Transport::Udp, now)
        {
            self.buffered_packets
                .extend(into_udp_dns_packet(local, remote, response));
        };
    }

    fn handle_llmnr_dns_query(&mut self, packet: IpPacket, now: Instant) {
        let Some(datagram) = packet.as_udp() else {
            tracing::debug!(?packet, "Not a UDP packet");

            return;
        };

        if datagram.destination_port() != LLMNR_PORT {
            tracing::debug!(
                ?packet,
                "LLMNR queries are only supported on port {LLMNR_PORT}"
            );
            return;
        }

        let message = match dns_types::Query::parse(datagram.payload()) {
            Ok(message) => message,
            Err(e) => {
                tracing::warn!(?packet, "Failed to parse DNS query: {e:#}");
                return;
            }
        };

        match self.resource_stub_resolver.handle_query(&message) {
            resource_stub_resolver::ResolveStrategy::LocalResponse { response, routes } => {
                #[cfg(feature = "telemetry")]
                if response.response_code() == dns_types::ResponseCode::NXDOMAIN
                    && telemetry::feature_flags::drop_llmnr_nxdomain_responses()
                {
                    return;
                }

                self.update_dns_resource_routes(routes);
                self.dns_resource_nat.recreate(message.domain());
                self.update_dns_resource_nat(now, iter::empty());

                let response_bytes = response.into_bytes(MAX_UDP_PAYLOAD);
                let maybe_packet = ip_packet::make::udp_packet(
                    packet.destination(),
                    packet.source(),
                    datagram.destination_port(),
                    datagram.source_port(),
                    &response_bytes,
                )
                .inspect_err(|e| {
                    tracing::debug!("Failed to create LLMNR DNS response packet: {e:#}");
                })
                .ok();

                self.buffered_packets.extend(maybe_packet);
            }
            resource_stub_resolver::ResolveStrategy::RecurseLocal => {
                tracing::trace!("LLMNR queries are not forwarded to upstream resolvers");
            }
            resource_stub_resolver::ResolveStrategy::RecurseSite(_) => {
                tracing::trace!("LLMNR queries are not forwarded to upstream resolvers");
            }
        }
    }

    fn handle_dns_query(
        &mut self,
        message: dns_types::Query,
        local: SocketAddr,
        remote: SocketAddr,
        upstream: dns::Upstream,
        transport: dns::Transport,
        now: Instant,
    ) -> Option<dns_types::Response> {
        let query_id = message.id();

        if let Some(response) = self.dns_cache.try_answer(&message, now) {
            return Some(response);
        }

        // Device names are answered from the portal ahead of DNS resources.
        match self
            .device_stub_resolver
            .handle_query(&message, local, remote, transport, now)
        {
            device_stub_resolver::ResolveStrategy::Passthrough => {}
            device_stub_resolver::ResolveStrategy::LocalResponse(response) => {
                return Some(response);
            }
            device_stub_resolver::ResolveStrategy::Pending => {
                self.drain_device_stub_resolver_events();
                return None;
            }
        }

        match self.resource_stub_resolver.handle_query(&message) {
            resource_stub_resolver::ResolveStrategy::LocalResponse { response, routes } => {
                self.update_dns_resource_routes(routes);
                self.dns_resource_nat.recreate(message.domain());
                self.update_dns_resource_nat(now, iter::empty());
                self.drain_resource_stub_resolver_events();
                self.dns_cache.insert(message.domain(), &response, now);

                return Some(response);
            }
            resource_stub_resolver::ResolveStrategy::RecurseLocal => {
                if let Some(upstream) = self.should_forward_dns_query_to_gateway(&upstream) {
                    self.forward_dns_query_to_new_upstream_via_tunnel(
                        local, remote, upstream, message, transport, now,
                    );

                    return None;
                }

                tracing::trace!(%upstream, %query_id, "Forwarding {transport} DNS query");

                self.buffered_dns_queries.push_back(dns::RecursiveQuery {
                    server: upstream,
                    local,
                    remote,
                    message,
                    transport,
                });
            }
            resource_stub_resolver::ResolveStrategy::RecurseSite(resources) => {
                let gateway_id = resources.iter().find_map(|resource| {
                    self.outbound_authorizations
                        .gateway_by_resource(*resource)
                        .copied()
                });
                let Some(gateway) = gateway_id.and_then(|id| self.gateways.peer_by_id_mut(&id))
                else {
                    self.pending_authorizations.on_not_authorized(
                        AuthorizationRequest::Resources(resources),
                        DnsQueryForSite {
                            local,
                            remote,
                            transport,
                            message,
                        },
                        now,
                    );
                    return None;
                };

                let server = gateway.tun_dns_server_endpoint(local.ip());

                self.forward_dns_query_to_new_upstream_via_tunnel(
                    local, remote, server, message, transport, now,
                );
            }
        };

        None
    }

    fn forward_dns_query_to_new_upstream_via_tunnel(
        &mut self,
        local: SocketAddr,
        remote: SocketAddr,
        server: SocketAddr,
        query: dns_types::Query,
        transport: dns::Transport,
        now: Instant,
    ) {
        let query_id = query.id();

        let result = match transport {
            dns::Transport::Udp => self
                .udp_dns_client
                .send_query(server, query.clone(), now)
                .map(UpstreamQuery::Udp),
            dns::Transport::Tcp => self
                .tcp_dns_client
                .send_query(server, query.clone())
                .map(UpstreamQuery::Tcp),
        };

        let upstream_query = match result {
            Ok(upstream_query) => upstream_query,
            Err(e) => {
                tracing::warn!(
                    ?query,
                    "Failed to send recursive {transport} DNS query to upstream resolver: {e:#}"
                );

                let response = dns_types::ResponseBuilder::for_query(
                    &query,
                    dns_types::ResponseCode::SERVFAIL,
                )
                .build();

                match transport {
                    dns::Transport::Udp => {
                        self.buffered_packets
                            .extend(into_udp_dns_packet(local, remote, response));
                    }
                    dns::Transport::Tcp => {
                        unwrap_or_warn!(
                            self.tcp_dns_server.send_message(local, remote, response),
                            "Failed to send TCP DNS response: {}"
                        );
                    }
                }

                return;
            }
        };

        tracing::trace!(%server, %local, %query_id, "Forwarded {transport} DNS query via tunnel");

        let existing = self
            .dns_streams_by_upstream_query
            .insert(upstream_query, (local, remote, now));

        debug_assert!(existing.is_none(), "Query tokens should be unique");
    }

    fn maybe_update_tun_routes(&mut self) {
        let Some(config) = self.tun_config.current() else {
            return;
        };

        let new_tun_config = TunConfig {
            routes: BTreeSet::from_iter(self.routes()),
            ..config.clone()
        };

        self.maybe_update_tun_config(new_tun_config);
    }

    fn maybe_update_tun_config(&mut self, new_tun_config: TunConfig) {
        if Some(&new_tun_config) == self.tun_config.current() {
            tracing::trace!(current = ?self.tun_config.current(), "TUN device configuration unchanged");

            return;
        }

        self.resource_stub_resolver
            .set_search_domain(new_tun_config.search_domain.clone());
        self.tun_config.update(new_tun_config);

        self.initialise_tcp_dns_client(); // We must reset the TCP DNS client because changed CIDR resources (and thus changed routes) might affect which site we connect to.
        self.initialise_tcp_dns_server();
    }

    fn drain_node_events(&mut self, now: Instant) {
        let mut added_ice_candidates =
            BTreeMap::<ClientOrGatewayId, BTreeSet<IceCandidate>>::default();
        let mut removed_ice_candidates =
            BTreeMap::<ClientOrGatewayId, BTreeSet<IceCandidate>>::default();

        while let Some(event) = self.node.poll_event() {
            match event {
                snownet::Event::ConnectionFailed(ClientOrGatewayId::Gateway(id)) => {
                    self.cleanup_connected_gateway(&id, now);
                }
                snownet::Event::ConnectionClosed(ClientOrGatewayId::Gateway(id)) => {
                    self.cleanup_connected_gateway(&id, now);
                }
                snownet::Event::ConnectionFailed(ClientOrGatewayId::Client(id)) => {
                    self.cleanup_connected_client(&id);
                }
                snownet::Event::ConnectionClosed(ClientOrGatewayId::Client(id)) => {
                    self.cleanup_connected_client(&id);
                }
                snownet::Event::NewIceCandidate {
                    connection,
                    candidate,
                } if !self.portal.is_connected() => {
                    // Portal is down: hold the candidate back until it reconnects
                    // instead of emitting an event that would be lost.
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
                snownet::Event::ConnectionEstablished(ClientOrGatewayId::Gateway(id)) => {
                    self.flush_pending_packets(ClientOrGatewayId::Gateway(id), now);
                    self.update_site_status_by_gateway(&id, ResourceStatus::Online, now);
                }
                snownet::Event::ConnectionEstablished(ClientOrGatewayId::Client(id)) => {
                    self.flush_pending_packets(ClientOrGatewayId::Client(id), now);
                    self.resource_list.update(self.resource_list_snapshot());
                }
                snownet::Event::NoRelays => {
                    self.buffered_events.push_back(ClientEvent::NoRelays);
                }
            }
        }

        for (conn_id, candidates) in added_ice_candidates.into_iter() {
            self.buffered_events
                .push_back(ClientEvent::AddedIceCandidates {
                    conn_id,
                    candidates,
                })
        }

        for (conn_id, candidates) in removed_ice_candidates.into_iter() {
            self.buffered_events
                .push_back(ClientEvent::RemovedIceCandidates {
                    conn_id,
                    candidates,
                })
        }
    }

    fn update_dns_resource_routes(
        &mut self,
        routes: Vec<resource_stub_resolver::DnsResourceRoute>,
    ) {
        for route in routes {
            let Some(Resource::Dns(dns)) = self.resources_by_id.get(&route.resource_id) else {
                continue;
            };

            for ip in route.proxy_ips {
                self.routing_tables.upsert_dns(
                    ip.into(),
                    route.resource_id,
                    route.domain.clone(),
                    route.pattern.clone(),
                    FilterEngine::new(&dns.filters),
                );
            }
        }
    }

    fn drain_resource_stub_resolver_events(&mut self) {
        while let Some(resource_stub_resolver::Event::RecordsChanged(records)) =
            self.resource_stub_resolver.poll_event()
        {
            self.buffered_events
                .push_back(ClientEvent::DnsRecordsChanged { records });
        }
    }

    fn drain_device_stub_resolver_events(&mut self) {
        while let Some(event) = self.device_stub_resolver.poll_event() {
            match event {
                device_stub_resolver::Event::QueryDomain { domain } => {
                    self.buffered_events
                        .push_back(ClientEvent::DeviceDomainQueried { domain });
                }
                device_stub_resolver::Event::SendResponse {
                    local,
                    remote,
                    transport,
                    response,
                } => {
                    self.send_dns_response(local, remote, transport, response);
                }
            }
        }
    }

    fn update_site_status_by_gateway(
        &mut self,
        gid: &GatewayId,
        status: ResourceStatus,
        now: Instant,
    ) {
        #[expect(clippy::disallowed_methods, reason = "Iteration order doesn't matter.")]
        let Some((sid, _)) = self
            .gateways_by_site
            .iter()
            .find(|(_, gateways)| gateways.contains(gid))
        else {
            tracing::warn!(%gid, "Cannot update status of unknown site");
            return;
        };

        self.sites_status.insert(*sid, (status, now));
        self.resource_list.update(self.resource_list_snapshot());
    }

    pub fn poll_event(&mut self) -> Option<ClientEvent> {
        if let Some(config) = self.tun_config.take_pending_update() {
            tracing::info!(?config, "Updating TUN device");

            return Some(ClientEvent::TunInterfaceUpdated(config));
        }

        if let Some(resources) = self.resource_list.take_pending_update() {
            tracing::debug!(
                resources = resources.resources.len(),
                connected_devices = resources.connected_devices.len(),
                "Updating resource list"
            );

            return Some(ClientEvent::ResourcesChanged { resources });
        }

        if let Some(request) = self.pending_authorizations.poll_authorization_requests() {
            return Some(match request {
                AuthorizationRequest::Resources(resources) => ClientEvent::RequestAccess {
                    preferred_gateways: resources
                        .iter()
                        .flat_map(|resource| self.preferred_gateways(*resource))
                        .unique()
                        .collect(),
                    resource_ids: resources,
                    ip: None,
                },
                AuthorizationRequest::Device { addr, pools } => ClientEvent::RequestAccess {
                    resource_ids: pools,
                    ip: Some(addr),
                    preferred_gateways: Vec::new(),
                },
            });
        }

        self.buffered_events.pop_front()
    }

    /// Records whether we currently have a live connection to the portal.
    ///
    /// While disconnected, ICE candidate changes are held back. On the disconnected ->
    /// connected edge, the held changes are flushed to their peers, one batch per
    /// connection, so a peer we roamed away from learns our new addresses and forgets
    /// the ones that became unreachable.
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
                .push_back(ClientEvent::AddedIceCandidates {
                    conn_id,
                    candidates,
                });
        }

        for (conn_id, candidates) in held.removed {
            if candidates.is_empty() {
                continue;
            }

            self.buffered_events
                .push_back(ClientEvent::RemovedIceCandidates {
                    conn_id,
                    candidates,
                });
        }
    }

    pub fn reset(&mut self, now: Instant, reason: &str) {
        tracing::info!("Resetting network state ({reason})");

        self.node.reset(now);
        self.drain_node_events(now);

        // Resetting the client will trigger a failed `QueryResult` for each one that is in-progress.
        // Failed queries get translated into `SERVFAIL` responses to the client.
        self.tcp_dns_client.reset();
    }

    pub fn poll_transmit(&mut self) -> Option<snownet::Transmit> {
        self.buffered_transmits
            .poll_transmit()
            .or_else(|| self.node.poll_transmit())
    }

    pub fn poll_dns_queries(&mut self) -> Option<dns::RecursiveQuery> {
        self.buffered_dns_queries.pop_front()
    }

    /// Replaces the configured resources while retaining unchanged routes.
    pub fn set_resources(
        &mut self,
        new_resources: Vec<crate::messages::client::ResourceDescription>,
        now: Instant,
    ) {
        let new_resources = new_resources
            .into_iter()
            .filter_map(Resource::from_description)
            .collect::<Vec<_>>();

        self.replace_resources(new_resources, now);
    }

    fn replace_resources(&mut self, new_resources: Vec<Resource>, now: Instant) {
        let current_resource_ids = self
            .resources_by_id
            .keys()
            .copied()
            .collect::<BTreeSet<_>>();
        let new_resource_ids = new_resources.iter().map(|r| r.id()).collect();

        tracing::debug!(?current_resource_ids, ?new_resource_ids);

        // First, remove all resources that are not present in the new resource list.
        for id in current_resource_ids.difference(&new_resource_ids).copied() {
            self.remove_resource(id, now);
        }

        // Second, add all resources.
        for resource in new_resources {
            self.upsert_resource(resource, now)
        }

        self.maybe_update_tun_routes();
        self.resource_list.update(self.resource_list_snapshot());
    }

    pub fn add_resource(
        &mut self,
        new_resource: crate::messages::client::ResourceDescription,
        now: Instant,
    ) {
        let Some(new_resource) = Resource::from_description(new_resource) else {
            return;
        };

        self.upsert_resource(new_resource, now);
    }

    fn upsert_resource(&mut self, new_resource: Resource, now: Instant) {
        if let Resource::DevicePool(new_pool) = new_resource {
            if self
                .resources_by_id
                .get(&new_pool.id)
                .is_some_and(|resource| !matches!(resource, Resource::DevicePool(_)))
            {
                self.remove_resource(new_pool.id, now);
            }

            self.upsert_device_pool(new_pool);
            return;
        }

        if let Some(resource) = self.resources_by_id.get(&new_resource.id()) {
            let resource_addressability_changed = resource.has_different_address(&new_resource)
                || resource.has_different_ip_stack(&new_resource)
                || resource.has_different_site(&new_resource)
                || resource.has_different_filters(&new_resource);

            if resource_addressability_changed {
                tracing::debug!(rid = %new_resource.id(), "Resource is known but its addressability changed");

                self.remove_resource(resource.id(), now);
            }
        }

        self.resources_by_id
            .insert(new_resource.id(), new_resource.clone());

        let activated = match &new_resource {
            Resource::Dns(dns) => {
                let result = self.resource_stub_resolver.add_resource(
                    dns.id,
                    dns.address.clone(),
                    dns.ip_stack,
                );

                self.update_dns_resource_routes(result.routes);

                result.is_new
            }
            Resource::Cidr(cidr) => self.routing_tables.upsert_cidr(
                cidr.address,
                cidr.id,
                FilterEngine::new(&cidr.filters),
            ),
            Resource::Internet(_) => self.is_internet_resource_active,
            Resource::DevicePool(_) => unreachable!("handled above"),
        };

        if activated {
            self.log_activating_resource(&new_resource);
        }

        self.drain_resource_stub_resolver_events();
        self.maybe_update_tun_routes();
        self.resource_list.update(self.resource_list_snapshot());
        self.dns_cache.flush("Resource added");
    }

    /// Stores a device pool and routes both tunnel ranges through its filters.
    fn upsert_device_pool(&mut self, new_pool: DevicePoolResource) {
        let pool_id = new_pool.id;

        let old_filters = match self.resources_by_id.get(&pool_id) {
            Some(Resource::DevicePool(pool)) => Some(pool.filters.clone()),
            Some(Resource::Dns(_) | Resource::Cidr(_) | Resource::Internet(_)) | None => None,
        };

        // Filtering is enforced on the receiving side, so a tightened filter must reach
        // every established connection too.
        if old_filters
            .as_ref()
            .is_some_and(|filters| *filters != new_pool.filters)
        {
            self.handle_resource_filters_updated(pool_id, new_pool.filters.clone());
        }

        self.routing_tables
            .upsert_pool(pool_id, FilterEngine::new(&new_pool.filters));

        let resource = Resource::DevicePool(new_pool);
        self.resources_by_id.insert(pool_id, resource.clone());

        if old_filters.is_none() {
            self.log_activating_resource(&resource);
        }

        self.resource_list.update(self.resource_list_snapshot());
    }

    fn log_activating_resource(&self, resource: &Resource) {
        let name = resource.name();
        let address = resource.address_string().map(tracing::field::display);
        let sites = resource.sites_string().map(tracing::field::display);

        tracing::info!(%name, address, sites, "Activating resource");
    }

    #[tracing::instrument(level = "debug", skip_all, fields(?id))]
    pub fn remove_resource(&mut self, id: ResourceId, now: Instant) {
        self.disable_resource(id, now);

        self.resources_by_id.remove(&id);
        self.routing_tables.remove_by_id(id);

        self.maybe_update_tun_routes();
        self.resource_list.update(self.resource_list_snapshot());
        self.dns_cache.flush("Resource removed");
    }

    fn disable_resource(&mut self, id: ResourceId, now: Instant) {
        let Some(resource) = self.resources_by_id.get(&id) else {
            return;
        };

        match resource {
            Resource::Dns(_) => self.resource_stub_resolver.remove_resource(id),
            Resource::Cidr(_) => {}
            Resource::Internet(_) => self.is_internet_resource_active = false,
            Resource::DevicePool(_) => {}
        }

        let name = resource.name();
        let address = resource.address_string().map(tracing::field::display);
        let sites = resource.sites_string().map(tracing::field::display);

        tracing::info!(%name, address, sites, "Deactivating resource");

        self.pending_authorizations
            .remove_resource_authorizations(id);

        if let Resource::DevicePool(_) = resource {
            self.pending_authorizations
                .remove_device_authorizations_for_pool(id);
        }

        for peer in self.clients.iter_mut() {
            peer.remove_resource(&id);
        }

        let Some((_, peer)) =
            gateway_by_resource_mut(&self.outbound_authorizations, &mut self.gateways, id)
        else {
            self.outbound_authorizations.remove_resource(id);
            return;
        };

        peer.remove_resource(id);

        self.outbound_authorizations.remove_resource(id);
        self.dns_resource_nat.clear_by_resource(&id);

        let unused_gateways = self.gateways.extract_if(|_, p| p.no_allowed_resources());

        for (gid, _) in unused_gateways {
            tracing::debug!(%gid, "Disabled / deactivated last resource for peer");

            self.node.close_connection(
                ClientOrGatewayId::Gateway(gid),
                p2p_control::goodbye(),
                now,
            );
            self.update_site_status_by_gateway(&gid, ResourceStatus::Unknown, now);
            self.resource_list.update(self.resource_list_snapshot());
        }
    }

    pub fn update_relays(
        &mut self,
        to_remove: BTreeSet<RelayId>,
        to_add: BTreeSet<(RelayId, RelaySocket, String, String, String)>,
        now: Instant,
    ) {
        self.node.update_relays(to_remove, &to_add, now);
        self.drain_node_events(now); // Ensure all state changes are fully-propagated.
    }
}

fn internet_resource(
    resources_by_id: &BTreeMap<ResourceId, Resource>,
) -> Option<&InternetResource> {
    resources_by_id.values().find_map(|r| match r {
        Resource::Dns(_) => None,
        Resource::Cidr(_) => None,
        Resource::DevicePool(_) => None,
        Resource::Internet(internet_resource) => Some(internet_resource),
    })
}

/// Generate an ICMP "administratively prohibited" error for `packet` and
/// buffer it for delivery back to the TUN device.
fn reply_with_icmp_prohibited(buffered_packets: &mut VecDeque<IpPacket>, packet: IpPacket) {
    match ip_packet::make::icmp_dest_unreachable_prohibited(&packet) {
        Ok(reply) => buffered_packets.push_back(reply),
        Err(e) => tracing::debug!("Failed to create ICMP prohibited error: {e:#}"),
    }
}

#[derive(Default)]
struct OutboundAuthorizations {
    gateways: HashMap<ResourceId, GatewayAuthorization>,
    device_pools: HashMap<ResourceId, BTreeMap<ClientId, IngestToken>>,
}

struct GatewayAuthorization {
    gateway_id: GatewayId,
    ingest_token: IngestToken,
}

impl OutboundAuthorizations {
    fn authorize_gateway(
        &mut self,
        resource_id: ResourceId,
        gateway_id: GatewayId,
        ingest_token: IngestToken,
    ) {
        self.gateways.insert(
            resource_id,
            GatewayAuthorization {
                gateway_id,
                ingest_token,
            },
        );
    }

    fn authorize_client(
        &mut self,
        resource_id: ResourceId,
        client_id: ClientId,
        ingest_token: IngestToken,
    ) {
        self.device_pools
            .entry(resource_id)
            .or_default()
            .insert(client_id, ingest_token);
    }

    fn gateway(&self, resource_id: ResourceId) -> Option<&GatewayAuthorization> {
        self.gateways.get(&resource_id)
    }

    fn gateway_by_resource(&self, resource_id: ResourceId) -> Option<&GatewayId> {
        Some(&self.gateway(resource_id)?.gateway_id)
    }

    fn client_token(&self, resource_id: ResourceId, client_id: ClientId) -> Option<&IngestToken> {
        self.device_pools.get(&resource_id)?.get(&client_id)
    }

    fn remove_client(&mut self, resource_id: ResourceId, client_id: ClientId) {
        if let Some(clients) = self.device_pools.get_mut(&resource_id) {
            clients.remove(&client_id);
        }
    }

    fn forget_client(&mut self, client_id: ClientId) {
        for clients in self.device_pools.values_mut() {
            clients.remove(&client_id);
        }
    }

    fn remove_resource(&mut self, resource_id: ResourceId) {
        self.gateways.remove(&resource_id);
        self.device_pools.remove(&resource_id);
    }

    fn forget_gateway(&mut self, gateway_id: GatewayId) {
        for _ in self
            .gateways
            .extract_if(|_, authorization| authorization.gateway_id == gateway_id)
        {}
    }
}

fn is_llmnr(dst: IpAddr) -> bool {
    match dst {
        IpAddr::V4(ip) => ip == LLMNR_IPV4,
        IpAddr::V6(ip) => ip == LLMNR_IPV6,
    }
}

fn is_dns_sentinel(dst: IpAddr) -> bool {
    match dst {
        IpAddr::V4(ip) => DNS_SENTINELS_V4.contains(ip),
        IpAddr::V6(ip) => DNS_SENTINELS_V6.contains(ip),
    }
}

/// The Client an ICMP error follows, if it refers to a flow we have with them.
///
/// Only Clients are considered: an error bound for a Gateway is not covered by a
/// client-to-client flow and stays unroutable.
///
/// In tests, a malicious client can be configured to send one for a flow it has no
/// part in, keeping the target Client's check for errors referencing an unknown
/// flow exercised.
fn client_for_icmp_error(
    clients: &PeerStore<ClientId, ClientOnClient>,
    packet: &IpPacket,
) -> Option<ClientId> {
    if !packet.icmp_error().is_ok_and(|error| error.is_some()) {
        return None;
    }

    let (cid, peer) = clients.peer_by_ip(packet.destination())?;

    if peer.is_known_outbound_error(packet) {
        return Some(cid);
    }

    #[cfg(any(test, feature = "malicious-behaviour"))]
    if crate::malicious_behaviour::send_untracked_icmp_errors() {
        tracing::debug!("Malicious client: sending ICMP error for an untracked flow");
        return Some(cid);
    }

    None
}

/// Like [`encapsulate_or_buffer`], but encapsulates into `buffered_transmits` and drops (with a
/// log) any error instead of returning it.
fn encapsulate_and_queue(
    packet: IpPacket,
    pid: ClientOrGatewayId,
    now: Instant,
    node: &mut Node<ClientOrGatewayId, RelayId>,
    buffered_transmits: &mut snownet::TransmitBuffer,
    pending_peer_packets: &mut BTreeMap<ClientOrGatewayId, UniquePacketBuffer>,
) {
    if let Err(e) = encapsulate_or_buffer(
        packet,
        pid,
        now,
        node,
        buffered_transmits,
        pending_peer_packets,
    ) {
        tracing::debug!(%pid, "Failed to encapsulate: {e:#}");
    }
}

/// Encapsulate `packet` for `pid` directly into `provider`, or buffer it if the connection is
/// still being established.
fn encapsulate_or_buffer(
    packet: IpPacket,
    pid: ClientOrGatewayId,
    now: Instant,
    node: &mut Node<ClientOrGatewayId, RelayId>,
    provider: &mut impl snownet::BufferProvider,
    pending_packets: &mut BTreeMap<ClientOrGatewayId, UniquePacketBuffer>,
) -> Result<()> {
    const CONNECTION_BUFFER_CAPACITY_POW_2: usize = 7; // 2^7 = 128

    if let Some(buffer) = pending_packets.get_mut(&pid) {
        buffer.push(packet);
        return Ok(());
    }

    match node.encapsulate(pid, &packet, now, provider) {
        Ok(Some(info)) => {
            flow_tracker::record_transmit(info.src, info.dst);
        }
        Ok(None) => {}
        Err(e) if e.any_is::<snownet::StillConnecting>() => {
            pending_packets
                .entry(pid)
                .or_insert_with(|| {
                    UniquePacketBuffer::with_capacity_power_of_2(
                        CONNECTION_BUFFER_CAPACITY_POW_2,
                        "pending-connection",
                    )
                })
                .push(packet);
        }
        Err(e) if e.any_is::<snownet::UnknownConnection>() => {
            return Err(e.context(UnroutablePacket::not_connected(&packet)));
        }
        Err(e) => return Err(e),
    };

    Ok(())
}

fn gateway_by_resource_mut<'p>(
    authorizations: &OutboundAuthorizations,
    peers: &'p mut PeerStore<GatewayId, GatewayOnClient>,
    resource: ResourceId,
) -> Option<(GatewayId, &'p mut GatewayOnClient)> {
    let gateway_id = authorizations.gateway_by_resource(resource)?;
    let peer = peers.peer_by_id_mut(gateway_id)?;

    Some((*gateway_id, peer))
}

fn into_udp_dns_packet(
    from: SocketAddr,
    dst: SocketAddr,
    message: dns_types::Response,
) -> Option<IpPacket> {
    let bytes = message.into_bytes(MAX_UDP_PAYLOAD);
    ip_packet::make::udp_packet(from.ip(), dst.ip(), from.port(), dst.port(), &bytes)
        .inspect_err(|e| tracing::warn!("Failed to create IP packet for DNS response: {e:#}"))
        .ok()
}

pub struct IpProvider {
    ipv4: Box<dyn Iterator<Item = Ipv4Addr> + Send + Sync>,
    ipv6: Box<dyn Iterator<Item = Ipv6Addr> + Send + Sync>,
}

impl IpProvider {
    pub fn for_resources() -> Self {
        IpProvider::new(
            IPV4_RESOURCES,
            IPV6_RESOURCES,
            vec![
                IpNetwork::V4(DNS_SENTINELS_V4),
                IpNetwork::V6(DNS_SENTINELS_V6),
            ],
        )
    }

    pub fn for_stub_dns_servers(old_servers: Vec<IpAddr>) -> Self {
        IpProvider::new(
            DNS_SENTINELS_V4,
            DNS_SENTINELS_V6,
            old_servers.into_iter().map(IpNetwork::from).collect(),
        )
    }

    fn new(ipv4: Ipv4Network, ipv6: Ipv6Network, exclusions: Vec<IpNetwork>) -> Self {
        Self {
            ipv4: Box::new({
                let exclusions = exclusions.clone();
                ipv4.hosts()
                    .filter(move |ip| !exclusions.iter().any(|e| e.contains(*ip)))
            }),
            ipv6: Box::new({
                ipv6.subnets_with_prefix(128)
                    .map(|ip| ip.network_address())
                    .filter(move |ip| !exclusions.iter().any(|e| e.contains(*ip)))
            }),
        }
    }

    pub fn get_proxy_ip_for(&mut self, ip: &IpAddr) -> Option<IpAddr> {
        let proxy_ip = match ip {
            IpAddr::V4(_) => self.ipv4.next().map(Into::into),
            IpAddr::V6(_) => self.ipv6.next().map(Into::into),
        };

        if proxy_ip.is_none() {
            // TODO: we might want to make the iterator cyclic or another strategy to prevent ip exhaustion
            // this might happen in ipv4 if tokens are too long lived.
            tracing::error!("IP exhaustion: Please reset your client");
        }

        proxy_ip
    }

    pub fn get_n_ipv4(&mut self, n: usize) -> Vec<IpAddr> {
        self.ipv4.by_ref().take(n).map_into().collect_vec()
    }

    pub fn get_n_ipv6(&mut self, n: usize) -> Vec<IpAddr> {
        self.ipv6.by_ref().take(n).map_into().collect_vec()
    }
}

#[cfg(test)]
fn test_ingest_token() -> IngestToken {
    serde_json::from_value(serde_json::json!(flow_tracker::TEST_INGEST_TOKEN)).unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::messages::PortRange;

    #[test]
    fn does_not_queue_device_access_intent_for_packet_to_own_tun_ipv4() {
        let mut state = ClientState::for_test();
        let tun_ipv4 = Ipv4Addr::new(100, 82, 80, 16);
        state.update_interface_config(interface(tun_ipv4, Ipv6Addr::LOCALHOST));

        let packet = ip_packet::make::udp_packet(tun_ipv4, tun_ipv4, 137, 137, &[1]).unwrap();

        assert_eq!(
            state
                .handle_tun_input(packet, Instant::now(), &mut snownet::TransmitBuffer::new())
                .unwrap_err()
                .to_string(),
            "Unroutable packet: Packet destination IP is TUN device"
        );
        assert_no_device_connection_intent(&mut state);
    }

    #[test]
    fn does_not_queue_device_access_intent_for_packet_to_own_tun_ipv6() {
        let mut state = ClientState::for_test();
        let tun_ipv6 = Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 1);
        state.update_interface_config(interface(Ipv4Addr::LOCALHOST, tun_ipv6));

        let packet = ip_packet::make::udp_packet(tun_ipv6, tun_ipv6, 137, 137, &[1]).unwrap();

        assert_eq!(
            state
                .handle_tun_input(packet, Instant::now(), &mut snownet::TransmitBuffer::new())
                .unwrap_err()
                .to_string(),
            "Unroutable packet: Packet destination IP is TUN device"
        );
        assert_no_device_connection_intent(&mut state);
    }

    #[test]
    fn packet_to_a_tunnel_address_asks_for_device_access_through_permitting_pools() {
        let mut state = ClientState::for_test();
        let now = Instant::now();
        state.update_interface_config(interface(own_tun_ipv4(), own_tun_ipv6()));
        state.upsert_resource(device_pool(1, vec![]), now);
        state.upsert_resource(device_pool(2, vec![Filter::Icmp]), now);
        state.upsert_resource(
            device_pool(3, vec![Filter::Udp(PortRange::new(53, 53).unwrap())]),
            now,
        );
        while state.poll_event().is_some() {}

        let packet =
            ip_packet::make::udp_packet(own_tun_ipv4(), device_tun_ipv4(), 1234, 53, &[1]).unwrap();
        state
            .handle_tun_input(packet, now, &mut snownet::TransmitBuffer::new())
            .unwrap();

        let request = iter::from_fn(|| state.poll_event()).find_map(|event| {
            if let ClientEvent::RequestAccess {
                ip: Some(ip),
                resource_ids,
                ..
            } = event
                && ip == IpAddr::V4(device_tun_ipv4())
            {
                return Some(resource_ids);
            }

            None
        });
        assert_eq!(
            request,
            Some(vec![ResourceId::from_u128(3), ResourceId::from_u128(1)]),
            "expected the permitting pools in routing table order"
        );
    }

    #[test]
    fn packet_to_a_tunnel_address_no_pool_permits_is_prohibited_locally() {
        let mut state = ClientState::for_test();
        let now = Instant::now();
        state.update_interface_config(interface(own_tun_ipv4(), own_tun_ipv6()));
        state.upsert_resource(device_pool(2, vec![Filter::Icmp]), now);
        while state.poll_event().is_some() {}
        while state.poll_packets().is_some() {}

        let packet =
            ip_packet::make::udp_packet(own_tun_ipv4(), device_tun_ipv4(), 1234, 53, &[1]).unwrap();
        state
            .handle_tun_input(packet, now, &mut snownet::TransmitBuffer::new())
            .unwrap();

        assert_no_device_connection_intent(&mut state);
        assert!(
            state.poll_packets().is_some(),
            "expected an ICMP error without a request"
        );
    }

    #[test]
    fn denied_device_flow_is_answered_and_asked_again_on_the_next_packet() {
        let mut state = ClientState::for_test();
        let now = Instant::now();
        state.update_interface_config(interface(own_tun_ipv4(), own_tun_ipv6()));
        state.upsert_resource(device_pool(1, vec![]), now);
        while state.poll_event().is_some() {}
        while state.poll_packets().is_some() {}

        let packet = || {
            ip_packet::make::udp_packet(own_tun_ipv4(), device_tun_ipv4(), 1234, 53, &[1]).unwrap()
        };

        state
            .handle_tun_input(packet(), now, &mut snownet::TransmitBuffer::new())
            .unwrap();
        while state.poll_event().is_some() {}

        state.handle_client_device_access_denied(
            Some(device_tun_ipv4()),
            None,
            FailReason::Forbidden,
        );
        assert!(
            state.poll_packets().is_some(),
            "expected an ICMP error for the buffered packet"
        );

        state
            .handle_tun_input(packet(), now, &mut snownet::TransmitBuffer::new())
            .unwrap();
        assert!(
            state.poll_packets().is_none(),
            "expected the packet to be buffered for a new request"
        );
        assert!(
            state.poll_event().is_some_and(|event| matches!(
                event,
                ClientEvent::RequestAccess { ip: Some(_), .. }
            )),
            "expected a new device access request"
        );
    }

    #[test]
    fn prefers_already_connected_gateways() {
        let mut state = ClientState::for_test();
        state.gateways_by_site.insert(
            SiteId::from_u128(1),
            HashSet::from([GatewayId::from_u128(10), GatewayId::from_u128(20)]),
        );
        state.gateways_by_site.insert(
            SiteId::from_u128(2),
            HashSet::from([GatewayId::from_u128(30), GatewayId::from_u128(40)]),
        );
        state.gateways.upsert(GatewayId::from_u128(30), peer);

        let preferred_gateways = state.preferred_gateways(ResourceId::from_u128(100));

        assert_eq!(
            preferred_gateways,
            vec![
                GatewayId::from_u128(30),
                GatewayId::from_u128(10),
                GatewayId::from_u128(20),
                GatewayId::from_u128(40)
            ]
        );
    }

    #[test]
    fn remembers_preference_for_authorized_resource_after_reset() {
        let mut state = ClientState::for_test();
        state.gateways_by_site.insert(
            SiteId::from_u128(1),
            HashSet::from([GatewayId::from_u128(10), GatewayId::from_u128(20)]),
        );
        state.gateways_by_site.insert(
            SiteId::from_u128(2),
            HashSet::from([GatewayId::from_u128(30), GatewayId::from_u128(40)]),
        );
        state.gateways.upsert(GatewayId::from_u128(30), peer);
        state.outbound_authorizations.authorize_gateway(
            ResourceId::from_u128(100),
            GatewayId::from_u128(30),
            test_ingest_token(),
        );

        state.reset(Instant::now(), "test");
        let preferred_gateways = state.preferred_gateways(ResourceId::from_u128(100));

        assert_eq!(
            preferred_gateways,
            vec![
                GatewayId::from_u128(30),
                GatewayId::from_u128(10),
                GatewayId::from_u128(20),
                GatewayId::from_u128(40)
            ]
        );
    }

    #[test]
    fn offline_site_status_resets_after_5_minutes() {
        let now = Instant::now();
        let mut state = ClientState::for_test();
        let site = SiteId::from_u128(1);

        state
            .sites_status
            .insert(site, (ResourceStatus::Offline, now));

        let expires_at = now + OFFLINE_SITE_STATUS_TIMEOUT;

        assert_eq!(
            state.poll_timeout(),
            Some((expires_at, "Offline site status expiry"))
        );

        state.handle_timeout(expires_at);

        assert_eq!(
            state.sites_status.get(&site).unwrap(),
            &(ResourceStatus::Unknown, expires_at)
        );
        assert!(matches!(
            state.poll_event().unwrap(),
            ClientEvent::ResourcesChanged { .. }
        ));
    }

    #[test]
    fn no_resource_list_update_if_site_status_does_not_change() {
        let mut now = Instant::now();
        let mut state = ClientState::for_test();
        let site = SiteId::from_u128(1);

        let offline_at = now;

        state
            .sites_status
            .insert(site, (ResourceStatus::Offline, offline_at));

        now += Duration::from_secs(60);

        state.handle_timeout(now);

        assert_eq!(
            state.sites_status.get(&site).unwrap(),
            &(ResourceStatus::Offline, offline_at)
        );
        assert!(state.poll_event().is_none());
    }

    impl ClientState {
        pub fn for_test() -> ClientState {
            ClientState::new(
                rand::random(),
                Default::default(),
                false,
                Instant::now(),
                Duration::ZERO,
            )
        }
    }

    fn peer() -> GatewayOnClient {
        GatewayOnClient::new(IpConfig {
            v4: Ipv4Addr::LOCALHOST,
            v6: Ipv6Addr::LOCALHOST,
        })
    }

    fn interface(ipv4: Ipv4Addr, ipv6: Ipv6Addr) -> InterfaceConfig {
        InterfaceConfig {
            ipv4,
            ipv6,
            upstream_dns: vec![],
            upstream_do53: vec![],
            upstream_doh: vec![],
            search_domain: None,
        }
    }

    fn own_tun_ipv4() -> Ipv4Addr {
        Ipv4Addr::new(100, 82, 80, 16)
    }

    fn own_tun_ipv6() -> Ipv6Addr {
        Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 1)
    }

    fn device_tun_ipv4() -> Ipv4Addr {
        Ipv4Addr::new(100, 82, 80, 17)
    }

    fn device_pool(id: u128, filters: Vec<Filter>) -> Resource {
        Resource::DevicePool(DevicePoolResource {
            id: ResourceId::from_u128(id),
            name: format!("pool-{id}"),
            filters,
        })
    }

    fn assert_no_device_connection_intent(state: &mut ClientState) {
        while let Some(event) = state.poll_event() {
            assert!(
                !matches!(event, ClientEvent::RequestAccess { ip: Some(_), .. }),
                "unexpected device access request"
            );
        }
    }
}

#[cfg(test)]
mod proptests {
    use std::collections::HashSet;

    use super::*;
    use crate::proptest::*;
    use connlib_model::ResourceView;
    use prop::collection;
    use proptest::prelude::*;
    use resource::{CidrResource, DnsResource};

    #[test_strategy::proptest]
    fn cidr_resources_are_turned_into_routes(
        #[strategy(cidr_resource())] resource1: CidrResource,
        #[strategy(cidr_resource())] resource2: CidrResource,
    ) {
        let mut client_state = ClientState::for_test();

        client_state.upsert_resource(Resource::Cidr(resource1.clone()), Instant::now());
        client_state.upsert_resource(Resource::Cidr(resource2.clone()), Instant::now());

        assert_eq!(
            hashset(client_state.routes()),
            expected_routes(vec![resource1.address, resource2.address])
        );
    }

    #[test_strategy::proptest]
    fn added_resources_show_up_as_resoucres(
        #[strategy(cidr_resource())] resource1: CidrResource,
        #[strategy(dns_resource())] resource2: DnsResource,
        #[strategy(cidr_resource())] resource3: CidrResource,
    ) {
        let mut client_state = ClientState::for_test();

        client_state.upsert_resource(Resource::Cidr(resource1.clone()), Instant::now());
        client_state.upsert_resource(Resource::Dns(resource2.clone()), Instant::now());

        assert_eq!(
            hashset(client_state.resources()),
            hashset([
                ResourceView::Cidr(resource1.clone().with_status(ResourceStatus::Unknown)),
                ResourceView::Dns(resource2.clone().with_status(ResourceStatus::Unknown))
            ])
        );

        client_state.upsert_resource(Resource::Cidr(resource3.clone()), Instant::now());

        assert_eq!(
            hashset(client_state.resources()),
            hashset([
                ResourceView::Cidr(resource1.with_status(ResourceStatus::Unknown)),
                ResourceView::Dns(resource2.with_status(ResourceStatus::Unknown)),
                ResourceView::Cidr(resource3.with_status(ResourceStatus::Unknown)),
            ])
        );
    }

    #[test_strategy::proptest]
    fn adding_same_resource_with_different_address_updates_the_address(
        #[strategy(cidr_resource())] resource: CidrResource,
        #[strategy(any_ip_network(8))] new_address: IpNetwork,
    ) {
        let mut client_state = ClientState::for_test();
        client_state.upsert_resource(Resource::Cidr(resource.clone()), Instant::now());

        let updated_resource = CidrResource {
            address: new_address,
            ..resource
        };

        client_state.upsert_resource(Resource::Cidr(updated_resource.clone()), Instant::now());

        assert_eq!(
            hashset(client_state.resources()),
            hashset([ResourceView::Cidr(
                updated_resource.with_status(ResourceStatus::Unknown)
            )])
        );
        assert_eq!(
            hashset(client_state.routes()),
            expected_routes(vec![new_address])
        );
    }

    #[test_strategy::proptest]
    fn resources_can_be_removed(
        #[strategy(dns_resource())] dns_resource: DnsResource,
        #[strategy(cidr_resource())] cidr_resource: CidrResource,
    ) {
        let mut client_state = ClientState::for_test();
        client_state.upsert_resource(Resource::Dns(dns_resource.clone()), Instant::now());
        client_state.upsert_resource(Resource::Cidr(cidr_resource.clone()), Instant::now());

        client_state.remove_resource(dns_resource.id, Instant::now());

        assert_eq!(
            hashset(client_state.resources()),
            hashset([ResourceView::Cidr(
                cidr_resource.clone().with_status(ResourceStatus::Unknown)
            )])
        );
        assert_eq!(
            hashset(client_state.routes()),
            expected_routes(vec![cidr_resource.address])
        );

        client_state.remove_resource(cidr_resource.id, Instant::now());

        assert_eq!(hashset(client_state.resources().iter()), hashset(&[]));
        assert_eq!(hashset(client_state.routes()), expected_routes(vec![]));
    }

    #[test_strategy::proptest]
    fn resources_can_be_replaced(
        #[strategy(dns_resource())] dns_resource1: DnsResource,
        #[strategy(dns_resource())] dns_resource2: DnsResource,
        #[strategy(cidr_resource())] cidr_resource1: CidrResource,
        #[strategy(cidr_resource())] cidr_resource2: CidrResource,
    ) {
        let mut client_state = ClientState::for_test();
        client_state.upsert_resource(Resource::Dns(dns_resource1), Instant::now());
        client_state.upsert_resource(Resource::Cidr(cidr_resource1), Instant::now());

        client_state.replace_resources(
            vec![
                Resource::Dns(dns_resource2.clone()),
                Resource::Cidr(cidr_resource2.clone()),
            ],
            Instant::now(),
        );

        assert_eq!(
            hashset(client_state.resources()),
            hashset([
                ResourceView::Dns(dns_resource2.with_status(ResourceStatus::Unknown)),
                ResourceView::Cidr(cidr_resource2.clone().with_status(ResourceStatus::Unknown)),
            ])
        );
        assert_eq!(
            hashset(client_state.routes()),
            expected_routes(vec![cidr_resource2.address])
        );
    }

    #[test_strategy::proptest]
    fn setting_gateway_online_sets_all_related_resources_online(
        #[strategy(resources_sharing_n_sites(1))] resources_online: Vec<Resource>,
        #[strategy(resources_sharing_n_sites(1))] resources_unknown: Vec<Resource>,
        #[strategy(gateway_id())] gateway: GatewayId,
    ) {
        let mut client_state = ClientState::for_test();

        for r in resources_online.iter().chain(resources_unknown.iter()) {
            client_state.upsert_resource(r.clone(), Instant::now())
        }

        let first_resource = resources_online.first().unwrap();
        client_state.outbound_authorizations.authorize_gateway(
            first_resource.id(),
            gateway,
            test_ingest_token(),
        );
        client_state.gateways_by_site.insert(
            first_resource.sites().iter().next().unwrap().id,
            HashSet::from([gateway]),
        );

        client_state.update_site_status_by_gateway(
            &gateway,
            ResourceStatus::Online,
            Instant::now(),
        );

        for resource in resources_online {
            assert_eq!(
                client_state.resource_status(&resource),
                ResourceStatus::Online
            );
        }

        for resource in resources_unknown {
            assert_eq!(
                client_state.resource_status(&resource),
                ResourceStatus::Unknown
            );
        }
    }

    #[test_strategy::proptest]
    fn disconnecting_gateway_sets_related_resources_unknown(
        #[strategy(resources_sharing_n_sites(1))] resources: Vec<Resource>,
        #[strategy(gateway_id())] gateway: GatewayId,
    ) {
        let mut client_state = ClientState::for_test();
        for r in &resources {
            client_state.upsert_resource(r.clone(), Instant::now());
        }
        let first_resources = resources.first().unwrap();
        client_state.outbound_authorizations.authorize_gateway(
            first_resources.id(),
            gateway,
            test_ingest_token(),
        );
        client_state.gateways_by_site.insert(
            first_resources.sites().iter().next().unwrap().id,
            HashSet::from([gateway]),
        );

        client_state.update_site_status_by_gateway(
            &gateway,
            ResourceStatus::Online,
            Instant::now(),
        );
        client_state.update_site_status_by_gateway(
            &gateway,
            ResourceStatus::Unknown,
            Instant::now(),
        );

        for resource in resources {
            assert_eq!(
                client_state.resource_status(&resource),
                ResourceStatus::Unknown
            );
        }
    }

    #[test_strategy::proptest]
    fn setting_resource_offline_doesnt_set_all_related_resources_offline(
        #[strategy(resources_sharing_n_sites(2))] multi_site_resources: Vec<Resource>,
        #[strategy(resource())] single_site_resource: Resource,
    ) {
        let mut client_state = ClientState::for_test();
        client_state.upsert_resource(single_site_resource.clone(), Instant::now());
        for r in &multi_site_resources {
            client_state.upsert_resource(r.clone(), Instant::now());
        }

        client_state.set_resource_offline(single_site_resource.id(), Instant::now());

        assert_eq!(
            client_state.resource_status(&single_site_resource),
            ResourceStatus::Offline
        );
        for resource in multi_site_resources {
            assert_eq!(
                client_state.resource_status(&resource),
                ResourceStatus::Unknown
            );
        }
    }

    pub fn expected_routes(resource_routes: Vec<IpNetwork>) -> HashSet<IpNetwork> {
        HashSet::from_iter(
            resource_routes
                .into_iter()
                .chain(iter::once(IPV4_TUNNEL.into()))
                .chain(iter::once(IPV6_TUNNEL.into()))
                .chain(iter::once(IPV4_RESOURCES.into()))
                .chain(iter::once(IPV6_RESOURCES.into()))
                .chain(iter::once(DNS_SENTINELS_V4.into()))
                .chain(iter::once(DNS_SENTINELS_V6.into())),
        )
    }

    #[expect(clippy::redundant_clone)] // False positive.
    pub fn hashset<T: std::hash::Hash + Eq, B: ToOwned<Owned = T>>(
        val: impl IntoIterator<Item = B>,
    ) -> HashSet<T> {
        HashSet::from_iter(val.into_iter().map(|b| b.to_owned()))
    }

    fn resource() -> impl Strategy<Value = Resource> {
        crate::proptest::resource(site().prop_map(|s| vec![s]))
    }

    fn cidr_resource() -> impl Strategy<Value = CidrResource> {
        crate::proptest::cidr_resource(any_ip_network(8), site().prop_map(|s| vec![s]))
    }

    fn dns_resource() -> impl Strategy<Value = DnsResource> {
        crate::proptest::dns_resource(site().prop_map(|s| vec![s]))
    }

    // Generate resources sharing 1 site
    fn resources_sharing_n_sites(num_sites: usize) -> impl Strategy<Value = Vec<Resource>> {
        collection::vec(site(), num_sites)
            .prop_flat_map(|sites| collection::vec(crate::proptest::resource(Just(sites)), 1..=100))
    }
}
