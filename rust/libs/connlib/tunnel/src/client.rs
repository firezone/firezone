mod dns_cache;
pub(crate) mod dns_config;
mod dns_resource_nat;
mod gateway_on_client;
mod pending_flows;
mod resource;
mod tracked_state;

use crate::client::dns_config::DnsConfig;
pub(crate) use crate::client::gateway_on_client::GatewayOnClient;
use crate::client::pending_flows::{ConnectionTrigger, DnsQueryForSite, PendingFlows};
use crate::client::tracked_state::TrackedState;
use boringtun::x25519;
#[cfg(all(feature = "proptest", test))]
pub(crate) use resource::DnsResource;
pub(crate) use resource::{CidrResource, InternetResource, Resource};

use dns_resource_nat::DnsResourceNat;
use dns_types::ResponseCode;
use ringbuffer::RingBuffer;
use secrecy::ExposeSecret as _;
use telemetry::{analytics, feature_flags};

use crate::client::dns_cache::DnsCache;
use crate::dns::{DnsResourceRecord, StubResolver};
use crate::messages::Interface as InterfaceConfig;
use crate::messages::{IceCredentials, SecretKey};
use crate::peer_store::PeerStore;
use crate::{IPV4_TUNNEL, IPV6_TUNNEL, IpConfig, TunConfig, dns, is_peer, p2p_control};
use anyhow::{Context, ErrorExt};
use connlib_model::{
    GatewayId, IceCandidate, PublicKey, RelayId, ResourceId, ResourceStatus, ResourceView,
};
use connlib_model::{Site, SiteId};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_network_table::IpNetworkTable;
use ip_packet::{IpPacket, MAX_UDP_PAYLOAD};
use itertools::Itertools;
use logging::{unwrap_or_debug, unwrap_or_warn};

use crate::ClientEvent;
use snownet::{ClientNode, NoTurnServers, RelaySocket, Transmit};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::ops::ControlFlow;
use std::time::{Duration, Instant};
use std::{io, iter};

pub(crate) const IPV4_RESOURCES: Ipv4Network =
    match Ipv4Network::new(Ipv4Addr::new(100, 96, 0, 0), 11) {
        Ok(n) => n,
        Err(_) => unreachable!(),
    };
pub(crate) const IPV6_RESOURCES: Ipv6Network = match Ipv6Network::new(
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

pub(crate) const DNS_SENTINELS_V4: Ipv4Network =
    match Ipv4Network::new(Ipv4Addr::new(100, 100, 111, 0), 24) {
        Ok(n) => n,
        Err(_) => unreachable!(),
    };
pub(crate) const DNS_SENTINELS_V6: Ipv6Network = match Ipv6Network::new(
    Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0x8000, 0x0100, 0x0100, 0x0111, 0),
    120,
) {
    Ok(n) => n,
    Err(_) => unreachable!(),
};

/// How many concurrent TCP DNS clients we can server _per_ sentinel DNS server IP.
const NUM_CONCURRENT_TCP_DNS_CLIENTS: usize = 10;

/// A sans-IO implementation of a Client's functionality.
///
/// Internally, this composes a [`snownet::ClientNode`] with firezone's policy engine around resources.
/// Clients differ from gateways in that they also implement a DNS resolver for DNS resources.
/// They also initiate connections to Gateways based on packets sent to Resources. Gateways only accept incoming connections.
pub struct ClientState {
    /// Manages wireguard tunnels to gateways.
    node: ClientNode<GatewayId, RelayId>,
    /// All gateways we are connected to and the associated, connection-specific state.
    peers: PeerStore<GatewayId, GatewayOnClient>,
    /// Tracks the flows to resources that we are currently trying to establish.
    pending_flows: PendingFlows,
    dns_resource_nat: DnsResourceNat,
    /// Tracks the resources we have been authorized for and which Gateway to use to access them.
    ///
    /// This state persists across `reset`s so we can re-connect to the same Gateway.
    authorized_resources: HashMap<ResourceId, GatewayId>,
    /// Tracks which gateways are in a site.
    gateways_by_site: HashMap<SiteId, HashSet<GatewayId>>,
    /// The online/offline status of a site.
    sites_status: HashMap<SiteId, ResourceStatus>,

    /// All CIDR resources we know about, indexed by the IP range they cover (like `1.1.0.0/8`).
    active_cidr_resources: IpNetworkTable<CidrResource>,
    is_internet_resource_active: bool,
    /// All resources indexed by their ID.
    resources_by_id: BTreeMap<ResourceId, Resource>,

    /// Manages the DNS configuration.
    dns_config: DnsConfig,

    /// Manages internal dns records and emits forwarding event when not internally handled
    stub_resolver: StubResolver,
    /// Caches responses from DNS servers.
    dns_cache: DnsCache,

    /// Configuration of the TUN device, when it is up.
    tun_config: TrackedState<TunConfig>,
    /// Cache of the resource list we emitted to the app.
    resource_list: TrackedState<Vec<ResourceView>>,

    udp_dns_client: l3_udp_dns_client::Client,
    tcp_dns_client: dns_over_tcp::Client,
    tcp_dns_server: dns_over_tcp::Server,
    /// Tracks the UDP/TCP stream (i.e. socket-pair) on which we received a DNS query by the ID of the recursive DNS query we issued.
    dns_streams_by_local_upstream_and_query_id:
        HashMap<(dns::Transport, SocketAddr, SocketAddr, u16), (SocketAddr, SocketAddr)>,

    buffered_events: VecDeque<ClientEvent>,
    buffered_packets: VecDeque<IpPacket>,
    buffered_transmits: VecDeque<Transmit>,
    buffered_dns_queries: VecDeque<dns::RecursiveQuery>,
}

impl ClientState {
    pub(crate) fn new(
        seed: [u8; 32],
        records: BTreeSet<DnsResourceRecord>,
        is_internet_resource_active: bool,
        now: Instant,
        unix_ts: Duration,
    ) -> Self {
        Self {
            authorized_resources: Default::default(),
            active_cidr_resources: IpNetworkTable::new(),
            resources_by_id: Default::default(),
            peers: Default::default(),
            dns_config: Default::default(),
            buffered_events: Default::default(),
            tun_config: Default::default(),
            buffered_packets: Default::default(),
            node: ClientNode::new(seed, now, unix_ts),
            sites_status: Default::default(),
            gateways_by_site: Default::default(),
            stub_resolver: StubResolver::new(records),
            dns_cache: Default::default(),
            buffered_transmits: Default::default(),
            is_internet_resource_active,
            buffered_dns_queries: Default::default(),
            udp_dns_client: l3_udp_dns_client::Client::new(seed),
            tcp_dns_client: dns_over_tcp::Client::new(now, seed),
            tcp_dns_server: dns_over_tcp::Server::new(now),
            dns_streams_by_local_upstream_and_query_id: Default::default(),
            pending_flows: Default::default(),
            dns_resource_nat: Default::default(),
            resource_list: Default::default(),
        }
    }

    #[cfg(all(test, feature = "proptest"))]
    pub(crate) fn tunnel_ip_config(&self) -> Option<crate::IpConfig> {
        Some(self.tun_config.current()?.ip)
    }

    #[cfg(all(test, feature = "proptest"))]
    pub(crate) fn tunnel_ip_for(&self, dst: IpAddr) -> Option<IpAddr> {
        Some(match dst {
            IpAddr::V4(_) => self.tunnel_ip_config()?.v4.into(),
            IpAddr::V6(_) => self.tunnel_ip_config()?.v6.into(),
        })
    }

    pub(crate) fn resources(&self) -> Vec<ResourceView> {
        self.resources_by_id
            .values()
            .cloned()
            .map(|r| {
                let status = self.resource_status(&r);
                r.with_status(status)
            })
            .sorted()
            .collect_vec()
    }

    fn resource_status(&self, resource: &Resource) -> ResourceStatus {
        if resource.sites().iter().any(|s| {
            self.sites_status
                .get(&s.id)
                .is_some_and(|s| *s == ResourceStatus::Online)
        }) {
            return ResourceStatus::Online;
        }

        if resource.sites().iter().all(|s| {
            self.sites_status
                .get(&s.id)
                .is_some_and(|s| *s == ResourceStatus::Offline)
        }) {
            return ResourceStatus::Offline;
        }

        ResourceStatus::Unknown
    }

    pub fn set_resource_offline(&mut self, id: ResourceId) {
        let Some(resource) = self.resources_by_id.get(&id).cloned() else {
            return;
        };

        for Site { id, .. } in resource.sites() {
            self.sites_status.insert(*id, ResourceStatus::Offline);
        }

        self.on_connection_failed(id);
        self.resource_list.update(self.resources());
    }

    pub(crate) fn public_key(&self) -> PublicKey {
        self.node.public_key()
    }

    pub fn shut_down(&mut self, now: Instant) {
        tracing::info!("Initiating graceful shutdown");

        self.peers.clear();
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
        // Organise all buffered packets by gateway + domain.
        let mut buffered_packets_by_gateway_and_domain = buffered_packets
            .map(|packet| {
                let (domain, resource) = self
                    .stub_resolver
                    .resolve_resource_by_ip(&packet.destination())
                    .context("IP is not associated with a DNS resource domain")?;
                let gateway_id = self
                    .authorized_resources
                    .get(resource)
                    .context("No gateway for resource")?;

                anyhow::Ok((*gateway_id, domain, packet))
            })
            .filter_map(|res| {
                res.inspect_err(|e| tracing::debug!("Dropping buffered packet: {e}"))
                    .ok()
            })
            .fold(
                BTreeMap::<_, VecDeque<IpPacket>>::new(),
                |mut map, (gid, domain, packet)| {
                    map.entry((gid, domain)).or_default().push_back(packet);

                    map
                },
            );

        for (domain, rid, proxy_ips, gid) in
            self.stub_resolver
                .resolved_resources()
                .map(|(domain, resource, proxy_ips)| {
                    let gateway = self.authorized_resources.get(resource);

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

            let packets_for_domain = buffered_packets_by_gateway_and_domain
                .remove(&(*gid, domain))
                .unwrap_or_default();

            match self.dns_resource_nat.update(
                domain.clone(),
                *gid,
                *rid,
                proxy_ips,
                packets_for_domain,
                now,
            ) {
                Ok(()) => {}
                Err(e) => {
                    tracing::warn!("Failed to update DNS resource NAT state: {e:#}");
                    continue;
                }
            }

            self.peers
                .add_ips_with_resource(gid, proxy_ips.clone(), rid);
        }
    }

    fn is_cidr_resource_connected(&self, resource: &ResourceId) -> bool {
        let Some(gateway_id) = self.authorized_resources.get(resource) else {
            return false;
        };

        self.peers.get(gateway_id).is_some()
    }

    /// Handles packets received on the TUN device.
    ///
    /// Most of these packets will be application traffic that needs to be encrypted and sent through a WireGuard tunnel.
    /// Some of it may be processed directly, for example DNS queries.
    /// In that case, this function will return `None` and you should call [`ClientState::handle_timeout`] next to fully advance the internal state.
    pub(crate) fn handle_tun_input(
        &mut self,
        packet: IpPacket,
        now: Instant,
    ) -> Option<snownet::Transmit> {
        if packet.is_fz_p2p_control() {
            tracing::warn!("Packet matches heuristics of FZ p2p control protocol");
        }

        if is_definitely_not_a_resource(packet.destination()) {
            return None;
        }

        let tun_config = self.tun_config.current()?;

        if !tun_config.ip.is_ip(packet.source()) {
            tracing::debug!(?packet, "Dropping packet with bad source IP");

            return None;
        }

        let non_dns_packet = match self.try_handle_dns(packet, now) {
            ControlFlow::Break(()) => return None,
            ControlFlow::Continue(non_dns_packet) => non_dns_packet,
        };

        self.encapsulate(non_dns_packet, now)
    }

    /// Handles UDP packets received on the network interface.
    ///
    /// Most of these packets will be WireGuard encrypted IP packets and will thus yield an [`IpPacket`].
    /// Some of them will however be handled internally, for example, TURN control packets exchanged with relays.
    ///
    /// In case this function returns `None`, you should call [`ClientState::handle_timeout`] next to fully advance the internal state.
    pub(crate) fn handle_network_input(
        &mut self,
        local: SocketAddr,
        from: SocketAddr,
        packet: &[u8],
        now: Instant,
    ) -> Option<IpPacket> {
        let (gid, packet) = self.node.decapsulate(
            local,
            from,
            packet.as_ref(),
            now,
        )
        .inspect_err(|e| tracing::debug!(%local, %from, num_bytes = %packet.len(), "Failed to decapsulate: {e:#}"))
        .ok()??;

        if self.udp_dns_client.accepts(&packet) {
            self.udp_dns_client.handle_inbound(packet);
            return None;
        }

        if self.tcp_dns_client.accepts(&packet) {
            self.tcp_dns_client.handle_inbound(packet);
            return None;
        }

        if let Some(fz_p2p_control) = packet.as_fz_p2p_control() {
            match fz_p2p_control.event_type() {
                p2p_control::DOMAIN_STATUS_EVENT => {
                    let res = p2p_control::dns_resource_nat::decode_domain_status(fz_p2p_control)
                        .inspect_err(|e| tracing::debug!("{e:#}"))
                        .ok()?;

                    let buffered_packets = self.dns_resource_nat.on_domain_status(gid, res);

                    for packet in buffered_packets {
                        encapsulate_and_buffer(
                            packet,
                            gid,
                            now,
                            &mut self.node,
                            &mut self.buffered_transmits,
                        );
                    }
                }
                p2p_control::GOODBYE_EVENT => {
                    self.node.remove_connection(gid, "received `goodbye`", now);
                    self.cleanup_connected_gateway(&gid);
                }
                code => {
                    tracing::debug!(code = %code.into_u8(), "Unknown control protocol");
                }
            };

            return None;
        }

        let Some(peer) = self.peers.get_mut(&gid) else {
            tracing::error!(%gid, "Couldn't find connection by ID");

            return None;
        };

        peer.ensure_allowed_src(&packet)
            .inspect_err(|e| tracing::debug!(%gid, %local, %from, "{e}"))
            .ok()?;

        if feature_flags::icmp_error_unreachable_prohibited_create_new_flow()
            && let Ok(Some((failed_packet, error))) = packet.icmp_error()
            && error.is_unreachable_prohibited()
            && let Some(resource) = self.get_resource_by_destination(failed_packet.dst())
        {
            analytics::feature_flag_called("icmp-error-unreachable-prohibited-create-new-flow");

            self.on_not_connected_resource(
                resource,
                ConnectionTrigger::IcmpDestinationUnreachableProhibited,
                now,
            );
        }

        Some(packet)
    }

    pub(crate) fn handle_dns_response(&mut self, response: dns::RecursiveResponse, now: Instant) {
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

        match response.transport {
            dns::Transport::Udp => {
                self.buffered_packets.extend(into_udp_dns_packet(
                    response.local,
                    response.remote,
                    message,
                ));
            }
            dns::Transport::Tcp => {
                unwrap_or_warn!(
                    self.tcp_dns_server
                        .send_message(response.local, response.remote, message),
                    "Failed to send TCP DNS response: {}"
                );
            }
        }
    }

    fn encapsulate(&mut self, mut packet: IpPacket, now: Instant) -> Option<snownet::Transmit> {
        let dst = packet.destination();

        let peer = if is_peer(dst) {
            let Some(peer) = self.peers.peer_by_ip_mut(dst) else {
                tracing::trace!(?packet, "Unknown peer");
                return None;
            };

            peer
        } else {
            let Some(resource) = self.get_resource_by_destination(dst) else {
                tracing::trace!(?packet, "Unknown resource");
                return None;
            };

            let Some(peer) =
                peer_by_resource_mut(&self.authorized_resources, &mut self.peers, resource)
            else {
                self.on_not_connected_resource(resource, packet, now);
                return None;
            };

            peer
        };

        // TODO: Check DNS resource NAT state for the domain that the destination IP belongs to.
        // Re-send if older than X.

        if let Some((domain, _)) = self.stub_resolver.resolve_resource_by_ip(&dst) {
            packet = self
                .dns_resource_nat
                .handle_outgoing(peer.id(), domain, packet, now)?;
        }

        let gid = peer.id();

        let transmit = self
            .node
            .encapsulate(gid, &packet, now)
            .inspect_err(|e| tracing::debug!(%gid, "Failed to encapsulate: {e:#}"))
            .ok()??;

        Some(transmit)
    }

    pub fn add_ice_candidate(
        &mut self,
        conn_id: GatewayId,
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
        conn_id: GatewayId,
        ice_candidate: IceCandidate,
        now: Instant,
    ) {
        self.node
            .remove_remote_candidate(conn_id, ice_candidate.into(), now);
        self.node.handle_timeout(now);
        self.drain_node_events();
    }

    #[tracing::instrument(level = "debug", skip_all, fields(%rid))]
    pub fn handle_flow_created(
        &mut self,
        rid: ResourceId,
        gid: GatewayId,
        gateway_key: PublicKey,
        gateway_tun: IpConfig,
        site_id: SiteId,
        preshared_key: SecretKey,
        client_ice: IceCredentials,
        gateway_ice: IceCredentials,
        now: Instant,
    ) -> anyhow::Result<Result<(), NoTurnServers>> {
        tracing::debug!(%gid, "New flow authorized for resource");

        let resource = self.resources_by_id.get(&rid).context("Unknown resource")?;

        let Some(pending_flow) = self.pending_flows.remove(&rid) else {
            tracing::debug!("No pending flow");

            return Ok(Ok(()));
        };

        match self.node.upsert_connection(
            gid,
            gateway_key,
            x25519::StaticSecret::from(preshared_key.expose_secret().0),
            snownet::Credentials {
                username: client_ice.username,
                password: client_ice.password,
            },
            snownet::Credentials {
                username: gateway_ice.username,
                password: gateway_ice.password,
            },
            now,
        ) {
            Ok(()) => {}
            Err(e) => return Ok(Err(e)),
        };
        self.authorized_resources.insert(rid, gid);
        self.gateways_by_site
            .entry(site_id)
            .or_default()
            .insert(gid);

        if self.peers.get(&gid).is_none() {
            self.peers
                .insert(GatewayOnClient::new(gid, gateway_tun), &[]);
        };

        // Allow looking up the Gateway via its TUN IP.
        // Resources are not allowed to be in our CG-NAT range, therefore in practise this cannot overlap with resources.
        self.peers.add_ip(&gid, &gateway_tun.v4.into());
        self.peers.add_ip(&gid, &gateway_tun.v6.into());

        // Deal with buffered packets

        let (buffered_resource_packets, dns_queries) = pending_flow.into_buffered_packets();

        // 1. Buffered packets for resources
        match resource {
            Resource::Cidr(_) | Resource::Internet(_) => {
                self.peers
                    .add_ips_with_resource(&gid, resource.addresses(), &rid);

                // For CIDR and Internet resources, we can directly queue the buffered packets.
                for packet in buffered_resource_packets {
                    encapsulate_and_buffer(
                        packet,
                        gid,
                        now,
                        &mut self.node,
                        &mut self.buffered_transmits,
                    );
                }
            }
            Resource::Dns(_) => {
                self.update_dns_resource_nat(now, buffered_resource_packets.into_iter())
            }
        }

        // If we are making this connection because we want to send a DNS query to the Gateway,
        // mark it as "used" through the DNS resource ID.
        if !dns_queries.is_empty() {
            self.peers.add_ips_with_resource(
                &gid,
                [
                    IpNetwork::from(gateway_tun.v4),
                    IpNetwork::from(gateway_tun.v6),
                ],
                &rid,
            );
        }

        // 2. Buffered UDP DNS queries for the Gateway
        for query in dns_queries {
            let gateway = self.peers.get(&gid).context("Unknown peer")?; // If this error happens we have a bug: We just inserted it above.

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

    /// For DNS queries to IPs that are a CIDR resources we want to mangle and forward to the gateway that handles that resource.
    ///
    /// We only want to do this if the upstream DNS server is set by the portal, otherwise, the server might be a local IP.
    fn should_forward_dns_query_to_gateway(
        &self,
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

        self.active_cidr_resources
            .longest_match(server.ip())
            .is_some()
            .then_some(*server)
    }

    /// Handles UDP & TCP packets targeted at our stub resolver.
    fn try_handle_dns(&mut self, packet: IpPacket, now: Instant) -> ControlFlow<(), IpPacket> {
        let dst = packet.destination();

        if is_llmnr(dst) {
            self.handle_llmnr_dns_query(packet, now);
            return ControlFlow::Break(());
        }

        let Some(upstream) = self.dns_config.mapping().upstream_by_sentinel(dst) else {
            return ControlFlow::Continue(packet); // Not for our DNS resolver.
        };

        if self.tcp_dns_server.accepts(&packet) {
            self.tcp_dns_server.handle_inbound(packet);
            return ControlFlow::Break(());
        }

        self.handle_udp_dns_query(upstream, packet, now);

        ControlFlow::Break(())
    }

    pub fn on_connection_failed(&mut self, resource: ResourceId) {
        self.pending_flows.remove(&resource);
        let Some(disconnected_gateway) = self.authorized_resources.remove(&resource) else {
            return;
        };
        self.cleanup_connected_gateway(&disconnected_gateway);
    }

    fn preferred_gateways(&self, resource: ResourceId) -> Vec<GatewayId> {
        #[expect(clippy::disallowed_methods, reason = "We are sorting anyway")]
        self.gateways_by_site
            .values()
            .flatten()
            .copied()
            .unique()
            .sorted_by(|left, right| {
                let prefer_authorized = self
                    .authorized_resources
                    .get(&resource)
                    .map(|g| match g {
                        g if g == left => Ordering::Less,
                        g if g == right => Ordering::Greater,
                        _ => Ordering::Equal,
                    })
                    .unwrap_or(Ordering::Equal);
                let prefer_connected = match (self.peers.get(left), self.peers.get(right)) {
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
        self.authorized_resources.get(resource).copied()
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

        let resource = self.internet_resource();

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
    fn cleanup_connected_gateway(&mut self, disconnected_gateway: &GatewayId) {
        self.update_site_status_by_gateway(disconnected_gateway, ResourceStatus::Unknown);
        self.peers.remove(disconnected_gateway);
        self.authorized_resources
            .retain(|_, g| g != disconnected_gateway);
        self.dns_resource_nat.clear_by_gateway(disconnected_gateway);
    }

    fn routes(&self) -> impl Iterator<Item = IpNetwork> + '_ {
        self.active_cidr_resources
            .iter()
            .map(|(ip, _)| ip)
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

    fn get_resource_by_destination(&self, destination: IpAddr) -> Option<ResourceId> {
        // We need to filter disabled resources because we never remove resources from the stub_resolver
        let maybe_dns_resource_id = self
            .stub_resolver
            .resolve_resource_by_ip(&destination)
            .map(|(_, r)| *r)
            .inspect(
                |rid| tracing::trace!(target: "tunnel_test_coverage", %destination, %rid, "Packet for DNS resource"),
            );

        // We don't need to filter from here because resources are removed from the active_cidr_resources as soon as they are disabled.
        let maybe_cidr_resource_id = self
            .active_cidr_resources
            .longest_match(destination)
            .map(|(_, res)| res.id)
            .inspect(
                |rid| tracing::trace!(target: "tunnel_test_coverage", %destination, %rid, "Packet for CIDR resource"),
            );

        let maybe_internet_resource = self.active_internet_resource()
            .map(|r| r.id)
            .inspect(|rid| {
                tracing::trace!(target: "tunnel_test_coverage", %destination, %rid, "Packet for Internet resource")
            });

        maybe_dns_resource_id
            .or(maybe_cidr_resource_id)
            .or(maybe_internet_resource)
    }

    fn active_internet_resource(&self) -> Option<&InternetResource> {
        if !self.is_internet_resource_active {
            return None;
        }

        self.internet_resource()
    }

    fn internet_resource(&self) -> Option<&InternetResource> {
        self.resources_by_id.values().find_map(|r| match r {
            Resource::Dns(_) => None,
            Resource::Cidr(_) => None,
            Resource::Internet(internet_resource) => Some(internet_resource),
        })
    }

    /// Update our list of known system DNS resolvers.
    ///
    /// Returns back the list of resolvers, sanitized from all unusable servers,
    /// i.e. all servers within the sentinel DNS range.
    ///
    /// Note: The returned list is not necessarily the list of DNS resolvers that is active.
    /// If DNS servers are defined in the portal, those will be preferred over the system defined ones.
    pub(crate) fn update_system_resolvers(&mut self, new_dns: Vec<IpAddr>) -> Vec<IpAddr> {
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
                ipv4_routes: existing.ipv4_routes.clone(),
                ipv6_routes: existing.ipv6_routes.clone(),
            })
            .unwrap_or_else(|| {
                let (ipv4_routes, ipv6_routes) = self.routes().partition_map(|route| match route {
                    IpNetwork::V4(v4) => itertools::Either::Left(v4),
                    IpNetwork::V6(v6) => itertools::Either::Right(v6),
                });

                TunConfig {
                    ip: IpConfig {
                        v4: config.ipv4,
                        v6: config.ipv6,
                    },
                    dns_by_sentinel: self.dns_config.mapping(),
                    search_domain: config.search_domain.clone(),
                    ipv4_routes,
                    ipv6_routes,
                }
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
            .chain(self.node.poll_timeout())
            .min_by_key(|(instant, _)| *instant)
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.node.handle_timeout(now);
        self.drain_node_events();

        self.advance_dns_clients_and_servers(now);
        self.send_dns_resource_nat_packets(now);

        self.dns_cache.handle_timeout(now);
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
                let Some(transmit) = self.encapsulate(packet, now) else {
                    continue;
                };

                self.buffered_transmits.push_back(transmit);
                continue;
            }

            // Check if the UDP DNS client has assembled a response to a query.
            if let Some(query_result) = self.udp_dns_client.poll_query_result() {
                let server = query_result.server;
                let qid = query_result.query.id();
                let known_sockets = &mut self.dns_streams_by_local_upstream_and_query_id;

                let Some((local, remote)) =
                    known_sockets.remove(&(dns::Transport::Udp, query_result.local, server, qid))
                else {
                    tracing::warn!(?known_sockets, %server, %qid, "Failed to find UDP socket handle for query result");

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
                    },
                    now,
                );
                continue;
            }

            // Check if the TCP DNS client has assembled a response to a query.
            if let Some(query_result) = self.tcp_dns_client.poll_query_result() {
                let server = query_result.server;
                let qid = query_result.query.id();
                let known_sockets = &mut self.dns_streams_by_local_upstream_and_query_id;

                let Some((local, remote)) =
                    known_sockets.remove(&(dns::Transport::Tcp, query_result.local, server, qid))
                else {
                    tracing::warn!(?known_sockets, %server, %qid, "Failed to find TCP socket handle for query result");

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
                    },
                    now,
                );
                continue;
            }

            break;
        }
    }

    fn send_dns_resource_nat_packets(&mut self, now: Instant) {
        while let Some((gid, domain, packet)) = self.dns_resource_nat.poll_packet() {
            tracing::debug!(%gid, %domain, "Setting up DNS resource NAT");

            encapsulate_and_buffer(
                packet,
                gid,
                now,
                &mut self.node,
                &mut self.buffered_transmits,
            );
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

        match self.stub_resolver.handle(&message) {
            dns::ResolveStrategy::LocalResponse(response) => {
                if response.response_code() == ResponseCode::NXDOMAIN
                    && telemetry::feature_flags::drop_llmnr_nxdomain_responses()
                {
                    return;
                }

                self.dns_resource_nat.recreate(message.domain());
                self.update_dns_resource_nat(now, iter::empty());

                let maybe_packet = ip_packet::make::udp_packet(
                    packet.destination(),
                    packet.source(),
                    datagram.destination_port(),
                    datagram.source_port(),
                    response.into_bytes(MAX_UDP_PAYLOAD),
                )
                .inspect_err(|e| {
                    tracing::debug!("Failed to create LLMNR DNS response packet: {e:#}");
                })
                .ok();

                self.buffered_packets.extend(maybe_packet);
            }
            dns::ResolveStrategy::RecurseLocal => {
                tracing::trace!("LLMNR queries are not forwarded to upstream resolvers");
            }
            dns::ResolveStrategy::RecurseSite(_) => {
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

        match self.stub_resolver.handle(&message) {
            dns::ResolveStrategy::LocalResponse(response) => {
                self.dns_resource_nat.recreate(message.domain());
                self.update_dns_resource_nat(now, iter::empty());
                self.dns_cache.insert(message.domain(), &response, now);

                return Some(response);
            }
            dns::ResolveStrategy::RecurseLocal => {
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
            dns::ResolveStrategy::RecurseSite(resource) => {
                let Some(gateway) =
                    peer_by_resource_mut(&self.authorized_resources, &mut self.peers, resource)
                else {
                    self.on_not_connected_resource(
                        resource,
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
            dns::Transport::Udp => self.udp_dns_client.send_query(server, query.clone(), now),
            dns::Transport::Tcp => self.tcp_dns_client.send_query(server, query.clone()),
        };

        let local_socket = match result {
            Ok(local_socket) => local_socket,
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

        tracing::trace!(%local_socket, %server, %local, %query_id, "Forwarded {transport} DNS query via tunnel");

        let existing = self
            .dns_streams_by_local_upstream_and_query_id
            .insert((transport, local_socket, server, query_id), (local, remote));

        if let Some((existing_local, existing_remote)) = existing
            && (existing_local != local || existing_remote != remote)
        {
            debug_assert!(false, "Query IDs should be unique");
        }
    }

    fn maybe_update_tun_routes(&mut self) {
        let Some(config) = self.tun_config.current() else {
            return;
        };

        let (ipv4_routes, ipv6_routes) = self.routes().partition_map(|route| match route {
            IpNetwork::V4(v4) => itertools::Either::Left(v4),
            IpNetwork::V6(v6) => itertools::Either::Right(v6),
        });

        let new_tun_config = TunConfig {
            ipv4_routes,
            ipv6_routes,
            ..config.clone()
        };

        self.maybe_update_tun_config(new_tun_config);
    }

    fn recalculate_active_cidr_resources(&self) -> IpNetworkTable<CidrResource> {
        let mut active_cidr_resources = IpNetworkTable::<CidrResource>::new();

        for resource in self.resources_by_id.values() {
            let Resource::Cidr(resource) = resource else {
                continue;
            };

            if let Some(active_resource) = active_cidr_resources.exact_match(resource.address)
                && self.is_cidr_resource_connected(&active_resource.id)
            {
                continue;
            }

            active_cidr_resources.insert(resource.address, resource.clone());
        }

        active_cidr_resources
    }

    fn maybe_update_tun_config(&mut self, new_tun_config: TunConfig) {
        if Some(&new_tun_config) == self.tun_config.current() {
            tracing::trace!(current = ?self.tun_config.current(), "TUN device configuration unchanged");

            return;
        }

        self.stub_resolver
            .set_search_domain(new_tun_config.search_domain.clone());
        self.tun_config.update(new_tun_config);

        self.initialise_tcp_dns_client(); // We must reset the TCP DNS client because changed CIDR resources (and thus changed routes) might affect which site we connect to.
        self.initialise_tcp_dns_server();
    }

    fn drain_node_events(&mut self) {
        let mut added_ice_candidates = BTreeMap::<GatewayId, BTreeSet<IceCandidate>>::default();
        let mut removed_ice_candidates = BTreeMap::<GatewayId, BTreeSet<IceCandidate>>::default();

        while let Some(event) = self.node.poll_event() {
            match event {
                snownet::Event::ConnectionFailed(id) | snownet::Event::ConnectionClosed(id) => {
                    self.cleanup_connected_gateway(&id);
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
                snownet::Event::ConnectionEstablished(id) => {
                    self.update_site_status_by_gateway(&id, ResourceStatus::Online);
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

    fn update_site_status_by_gateway(&mut self, gid: &GatewayId, status: ResourceStatus) {
        #[expect(clippy::disallowed_methods, reason = "Iteration order doesn't matter.")]
        let Some((sid, _)) = self
            .gateways_by_site
            .iter()
            .find(|(_, gateways)| gateways.contains(gid))
        else {
            tracing::warn!(%gid, "Cannot update status of unknown site");
            return;
        };

        self.sites_status.insert(*sid, status);
        self.resource_list.update(self.resources());
    }

    pub(crate) fn poll_event(&mut self) -> Option<ClientEvent> {
        if let Some(config) = self.tun_config.take_pending_update() {
            tracing::info!(?config, "Updating TUN device");

            return Some(ClientEvent::TunInterfaceUpdated(config));
        }

        if let Some(resources) = self.resource_list.take_pending_update() {
            tracing::debug!(count = %resources.len(), "Updating resource list");

            return Some(ClientEvent::ResourcesChanged { resources });
        }

        if let Some(resource) = self.pending_flows.poll_connection_intents() {
            return Some(ClientEvent::ConnectionIntent {
                resource,
                preferred_gateways: self.preferred_gateways(resource),
            });
        }

        self.buffered_events
            .pop_front()
            .or_else(|| match self.stub_resolver.poll_event()? {
                dns::Event::RecordsChanged(records) => {
                    Some(ClientEvent::DnsRecordsChanged { records })
                }
            })
    }

    pub(crate) fn reset(&mut self, now: Instant, reason: &str) {
        tracing::info!("Resetting network state ({reason})");

        self.node.reset(now); // Clear all network connections.
        self.peers.clear(); // Clear all state associated with Gateways.

        self.dns_resource_nat.clear(); // Clear all state related to DNS resource NATs.
        self.drain_node_events();

        // Resetting the client will trigger a failed `QueryResult` for each one that is in-progress.
        // Failed queries get translated into `SERVFAIL` responses to the client.
        self.tcp_dns_client.reset();
    }

    pub(crate) fn poll_transmit(&mut self) -> Option<snownet::Transmit> {
        self.buffered_transmits
            .pop_front()
            .or_else(|| self.node.poll_transmit())
    }

    pub(crate) fn poll_dns_queries(&mut self) -> Option<dns::RecursiveQuery> {
        self.buffered_dns_queries.pop_front()
    }

    /// Sets a new set of resources.
    ///
    /// This function does **not** perform a blanket "clear all and set new resources".
    /// Instead, it diffs which resources to remove first and then adds the new ones.
    ///
    /// Removing a resource interrupts routing for all packets, even if the resource is added back right away because [`GatewayOnClient`] tracks the allowed IPs which has to contain the resource ID.
    ///
    /// TODO: Add a test that asserts the above.
    ///       That is tricky because we need to assert on state deleted by [`ClientState::remove_resource`] and check that it did in fact not get deleted.
    pub fn set_resources<R>(&mut self, new_resources: Vec<R>, now: Instant)
    where
        R: TryInto<Resource, Error: std::error::Error>,
    {
        let new_resources = new_resources
            .into_iter()
            .filter_map(|r| r.try_into().inspect_err(|e| tracing::debug!("{e}")).ok())
            .collect::<Vec<_>>();

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
            self.add_resource(resource, now)
        }

        self.active_cidr_resources = self.recalculate_active_cidr_resources();
        self.maybe_update_tun_routes();
        self.resource_list.update(self.resources());
    }

    pub fn add_resource(
        &mut self,
        new_resource: impl TryInto<Resource, Error: std::error::Error>,
        now: Instant,
    ) {
        let new_resource = match new_resource.try_into() {
            Ok(r) => r,
            Err(e) => {
                tracing::debug!("{e}");
                return;
            }
        };

        if let Some(resource) = self.resources_by_id.get(&new_resource.id()) {
            let resource_addressability_changed = resource.has_different_address(&new_resource)
                || resource.has_different_ip_stack(&new_resource)
                || resource.has_different_site(&new_resource);

            if resource_addressability_changed {
                tracing::debug!(rid = %new_resource.id(), "Resource is known but its addressability changed");

                self.remove_resource(resource.id(), now);
            }
        }

        self.resources_by_id
            .insert(new_resource.id(), new_resource.clone());

        let activated = match &new_resource {
            Resource::Dns(dns) => {
                self.stub_resolver
                    .add_resource(dns.id, dns.address.clone(), dns.ip_stack)
            }
            Resource::Cidr(cidr) => {
                let existing = self.active_cidr_resources.exact_match(cidr.address);

                match existing {
                    Some(existing) => {
                        // If we are "activating" the same resource, don't print a log to avoid spam.
                        let is_different = existing.id != cidr.id;

                        // If the current resource is routing traffic, we don't update the routing table, so don't print a log either.
                        // See `recalculate_active_cidr_resources` for details.
                        let existing_is_not_connected =
                            self.is_cidr_resource_connected(&existing.id);

                        is_different && existing_is_not_connected
                    }
                    None => true,
                }
            }
            Resource::Internet(_) => self.is_internet_resource_active,
        };

        if activated {
            self.log_activating_resource(&new_resource);
        }

        if matches!(new_resource, Resource::Cidr(_)) {
            self.active_cidr_resources = self.recalculate_active_cidr_resources();
        }

        self.maybe_update_tun_routes();
        self.resource_list.update(self.resources());
        self.dns_cache.flush("Resource added");
    }

    fn log_activating_resource(&self, resource: &Resource) {
        let name = resource.name();
        let address = resource.address_string().map(tracing::field::display);
        let sites = resource.sites_string();

        tracing::info!(%name, address, %sites, "Activating resource");
    }

    #[tracing::instrument(level = "debug", skip_all, fields(?id))]
    pub fn remove_resource(&mut self, id: ResourceId, now: Instant) {
        self.disable_resource(id, now);

        if self
            .resources_by_id
            .remove(&id)
            .is_some_and(|r| matches!(r, Resource::Cidr(_)))
        {
            self.active_cidr_resources = self.recalculate_active_cidr_resources();
        };

        self.maybe_update_tun_routes();
        self.resource_list.update(self.resources());
        self.dns_cache.flush("Resource removed");
    }

    fn disable_resource(&mut self, id: ResourceId, now: Instant) {
        let Some(resource) = self.resources_by_id.get(&id) else {
            return;
        };

        match resource {
            Resource::Dns(_) => self.stub_resolver.remove_resource(id),
            Resource::Cidr(_) => {}
            Resource::Internet(_) => self.is_internet_resource_active = false,
        }

        let name = resource.name();
        let address = resource.address_string().map(tracing::field::display);
        let sites = resource.sites_string();

        tracing::info!(%name, address, %sites, "Deactivating resource");

        self.pending_flows.remove(&id);

        let Some(peer) = peer_by_resource_mut(&self.authorized_resources, &mut self.peers, id)
        else {
            return;
        };

        // First we remove the id from all allowed ips
        for (_, resources) in peer
            .allowed_ips
            .iter_mut()
            .filter(|(_, resources)| resources.contains(&id))
        {
            resources.remove(&id);

            if !resources.is_empty() {
                continue;
            }
        }

        // We remove all empty allowed ips entry since there's no resource that corresponds to it
        peer.allowed_ips.retain(|_, r| !r.is_empty());

        self.authorized_resources.remove(&id);

        // Clear DNS resource NAT state for all domains resolved for this DNS resource.
        for domain in self
            .stub_resolver
            .resolved_resources()
            .filter_map(|(domain, candidate, _)| (candidate == &id).then_some(domain))
        {
            self.dns_resource_nat.clear_by_domain(domain);
        }

        let unused_gateways = self.peers.extract_if(|_, p| p.allowed_ips.is_empty());

        for (gid, _) in unused_gateways {
            tracing::debug!(%gid, "Disabled / deactivated last resource for peer");

            self.node.close_connection(gid, p2p_control::goodbye(), now);
            self.update_site_status_by_gateway(&gid, ResourceStatus::Unknown);
            self.resource_list.update(self.resources());
        }
    }

    pub fn update_relays(
        &mut self,
        to_remove: BTreeSet<RelayId>,
        to_add: BTreeSet<(RelayId, RelaySocket, String, String, String)>,
        now: Instant,
    ) {
        self.node.update_relays(to_remove, &to_add, now);
        self.drain_node_events(); // Ensure all state changes are fully-propagated.
    }

    fn on_not_connected_resource(
        &mut self,
        resource: ResourceId,
        trigger: impl Into<ConnectionTrigger>,
        now: Instant,
    ) {
        self.pending_flows.on_not_connected_resource(
            resource,
            trigger,
            &self.resources_by_id,
            |s| {
                self.gateways_by_site
                    .get(&s)
                    .into_iter()
                    .flatten()
                    .any(|g| self.peers.get(g).is_some())
            },
            now,
        );
    }
}

fn is_llmnr(dst: IpAddr) -> bool {
    match dst {
        IpAddr::V4(ip) => ip == LLMNR_IPV4,
        IpAddr::V6(ip) => ip == LLMNR_IPV6,
    }
}

fn encapsulate_and_buffer(
    packet: IpPacket,
    gid: GatewayId,
    now: Instant,
    node: &mut ClientNode<GatewayId, RelayId>,
    buffered_transmits: &mut VecDeque<Transmit>,
) {
    let Some(transmit) = node
        .encapsulate(gid, &packet, now)
        .inspect_err(|e| tracing::debug!(%gid, "Failed to encapsulate: {e}"))
        .ok()
        .flatten()
    else {
        return;
    };

    buffered_transmits.push_back(transmit);
}

fn peer_by_resource_mut<'p>(
    resources_gateways: &HashMap<ResourceId, GatewayId>,
    peers: &'p mut PeerStore<GatewayId, GatewayOnClient>,
    resource: ResourceId,
) -> Option<&'p mut GatewayOnClient> {
    let gateway_id = resources_gateways.get(&resource)?;
    let peer = peers.get_mut(gateway_id)?;

    Some(peer)
}

/// Compares the given [`IpAddr`] against a static set of ignored IPs that are definitely not resources.
fn is_definitely_not_a_resource(ip: IpAddr) -> bool {
    /// Source: https://en.wikipedia.org/wiki/Multicast_address#Notable_IPv4_multicast_addresses
    const IPV4_IGMP_MULTICAST: Ipv4Addr = Ipv4Addr::new(224, 0, 0, 22);

    /// Source: <https://en.wikipedia.org/wiki/Multicast_address#Notable_IPv6_multicast_addresses>
    const IPV6_MULTICAST_ALL_ROUTERS: Ipv6Addr = Ipv6Addr::new(0xFF02, 0, 0, 0, 0, 0, 0, 0x0002);

    match ip {
        IpAddr::V4(ip4) => {
            if ip4 == IPV4_IGMP_MULTICAST {
                return true;
            }
        }
        IpAddr::V6(ip6) => {
            if ip6 == IPV6_MULTICAST_ALL_ROUTERS {
                return true;
            }
        }
    }

    false
}

fn into_udp_dns_packet(
    from: SocketAddr,
    dst: SocketAddr,
    message: dns_types::Response,
) -> Option<IpPacket> {
    ip_packet::make::udp_packet(
        from.ip(),
        dst.ip(),
        from.port(),
        dst.port(),
        message.into_bytes(MAX_UDP_PAYLOAD),
    )
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
mod tests {
    use super::*;

    #[test]
    fn ignores_ip4_igmp_multicast() {
        assert!(is_definitely_not_a_resource(ip("224.0.0.22")))
    }

    #[test]
    fn ignores_ip6_multicast_all_routers() {
        assert!(is_definitely_not_a_resource(ip("ff02::2")))
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
        state.peers.insert(peer(GatewayId::from_u128(30)), &[]);

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
        state.peers.insert(peer(GatewayId::from_u128(30)), &[]);
        state
            .authorized_resources
            .insert(ResourceId::from_u128(100), GatewayId::from_u128(30));

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

    fn ip(addr: &str) -> IpAddr {
        addr.parse().unwrap()
    }

    fn peer(id: GatewayId) -> GatewayOnClient {
        GatewayOnClient::new(
            id,
            IpConfig {
                v4: Ipv4Addr::LOCALHOST,
                v6: Ipv6Addr::LOCALHOST,
            },
        )
    }
}

#[cfg(all(test, feature = "proptest"))]
mod proptests {
    use std::collections::HashSet;

    use super::*;
    use crate::proptest::*;
    use connlib_model::ResourceView;
    use prop::collection;
    use proptest::prelude::*;
    use resource::DnsResource;

    #[test_strategy::proptest]
    fn cidr_resources_are_turned_into_routes(
        #[strategy(cidr_resource())] resource1: CidrResource,
        #[strategy(cidr_resource())] resource2: CidrResource,
    ) {
        let mut client_state = ClientState::for_test();

        client_state.add_resource(Resource::Cidr(resource1.clone()), Instant::now());
        client_state.add_resource(Resource::Cidr(resource2.clone()), Instant::now());

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

        client_state.add_resource(Resource::Cidr(resource1.clone()), Instant::now());
        client_state.add_resource(Resource::Dns(resource2.clone()), Instant::now());

        assert_eq!(
            hashset(client_state.resources()),
            hashset([
                ResourceView::Cidr(resource1.clone().with_status(ResourceStatus::Unknown)),
                ResourceView::Dns(resource2.clone().with_status(ResourceStatus::Unknown))
            ])
        );

        client_state.add_resource(Resource::Cidr(resource3.clone()), Instant::now());

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
        client_state.add_resource(Resource::Cidr(resource.clone()), Instant::now());

        let updated_resource = CidrResource {
            address: new_address,
            ..resource
        };

        client_state.add_resource(Resource::Cidr(updated_resource.clone()), Instant::now());

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
    fn adding_cidr_resource_with_same_id_as_dns_resource_replaces_dns_resource(
        #[strategy(dns_resource())] resource: DnsResource,
        #[strategy(any_ip_network(8))] address: IpNetwork,
    ) {
        let mut client_state = ClientState::for_test();
        client_state.add_resource(Resource::Dns(resource.clone()), Instant::now());

        let dns_as_cidr_resource = CidrResource {
            address,
            id: resource.id,
            name: resource.name,
            address_description: resource.address_description,
            sites: resource.sites,
        };

        client_state.add_resource(Resource::Cidr(dns_as_cidr_resource.clone()), Instant::now());

        assert_eq!(
            hashset(client_state.resources()),
            hashset([ResourceView::Cidr(
                dns_as_cidr_resource.with_status(ResourceStatus::Unknown)
            )])
        );
        assert_eq!(
            hashset(client_state.routes()),
            expected_routes(vec![address])
        );
    }

    #[test_strategy::proptest]
    fn resources_can_be_removed(
        #[strategy(dns_resource())] dns_resource: DnsResource,
        #[strategy(cidr_resource())] cidr_resource: CidrResource,
    ) {
        let mut client_state = ClientState::for_test();
        client_state.add_resource(Resource::Dns(dns_resource.clone()), Instant::now());
        client_state.add_resource(Resource::Cidr(cidr_resource.clone()), Instant::now());

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
        client_state.add_resource(Resource::Dns(dns_resource1), Instant::now());
        client_state.add_resource(Resource::Cidr(cidr_resource1), Instant::now());

        client_state.set_resources(
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
            client_state.add_resource(r.clone(), Instant::now())
        }

        let first_resource = resources_online.first().unwrap();
        client_state
            .authorized_resources
            .insert(first_resource.id(), gateway);
        client_state.gateways_by_site.insert(
            first_resource.sites().iter().next().unwrap().id,
            HashSet::from([gateway]),
        );

        client_state.update_site_status_by_gateway(&gateway, ResourceStatus::Online);

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
            client_state.add_resource(r.clone(), Instant::now());
        }
        let first_resources = resources.first().unwrap();
        client_state
            .authorized_resources
            .insert(first_resources.id(), gateway);
        client_state.gateways_by_site.insert(
            first_resources.sites().iter().next().unwrap().id,
            HashSet::from([gateway]),
        );

        client_state.update_site_status_by_gateway(&gateway, ResourceStatus::Online);
        client_state.update_site_status_by_gateway(&gateway, ResourceStatus::Unknown);

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
        client_state.add_resource(single_site_resource.clone(), Instant::now());
        for r in &multi_site_resources {
            client_state.add_resource(r.clone(), Instant::now());
        }

        client_state.set_resource_offline(single_site_resource.id());

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
