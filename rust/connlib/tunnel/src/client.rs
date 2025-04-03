mod resource;

use dns_types::{DomainName, ResponseCode};
pub(crate) use resource::{CidrResource, Resource};
#[cfg(all(feature = "proptest", test))]
pub(crate) use resource::{DnsResource, InternetResource};
use ringbuffer::{AllocRingBuffer, RingBuffer};

use crate::dns::StubResolver;
use crate::expiring_map::ExpiringMap;
use crate::messages::{DnsServer, Interface as InterfaceConfig, IpDnsServer};
use crate::messages::{IceCredentials, SecretKey};
use crate::peer_store::PeerStore;
use crate::unique_packet_buffer::UniquePacketBuffer;
use crate::{IPV4_TUNNEL, IPV6_TUNNEL, IpConfig, TunConfig, dns, is_peer, p2p_control};
use anyhow::Context;
use bimap::BiMap;
use connlib_model::{GatewayId, PublicKey, RelayId, ResourceId, ResourceStatus, ResourceView};
use connlib_model::{Site, SiteId};
use firezone_logging::{err_with_src, telemetry_event, unwrap_or_debug, unwrap_or_warn};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_network_table::IpNetworkTable;
use ip_packet::{IpPacket, MAX_UDP_PAYLOAD};
use itertools::Itertools;

use crate::ClientEvent;
use crate::peer::GatewayOnClient;
use lru::LruCache;
use secrecy::{ExposeSecret as _, Secret};
use snownet::{ClientNode, NoTurnServers, RelaySocket, Transmit};
use std::collections::hash_map::Entry;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::num::NonZeroUsize;
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

// The max time a dns request can be configured to live in resolvconf
// is 30 seconds. See resolvconf(5) timeout.
const IDS_EXPIRE: std::time::Duration = std::time::Duration::from_secs(60);

/// How many gateways we at most remember that we connected to.
///
/// 100 has been chosen as a pretty arbitrary value.
/// We only store [`GatewayId`]s so the memory footprint is negligible.
const MAX_REMEMBERED_GATEWAYS: NonZeroUsize = NonZeroUsize::new(100).expect("100 > 0");

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
    pending_flows: HashMap<ResourceId, PendingFlow>,
    /// Tracks the domains for which we have set up a NAT per gateway.
    ///
    /// The IPs for DNS resources get assigned on the client.
    /// In order to route them to the actual resource, the gateway needs to set up a NAT table.
    /// Until the NAT is set up, packets sent to these resources are effectively black-holed.
    dns_resource_nat_by_gateway: BTreeMap<(GatewayId, DomainName), DnsResourceNatState>,
    /// Tracks which gateway to use for a particular Resource.
    resources_gateways: HashMap<ResourceId, GatewayId>,
    /// The site a gateway belongs to.
    gateways_site: HashMap<GatewayId, SiteId>,
    /// The online/offline status of a site.
    sites_status: HashMap<SiteId, ResourceStatus>,

    /// All CIDR resources we know about, indexed by the IP range they cover (like `1.1.0.0/8`).
    active_cidr_resources: IpNetworkTable<CidrResource>,
    /// `Some` if the Internet resource is enabled.
    internet_resource: Option<ResourceId>,
    /// All resources indexed by their ID.
    resources_by_id: BTreeMap<ResourceId, Resource>,

    /// The DNS resolvers configured on the system outside of connlib.
    system_resolvers: Vec<IpAddr>,
    /// The DNS resolvers configured in the portal.
    ///
    /// Has priority over system-configured DNS servers.
    upstream_dns: Vec<DnsServer>,

    /// Maps from connlib-assigned IP of a DNS server back to the originally configured system DNS resolver.
    dns_mapping: BiMap<IpAddr, DnsServer>,
    /// UDP DNS queries that had their destination IP mangled to redirect them to another DNS resolver through the tunnel.
    udp_dns_sockets_by_upstream_and_query_id: ExpiringMap<(SocketAddr, u16), SocketAddr>,
    /// Manages internal dns records and emits forwarding event when not internally handled
    stub_resolver: StubResolver,

    /// Configuration of the TUN device, when it is up.
    tun_config: Option<TunConfig>,

    /// Resources that have been disabled by the UI
    disabled_resources: BTreeSet<ResourceId>,

    tcp_dns_client: dns_over_tcp::Client,
    tcp_dns_server: dns_over_tcp::Server,
    /// Tracks the TCP stream (i.e. socket-pair) on which we received a TCP DNS query by the ID of the recursive DNS query we issued.
    tcp_dns_streams_by_upstream_and_query_id: HashMap<(SocketAddr, u16), (SocketAddr, SocketAddr)>,

    /// Stores the gateways we recently connected to.
    ///
    /// We use this as a hint to the portal to re-connect us to the same gateway for a resource.
    recently_connected_gateways: LruCache<GatewayId, ()>,

    buffered_events: VecDeque<ClientEvent>,
    buffered_packets: VecDeque<IpPacket>,
    buffered_transmits: VecDeque<Transmit<'static>>,
    buffered_dns_queries: VecDeque<dns::RecursiveQuery>,
}

enum DnsResourceNatState {
    Pending {
        sent_at: Instant,
        buffered_packets: UniquePacketBuffer,
    },
    Confirmed,
}

impl DnsResourceNatState {
    fn num_buffered_packets(&self) -> usize {
        match self {
            DnsResourceNatState::Pending {
                buffered_packets, ..
            } => buffered_packets.len(),
            DnsResourceNatState::Confirmed => 0,
        }
    }

    fn confirm(&mut self) -> impl Iterator<Item = IpPacket> + use<> {
        let buffered_packets = match std::mem::replace(self, DnsResourceNatState::Confirmed) {
            DnsResourceNatState::Pending {
                buffered_packets, ..
            } => Some(buffered_packets.into_iter()),
            DnsResourceNatState::Confirmed => None,
        };

        buffered_packets.into_iter().flatten()
    }
}

struct PendingFlow {
    last_intent_sent_at: Instant,
    resource_packets: UniquePacketBuffer,
    udp_dns_queries: AllocRingBuffer<IpPacket>,
    tcp_dns_queries: AllocRingBuffer<dns_over_tcp::Query>,
}

impl PendingFlow {
    /// How many packets we will at most buffer in a [`PendingFlow`].
    ///
    /// `PendingFlow`s are per _resource_ (which could be Internet Resource or wildcard DNS resources).
    /// Thus, we may receive a fair few packets before we can send them.
    const CAPACITY_POW_2: usize = 7; // 2^7 = 128

    fn new(now: Instant, trigger: ConnectionTrigger) -> Self {
        let mut this = Self {
            last_intent_sent_at: now,
            resource_packets: UniquePacketBuffer::with_capacity_power_of_2(Self::CAPACITY_POW_2),
            udp_dns_queries: AllocRingBuffer::with_capacity_power_of_2(Self::CAPACITY_POW_2),
            tcp_dns_queries: AllocRingBuffer::with_capacity_power_of_2(Self::CAPACITY_POW_2),
        };
        this.push(trigger);

        this
    }

    fn push(&mut self, trigger: ConnectionTrigger) {
        match trigger {
            ConnectionTrigger::PacketForResource(packet) => {
                self.resource_packets.push(packet);
            }
            ConnectionTrigger::UdpDnsQueryForSite(packet) => self.udp_dns_queries.push(packet),
            ConnectionTrigger::TcpDnsQueryForSite(query) => self.tcp_dns_queries.push(query),
        }
    }
}

impl ClientState {
    pub(crate) fn new(seed: [u8; 32], now: Instant) -> Self {
        Self {
            resources_gateways: Default::default(),
            active_cidr_resources: IpNetworkTable::new(),
            resources_by_id: Default::default(),
            peers: Default::default(),
            dns_mapping: Default::default(),
            buffered_events: Default::default(),
            tun_config: Default::default(),
            buffered_packets: Default::default(),
            node: ClientNode::new(seed, now),
            system_resolvers: Default::default(),
            sites_status: Default::default(),
            gateways_site: Default::default(),
            udp_dns_sockets_by_upstream_and_query_id: Default::default(),
            stub_resolver: Default::default(),
            disabled_resources: Default::default(),
            buffered_transmits: Default::default(),
            internet_resource: None,
            recently_connected_gateways: LruCache::new(MAX_REMEMBERED_GATEWAYS),
            upstream_dns: Default::default(),
            buffered_dns_queries: Default::default(),
            tcp_dns_client: dns_over_tcp::Client::new(now, seed),
            tcp_dns_server: dns_over_tcp::Server::new(now),
            tcp_dns_streams_by_upstream_and_query_id: Default::default(),
            pending_flows: Default::default(),
            dns_resource_nat_by_gateway: BTreeMap::new(),
        }
    }

    #[cfg(all(test, feature = "proptest"))]
    pub(crate) fn tunnel_ip_config(&self) -> Option<crate::IpConfig> {
        Some(self.tun_config.as_ref()?.ip)
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
        self.emit_resources_changed();
    }

    pub(crate) fn public_key(&self) -> PublicKey {
        self.node.public_key()
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
                    .resources_gateways
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

        use std::collections::btree_map::Entry;

        for (domain, rid, proxy_ips, gid) in
            self.stub_resolver
                .resolved_resources()
                .map(|(domain, resource, proxy_ips)| {
                    let gateway = self.resources_gateways.get(resource);

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

            match self
                .dns_resource_nat_by_gateway
                .entry((*gid, domain.clone()))
            {
                Entry::Vacant(v) => {
                    self.peers
                        .add_ips_with_resource(gid, proxy_ips.iter().copied(), rid);
                    let mut buffered_packets = UniquePacketBuffer::with_capacity_power_of_2(5); // 2^5 = 32
                    buffered_packets.extend(packets_for_domain);

                    v.insert(DnsResourceNatState::Pending {
                        sent_at: now,
                        buffered_packets,
                    });
                }
                Entry::Occupied(mut o) => match o.get_mut() {
                    DnsResourceNatState::Confirmed => continue,
                    DnsResourceNatState::Pending {
                        sent_at,
                        buffered_packets,
                    } => {
                        let time_since_last_attempt = now.duration_since(*sent_at);
                        buffered_packets.extend(packets_for_domain);

                        if time_since_last_attempt < Duration::from_secs(2) {
                            continue;
                        }

                        *sent_at = now;
                    }
                },
            }

            let packet = match p2p_control::dns_resource_nat::assigned_ips(
                *rid,
                domain.clone(),
                proxy_ips.clone(),
            ) {
                Ok(packet) => packet,
                Err(e) => {
                    tracing::warn!("Failed to create IP packet for `AssignedIp`s event: {e:#}");
                    continue;
                }
            };

            tracing::debug!(%gid, %domain, "Setting up DNS resource NAT");

            encapsulate_and_buffer(
                packet,
                *gid,
                now,
                &mut self.node,
                &mut self.buffered_transmits,
            );
        }
    }

    /// Clears the DNS resource NAT state for a given domain.
    ///
    /// Once cleared, this will trigger the client to submit another `AssignedIp`s event to the Gateway.
    /// On the Gateway, such an event causes a new DNS resolution.
    ///
    /// We call this function every time a client issues a DNS query for a certain domain.
    /// Coupling this behaviour together allows a client to refresh the DNS resolution of a DNS resource on the Gateway
    /// through local DNS resolutions.
    fn clear_dns_resource_nat_for_domain(&mut self, message: &dns_types::Response) {
        let mut any_deleted = false;

        self.dns_resource_nat_by_gateway
            .retain(|(_, candidate), state| {
                let DnsResourceNatState::Confirmed = state else {
                    return true;
                };

                if candidate == &message.domain() {
                    any_deleted = true;
                    return false;
                }

                true
            });

        if any_deleted {
            tracing::debug!(domain = %message.domain(), "Cleared DNS resource NAT");
        }
    }

    fn is_cidr_resource_connected(&self, resource: &ResourceId) -> bool {
        let Some(gateway_id) = self.resources_gateways.get(resource) else {
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
    ) -> Option<snownet::EncryptedPacket> {
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
        .inspect_err(|e| tracing::debug!(%local, num_bytes = %packet.len(), "Failed to decapsulate incoming packet: {}", err_with_src(e)))
        .ok()??;

        if self.tcp_dns_client.accepts(&packet) {
            self.tcp_dns_client.handle_inbound(packet);
            return None;
        }

        if let Some(fz_p2p_control) = packet.as_fz_p2p_control() {
            handle_p2p_control_packet(
                gid,
                fz_p2p_control,
                &mut self.dns_resource_nat_by_gateway,
                &mut self.node,
                &mut self.buffered_transmits,
                now,
            );
            return None;
        }

        let Some(peer) = self.peers.get_mut(&gid) else {
            tracing::error!(%gid, "Couldn't find connection by ID");

            return None;
        };

        peer.ensure_allowed_src(&packet)
            .inspect_err(|e| tracing::debug!(%gid, %local, %from, "{e}"))
            .ok()?;

        let packet = maybe_mangle_dns_response_from_upstream_dns_server(
            packet,
            &mut self.udp_dns_sockets_by_upstream_and_query_id,
        );

        Some(packet)
    }

    pub(crate) fn handle_dns_response(&mut self, response: dns::RecursiveResponse) {
        let qid = response.query.id();
        let server = response.server;
        let domain = response.query.domain();

        let _span = tracing::debug_span!("handle_dns_response", %qid, %server, %domain).entered();

        match (response.transport, response.message) {
            (dns::Transport::Udp { .. }, Err(e)) if e.kind() == io::ErrorKind::TimedOut => {
                tracing::debug!("Recursive UDP DNS query timed out")
            }
            (dns::Transport::Udp { source }, result) => {
                let message = result
                    .inspect(|message| {
                        tracing::trace!("Received recursive UDP DNS response");

                        if message.truncated() {
                            tracing::debug!("Upstream DNS server had to truncate response");
                        }
                    })
                    .unwrap_or_else(|e| {
                        telemetry_event!("Recursive UDP DNS query failed: {}", err_with_src(&e));

                        dns_types::Response::servfail(&response.query)
                    });

                unwrap_or_warn!(
                    self.try_queue_udp_dns_response(server, source, message),
                    "Failed to queue UDP DNS response: {}"
                );
            }
            (dns::Transport::Tcp { local, remote }, result) => {
                let message = result
                    .inspect(|_| {
                        tracing::trace!("Received recursive TCP DNS response");
                    })
                    .unwrap_or_else(|e| {
                        telemetry_event!("Recursive TCP DNS query failed: {}", err_with_src(&e));

                        dns_types::Response::servfail(&response.query)
                    });

                unwrap_or_warn!(
                    self.tcp_dns_server.send_message(local, remote, message),
                    "Failed to send TCP DNS response: {}"
                );
            }
        }
    }

    fn encapsulate(&mut self, packet: IpPacket, now: Instant) -> Option<snownet::EncryptedPacket> {
        let dst = packet.destination();

        if is_definitely_not_a_resource(dst) {
            return None;
        }

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
                peer_by_resource_mut(&self.resources_gateways, &mut self.peers, resource)
            else {
                self.on_not_connected_resource(resource, packet, now);
                return None;
            };

            peer
        };

        // TODO: Check DNS resource NAT state for the domain that the destination IP belongs to.
        // Re-send if older than X.

        if let Some((domain, _)) = self.stub_resolver.resolve_resource_by_ip(&dst) {
            if let Some(DnsResourceNatState::Pending {
                buffered_packets, ..
            }) = self
                .dns_resource_nat_by_gateway
                .get_mut(&(peer.id(), domain.clone()))
            {
                buffered_packets.push(packet);
                return None;
            }
        }

        let gid = peer.id();

        let transmit = self
            .node
            .encapsulate(gid, packet, now)
            .inspect_err(|e| tracing::debug!(%gid, "Failed to encapsulate: {}", err_with_src(e)))
            .ok()??;

        Some(transmit)
    }

    fn try_queue_udp_dns_response(
        &mut self,
        from: SocketAddr,
        dst: SocketAddr,
        message: dns_types::Response,
    ) -> anyhow::Result<()> {
        let saddr = *self
            .dns_mapping
            .get_by_right(&DnsServer::from(from))
            .context("Unknown DNS server")?;

        let ip_packet = ip_packet::make::udp_packet(
            saddr,
            dst.ip(),
            DNS_PORT,
            dst.port(),
            message.into_bytes(MAX_UDP_PAYLOAD),
        )?;

        self.buffered_packets.push_back(ip_packet);

        Ok(())
    }

    pub fn add_ice_candidate(&mut self, conn_id: GatewayId, ice_candidate: String, now: Instant) {
        self.node.add_remote_candidate(conn_id, ice_candidate, now);
        self.node.handle_timeout(now);
        self.drain_node_events();
    }

    pub fn remove_ice_candidate(
        &mut self,
        conn_id: GatewayId,
        ice_candidate: String,
        now: Instant,
    ) {
        self.node
            .remove_remote_candidate(conn_id, ice_candidate, now);
        self.node.handle_timeout(now);
        self.drain_node_events();
    }

    #[tracing::instrument(level = "debug", skip_all, fields(%resource_id))]
    #[expect(clippy::too_many_arguments)]
    pub fn handle_flow_created(
        &mut self,
        resource_id: ResourceId,
        gateway_id: GatewayId,
        gateway_key: PublicKey,
        gateway_tun: IpConfig,
        site_id: SiteId,
        preshared_key: SecretKey,
        client_ice: IceCredentials,
        gateway_ice: IceCredentials,
        now: Instant,
    ) -> anyhow::Result<Result<(), NoTurnServers>> {
        tracing::debug!(%gateway_id, "New flow authorized for resource");

        let resource = self
            .resources_by_id
            .get(&resource_id)
            .context("Unknown resource")?;

        let Some(pending_flow) = self.pending_flows.remove(&resource_id) else {
            tracing::debug!("No pending flow");

            return Ok(Ok(()));
        };

        if let Some(old_gateway_id) = self.resources_gateways.insert(resource_id, gateway_id) {
            if self.peers.get(&old_gateway_id).is_some() {
                assert_eq!(
                    old_gateway_id, gateway_id,
                    "Resources are not expected to change gateways without a previous message, resource_id = {resource_id}"
                );
            }
        }

        match self.node.upsert_connection(
            gateway_id,
            gateway_key,
            Secret::new(preshared_key.expose_secret().0),
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
        self.resources_gateways.insert(resource_id, gateway_id);
        self.gateways_site.insert(gateway_id, site_id);
        self.recently_connected_gateways.put(gateway_id, ());

        if self.peers.get(&gateway_id).is_none() {
            self.peers
                .insert(GatewayOnClient::new(gateway_id, gateway_tun), &[]);
        };

        // Allow looking up the Gateway via its TUN IP.
        // Resources are not allowed to be in our CG-NAT range, therefore in practise this cannot overlap with resources.
        self.peers.add_ip(&gateway_id, &gateway_tun.v4.into());
        self.peers.add_ip(&gateway_id, &gateway_tun.v6.into());

        // Deal with buffered packets

        // 1. Buffered packets for resources
        let buffered_resource_packets = pending_flow.resource_packets;

        match resource {
            Resource::Cidr(_) | Resource::Internet(_) => {
                self.peers.add_ips_with_resource(
                    &gateway_id,
                    resource.addresses().into_iter(),
                    &resource_id,
                );

                // For CIDR and Internet resources, we can directly queue the buffered packets.
                for packet in buffered_resource_packets {
                    encapsulate_and_buffer(
                        packet,
                        gateway_id,
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

        // 2. Buffered UDP DNS queries for the Gateway
        for packet in pending_flow.udp_dns_queries {
            let gateway = self.peers.get(&gateway_id).context("Unknown peer")?; // If this error happens we have a bug: We just inserted it above.

            let upstream = gateway.tun_dns_server_endpoint(packet.destination());
            let packet =
                self.mangle_udp_dns_query_to_new_upstream_through_tunnel(upstream, now, packet);

            encapsulate_and_buffer(
                packet,
                gateway_id,
                now,
                &mut self.node,
                &mut self.buffered_transmits,
            )
        }

        // 3. Buffered TCP DNS queries for the Gateway
        for query in pending_flow.tcp_dns_queries {
            let server = match query.local {
                SocketAddr::V4(_) => {
                    SocketAddr::new(gateway_tun.v4.into(), crate::gateway::TUN_DNS_PORT)
                }
                SocketAddr::V6(_) => {
                    SocketAddr::new(gateway_tun.v6.into(), crate::gateway::TUN_DNS_PORT)
                }
            };

            self.forward_tcp_dns_query_to_new_upstream_via_tunnel(server, query);
        }

        Ok(Ok(()))
    }

    fn is_upstream_set_by_the_portal(&self) -> bool {
        !self.upstream_dns.is_empty()
    }

    /// For DNS queries to IPs that are a CIDR resources we want to mangle and forward to the gateway that handles that resource.
    ///
    /// We only want to do this if the upstream DNS server is set by the portal, otherwise, the server might be a local IP.
    fn should_forward_dns_query_to_gateway(&self, dns_server: IpAddr) -> bool {
        if !self.is_upstream_set_by_the_portal() {
            return false;
        }
        if self.internet_resource.is_some() {
            return true;
        }

        self.active_cidr_resources
            .longest_match(dns_server)
            .is_some()
    }

    /// Handles UDP & TCP packets targeted at our stub resolver.
    fn try_handle_dns(&mut self, packet: IpPacket, now: Instant) -> ControlFlow<(), IpPacket> {
        let dst = packet.destination();

        if is_llmnr(dst) {
            self.handle_llmnr_dns_query(packet, now);
            return ControlFlow::Break(());
        }

        let Some(upstream) = self.dns_mapping.get_by_left(&dst).map(|s| s.address()) else {
            return ControlFlow::Continue(packet); // Not for our DNS resolver.
        };

        if self.tcp_dns_server.accepts(&packet) {
            self.tcp_dns_server.handle_inbound(packet);
            return ControlFlow::Break(());
        }

        self.handle_udp_dns_query(upstream, packet, now)
    }

    pub fn on_connection_failed(&mut self, resource: ResourceId) {
        self.pending_flows.remove(&resource);
        let Some(disconnected_gateway) = self.resources_gateways.remove(&resource) else {
            return;
        };
        self.cleanup_connected_gateway(&disconnected_gateway);
    }

    #[tracing::instrument(level = "debug", skip_all, fields(%resource))]
    fn on_not_connected_resource(
        &mut self,
        resource: ResourceId,
        trigger: impl Into<ConnectionTrigger>,
        now: Instant,
    ) {
        let trigger = trigger.into();

        debug_assert!(self.resources_by_id.contains_key(&resource));

        match self.pending_flows.entry(resource) {
            Entry::Vacant(v) => {
                v.insert(PendingFlow::new(now, trigger));
            }
            Entry::Occupied(mut o) => {
                let pending_flow = o.get_mut();
                pending_flow.push(trigger);

                let time_since_last_intent = now.duration_since(pending_flow.last_intent_sent_at);

                if time_since_last_intent < Duration::from_secs(2) {
                    tracing::trace!(?time_since_last_intent, "Skipping connection intent");
                    return;
                }

                pending_flow.last_intent_sent_at = now;
            }
        }

        tracing::debug!("Sending connection intent");

        self.buffered_events
            .push_back(ClientEvent::ConnectionIntent {
                resource,
                connected_gateway_ids: self.connected_gateway_ids(),
            })
    }

    // We tell the portal about all gateways we ever connected to, to encourage re-connecting us to the same ones during a session.
    // The LRU cache visits them in MRU order, meaning a gateway that we recently connected to should still be preferred.
    fn connected_gateway_ids(&self) -> BTreeSet<GatewayId> {
        self.recently_connected_gateways
            .iter()
            .map(|(g, _)| *g)
            .collect()
    }

    pub fn gateway_by_resource(&self, resource: &ResourceId) -> Option<GatewayId> {
        self.resources_gateways.get(resource).copied()
    }

    fn set_dns_mapping(&mut self, new_mapping: BiMap<IpAddr, DnsServer>) {
        self.dns_mapping = new_mapping;
    }

    fn initialise_tcp_dns_client(&mut self) {
        let Some(tun_config) = self.tun_config.as_ref() else {
            return;
        };

        self.tcp_dns_client
            .set_source_interface(tun_config.ip.v4, tun_config.ip.v6);
        self.tcp_dns_client.reset();
    }

    fn initialise_tcp_dns_server(&mut self) {
        let sentinel_sockets = self
            .dns_mapping
            .left_values()
            .map(|ip| SocketAddr::new(*ip, DNS_PORT))
            .collect();

        self.tcp_dns_server
            .set_listen_addresses::<NUM_CONCURRENT_TCP_DNS_CLIENTS>(sentinel_sockets);
    }

    pub fn set_disabled_resources(&mut self, new_disabled_resources: BTreeSet<ResourceId>) {
        let current_disabled_resources = self.disabled_resources.clone();

        // We set disabled_resources before anything else so that add_resource knows what resources are enabled right now.
        self.disabled_resources.clone_from(&new_disabled_resources);

        for re_enabled_resource in current_disabled_resources.difference(&new_disabled_resources) {
            let Some(resource) = self.resources_by_id.get(re_enabled_resource) else {
                continue;
            };

            self.add_resource(resource.clone());
        }

        for new_disabled_resource in new_disabled_resources.difference(&current_disabled_resources)
        {
            self.disable_resource(*new_disabled_resource);
        }

        self.maybe_update_cidr_resources();
        self.maybe_update_tun_routes()
    }

    pub fn dns_mapping(&self) -> BiMap<IpAddr, DnsServer> {
        self.dns_mapping.clone()
    }

    #[tracing::instrument(level = "debug", skip_all, fields(gateway = %disconnected_gateway))]
    fn cleanup_connected_gateway(&mut self, disconnected_gateway: &GatewayId) {
        self.update_site_status_by_gateway(disconnected_gateway, ResourceStatus::Unknown);
        self.peers.remove(disconnected_gateway);
        self.resources_gateways
            .retain(|_, g| g != disconnected_gateway);
        self.dns_resource_nat_by_gateway
            .retain(|(gateway, _), _| gateway != disconnected_gateway);
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
                self.internet_resource
                    .map(|_| Ipv4Network::DEFAULT_ROUTE.into()),
            )
            .chain(
                self.internet_resource
                    .map(|_| Ipv6Network::DEFAULT_ROUTE.into()),
            )
    }

    fn is_resource_enabled(&self, resource: &ResourceId) -> bool {
        !self.disabled_resources.contains(resource) && self.resources_by_id.contains_key(resource)
    }

    fn get_resource_by_destination(&self, destination: IpAddr) -> Option<ResourceId> {
        // We need to filter disabled resources because we never remove resources from the stub_resolver
        let maybe_dns_resource_id = self
            .stub_resolver
            .resolve_resource_by_ip(&destination)
            .map(|(_, r)| *r)
            .filter(|resource| self.is_resource_enabled(resource))
            .inspect(
                |resource| tracing::trace!(target: "tunnel_test_coverage", %destination, %resource, "Packet for DNS resource"),
            );

        // We don't need to filter from here because resources are removed from the active_cidr_resources as soon as they are disabled.
        let maybe_cidr_resource_id = self
            .active_cidr_resources
            .longest_match(destination)
            .map(|(_, res)| res.id)
            .inspect(
                |resource| tracing::trace!(target: "tunnel_test_coverage", %destination, %resource, "Packet for CIDR resource"),
            );

        maybe_dns_resource_id
            .or(maybe_cidr_resource_id)
            .or(self.internet_resource)
            .inspect(|r| {
                if Some(*r) == self.internet_resource {
                    tracing::trace!(target: "tunnel_test_coverage", %destination, "Packet for Internet resource")
                }
            })
    }

    pub fn update_system_resolvers(&mut self, new_dns: Vec<IpAddr>) {
        tracing::debug!(servers = ?new_dns, "Received system-defined DNS servers");

        self.system_resolvers = new_dns;

        self.update_dns_mapping()
    }

    pub fn update_interface_config(&mut self, config: InterfaceConfig) {
        tracing::trace!(upstream_dns = ?config.upstream_dns, search_domain = ?config.search_domain, ipv4 = %config.ipv4, ipv6 = %config.ipv6, "Received interface configuration from portal");

        // Create a new `TunConfig` by patching the corresponding fields of the existing one.
        let new_tun_config = self
            .tun_config
            .as_ref()
            .map(|existing| TunConfig {
                ip: IpConfig {
                    v4: config.ipv4,
                    v6: config.ipv6,
                },
                dns_by_sentinel: existing.dns_by_sentinel.clone(),
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
                    dns_by_sentinel: Default::default(),
                    search_domain: config.search_domain.clone(),
                    ipv4_routes,
                    ipv6_routes,
                }
            });

        // Apply the new `TunConfig` if it differs from the existing one.
        self.maybe_update_tun_config(new_tun_config);

        self.upstream_dns = config.upstream_dns;
        self.update_dns_mapping();
    }

    pub fn poll_packets(&mut self) -> Option<IpPacket> {
        self.buffered_packets
            .pop_front()
            .or_else(|| self.tcp_dns_server.poll_outbound())
    }

    pub fn poll_timeout(&mut self) -> Option<Instant> {
        iter::empty()
            .chain(self.udp_dns_sockets_by_upstream_and_query_id.poll_timeout())
            .chain(self.tcp_dns_client.poll_timeout())
            .chain(self.tcp_dns_server.poll_timeout())
            .chain(self.node.poll_timeout())
            .min()
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.node.handle_timeout(now);
        self.drain_node_events();

        self.udp_dns_sockets_by_upstream_and_query_id
            .handle_timeout(now);

        self.advance_dns_tcp_sockets(now);
    }

    /// Advance the TCP DNS server and client state machines.
    ///
    /// Receiving something on a TCP server socket may trigger packets to be sent on the TCP client socket and vice versa.
    /// Therefore, we loop here until non of the `poll-X` functions return anything anymore.
    fn advance_dns_tcp_sockets(&mut self, now: Instant) {
        loop {
            self.tcp_dns_server.handle_timeout(now);
            self.tcp_dns_client.handle_timeout(now);

            // Check if have any pending TCP DNS queries.
            if let Some(query) = self.tcp_dns_server.poll_queries() {
                self.handle_tcp_dns_query(query, now);
                continue;
            }

            // Check if the client wants to emit any packets.
            if let Some(packet) = self.tcp_dns_client.poll_outbound() {
                // All packets from the TCP DNS client _should_ go through the tunnel.
                let Some(encryped_packet) = self.encapsulate(packet, now) else {
                    continue;
                };

                let transmit = encryped_packet.to_transmit().into_owned();
                self.buffered_transmits.push_back(transmit);
                continue;
            }

            // Check if the client has assembled a response to a query.
            if let Some(query_result) = self.tcp_dns_client.poll_query_result() {
                let server = query_result.server;
                let qid = query_result.query.id();
                let known_sockets = &mut self.tcp_dns_streams_by_upstream_and_query_id;

                let Some((local, remote)) = known_sockets.remove(&(server, qid)) else {
                    tracing::warn!(?known_sockets, %server, %qid, "Failed to find TCP socket handle for query result");

                    continue;
                };

                self.handle_dns_response(dns::RecursiveResponse {
                    server,
                    query: query_result.query,
                    message: query_result
                        .result
                        .map_err(|e| io::Error::new(io::ErrorKind::Other, format!("{e:#}"))),
                    transport: dns::Transport::Tcp { local, remote },
                });
                continue;
            }

            break;
        }
    }

    fn handle_udp_dns_query(
        &mut self,
        upstream: SocketAddr,
        packet: IpPacket,
        now: Instant,
    ) -> ControlFlow<(), IpPacket> {
        let Some(datagram) = packet.as_udp() else {
            tracing::debug!(?packet, "Not a UDP packet");

            return ControlFlow::Break(());
        };

        if datagram.destination_port() != DNS_PORT {
            tracing::debug!(
                ?packet,
                "UDP DNS queries are only supported on port {DNS_PORT}"
            );
            return ControlFlow::Break(());
        }

        let message = match dns_types::Query::parse(datagram.payload()) {
            Ok(message) => message,
            Err(e) => {
                tracing::warn!(?packet, "Failed to parse DNS query: {e:#}");
                return ControlFlow::Break(());
            }
        };

        let source = SocketAddr::new(packet.source(), datagram.source_port());

        match self.stub_resolver.handle(&message) {
            dns::ResolveStrategy::LocalResponse(response) => {
                self.clear_dns_resource_nat_for_domain(&response);
                self.update_dns_resource_nat(now, iter::empty());

                unwrap_or_debug!(
                    self.try_queue_udp_dns_response(upstream, source, response),
                    "Failed to queue UDP DNS response: {}"
                );
            }
            dns::ResolveStrategy::RecurseLocal => {
                if self.should_forward_dns_query_to_gateway(upstream.ip()) {
                    let packet = self
                        .mangle_udp_dns_query_to_new_upstream_through_tunnel(upstream, now, packet);

                    return ControlFlow::Continue(packet);
                }
                let query_id = message.id();

                tracing::trace!(server = %upstream, %query_id, "Forwarding UDP DNS query directly via host");

                self.buffered_dns_queries
                    .push_back(dns::RecursiveQuery::via_udp(source, upstream, message));
            }
            dns::ResolveStrategy::RecurseSite(resource) => {
                let Some(gateway) =
                    peer_by_resource_mut(&self.resources_gateways, &mut self.peers, resource)
                else {
                    self.on_not_connected_resource(
                        resource,
                        ConnectionTrigger::UdpDnsQueryForSite(packet),
                        now,
                    );
                    return ControlFlow::Break(());
                };

                let upstream = gateway.tun_dns_server_endpoint(packet.destination());

                let packet =
                    self.mangle_udp_dns_query_to_new_upstream_through_tunnel(upstream, now, packet);

                return ControlFlow::Continue(packet);
            }
        }

        ControlFlow::Break(())
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
                    && firezone_telemetry::feature_flags::drop_llmnr_nxdomain_responses()
                {
                    return;
                }

                self.clear_dns_resource_nat_for_domain(&response);
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

    fn mangle_udp_dns_query_to_new_upstream_through_tunnel(
        &mut self,
        upstream: SocketAddr,
        now: Instant,
        mut packet: IpPacket,
    ) -> IpPacket {
        let dst_ip = packet.destination();
        let datagram = packet
            .as_udp()
            .expect("to be a valid UDP packet at this point");

        let dst_port = datagram.destination_port();
        let query_id = dns_types::Query::parse(datagram.payload())
            .expect("to be a valid DNS query at this point")
            .id();

        let connlib_dns_server = SocketAddr::new(dst_ip, dst_port);

        self.udp_dns_sockets_by_upstream_and_query_id.insert(
            (upstream, query_id),
            connlib_dns_server,
            now + IDS_EXPIRE,
        );
        packet.set_dst(upstream.ip());
        // TODO: Remove this once we disallow non-standard DNS ports: https://github.com/firezone/firezone/issues/8330
        packet
            .as_udp_mut()
            .expect("to be a valid UDP packet at this point")
            .set_destination_port(upstream.port());

        packet.update_checksum();

        tracing::trace!(%upstream, %connlib_dns_server, %query_id, "Forwarding UDP DNS query via tunnel");

        packet
    }

    fn handle_tcp_dns_query(&mut self, query: dns_over_tcp::Query, now: Instant) {
        let query_id = query.message.id();

        let Some(upstream) = self.dns_mapping.get_by_left(&query.local.ip()) else {
            // This is highly-unlikely but might be possible if our DNS mapping changes whilst the TCP DNS server is processing a request.
            return;
        };
        let server = upstream.address();

        match self.stub_resolver.handle(&query.message) {
            dns::ResolveStrategy::LocalResponse(response) => {
                self.clear_dns_resource_nat_for_domain(&response);
                self.update_dns_resource_nat(now, iter::empty());

                unwrap_or_debug!(
                    self.tcp_dns_server
                        .send_message(query.local, query.remote, response),
                    "Failed to send TCP DNS response: {}"
                );
            }
            dns::ResolveStrategy::RecurseLocal => {
                if self.should_forward_dns_query_to_gateway(server.ip()) {
                    self.forward_tcp_dns_query_to_new_upstream_via_tunnel(server, query);

                    return;
                }

                tracing::trace!(%server, %query_id, "Forwarding TCP DNS query");

                self.buffered_dns_queries
                    .push_back(dns::RecursiveQuery::via_tcp(
                        query.local,
                        query.remote,
                        server,
                        query.message,
                    ));
            }
            dns::ResolveStrategy::RecurseSite(resource) => {
                let Some(gateway) =
                    peer_by_resource_mut(&self.resources_gateways, &mut self.peers, resource)
                else {
                    self.on_not_connected_resource(
                        resource,
                        ConnectionTrigger::TcpDnsQueryForSite(query),
                        now,
                    );
                    return;
                };

                let server = gateway.tun_dns_server_endpoint(query.local.ip());

                self.forward_tcp_dns_query_to_new_upstream_via_tunnel(server, query);
            }
        };
    }

    fn forward_tcp_dns_query_to_new_upstream_via_tunnel(
        &mut self,
        server: SocketAddr,
        query: dns_over_tcp::Query,
    ) {
        let query_id = query.message.id();

        match self
            .tcp_dns_client
            .send_query(server, query.message.clone())
        {
            Ok(()) => {}
            Err(e) => {
                tracing::warn!(
                    "Failed to send recursive TCP DNS query to upstream resolver: {e:#}"
                );

                unwrap_or_debug!(
                    self.tcp_dns_server.send_message(
                        query.local,
                        query.remote,
                        dns_types::Response::servfail(&query.message)
                    ),
                    "Failed to send TCP DNS response: {}"
                );
                return;
            }
        };

        let existing = self
            .tcp_dns_streams_by_upstream_and_query_id
            .insert((server, query_id), (query.local, query.remote));

        debug_assert!(existing.is_none(), "Query IDs should be unique");
    }

    fn maybe_update_tun_routes(&mut self) {
        let Some(config) = self.tun_config.clone() else {
            return;
        };

        let (ipv4_routes, ipv6_routes) = self.routes().partition_map(|route| match route {
            IpNetwork::V4(v4) => itertools::Either::Left(v4),
            IpNetwork::V6(v6) => itertools::Either::Right(v6),
        });

        let new_tun_config = TunConfig {
            ipv4_routes,
            ipv6_routes,
            ..config
        };

        self.maybe_update_tun_config(new_tun_config);
    }

    fn maybe_update_cidr_resources(&mut self) {
        let new_resources = self.recalculate_active_cidr_resources();

        if self.active_cidr_resources == new_resources {
            return;
        }

        tracing::info!(?self.active_cidr_resources, ?new_resources, "Re-calculated active CIDR resources");

        self.active_cidr_resources = new_resources;
    }

    fn recalculate_active_cidr_resources(&self) -> IpNetworkTable<CidrResource> {
        let mut active_cidr_resources = IpNetworkTable::<CidrResource>::new();

        for resource in self.resources_by_id.values() {
            let Resource::Cidr(resource) = resource else {
                continue;
            };

            if !self.is_resource_enabled(&resource.id) {
                continue;
            }

            if let Some(active_resource) = active_cidr_resources.exact_match(resource.address) {
                if self.is_cidr_resource_connected(&active_resource.id) {
                    continue;
                }
            }

            active_cidr_resources.insert(resource.address, resource.clone());
        }

        active_cidr_resources
    }

    fn maybe_update_tun_config(&mut self, new_tun_config: TunConfig) {
        if Some(&new_tun_config) == self.tun_config.as_ref() {
            tracing::trace!(current = ?self.tun_config, "TUN device configuration unchanged");

            return;
        }

        tracing::info!(config = ?new_tun_config, "Updating TUN device");

        self.stub_resolver
            .set_search_domain(new_tun_config.search_domain.clone());

        // Ensure we don't emit multiple interface updates in a row.
        self.buffered_events
            .retain(|e| !matches!(e, ClientEvent::TunInterfaceUpdated(_)));

        self.tun_config = Some(new_tun_config.clone());
        self.buffered_events
            .push_back(ClientEvent::TunInterfaceUpdated(new_tun_config));

        self.initialise_tcp_dns_client(); // We must reset the TCP DNS client because changed CIDR resources (and thus changed routes) might affect which site we connect to.
        self.initialise_tcp_dns_server();
    }

    fn drain_node_events(&mut self) {
        let mut resources_changed = false; // Track this separately to batch together `ResourcesChanged` events.
        let mut added_ice_candidates = BTreeMap::<GatewayId, BTreeSet<String>>::default();
        let mut removed_ice_candidates = BTreeMap::<GatewayId, BTreeSet<String>>::default();

        while let Some(event) = self.node.poll_event() {
            match event {
                snownet::Event::ConnectionFailed(id) | snownet::Event::ConnectionClosed(id) => {
                    self.cleanup_connected_gateway(&id);
                    resources_changed = true;
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
                snownet::Event::ConnectionEstablished(id) => {
                    self.update_site_status_by_gateway(&id, ResourceStatus::Online);
                    resources_changed = true;
                }
            }
        }

        if resources_changed {
            self.emit_resources_changed()
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

    fn update_site_status_by_gateway(&mut self, gateway_id: &GatewayId, status: ResourceStatus) {
        // Note: we can do this because in theory we shouldn't have multiple gateways for the same site
        // connected at the same time.
        self.sites_status.insert(
            *self.gateways_site.get(gateway_id).expect(
                "if we're updating a site status there should be an associated site to a gateway",
            ),
            status,
        );
    }

    pub(crate) fn poll_event(&mut self) -> Option<ClientEvent> {
        self.buffered_events.pop_front()
    }

    pub(crate) fn reset(&mut self, now: Instant) {
        tracing::info!("Resetting network state");

        self.node.reset(now); // Clear all network connections.
        self.peers.clear(); // Clear all state associated with Gateways.

        self.resources_gateways.clear(); // Clear Resource <> Gateway mapping (we will re-create this as new flows are authorized).

        self.recently_connected_gateways.clear(); // Ensure we don't have sticky gateways when we roam.
        self.dns_resource_nat_by_gateway.clear(); // Clear all state related to DNS resource NATs.
        self.drain_node_events();

        // Resetting the client will trigger a failed `QueryResult` for each one that is in-progress.
        // Failed queries get translated into `SERVFAIL` responses to the client.
        self.tcp_dns_client.reset();
    }

    pub(crate) fn poll_transmit(&mut self) -> Option<snownet::Transmit<'static>> {
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
    pub fn set_resources<R>(&mut self, new_resources: Vec<R>)
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
            self.remove_resource(id);
        }

        // Second, add all resources.
        for resource in new_resources {
            self.add_resource(resource)
        }

        self.maybe_update_cidr_resources();
        self.maybe_update_tun_routes();
        self.emit_resources_changed();
    }

    pub fn add_resource(&mut self, new_resource: impl TryInto<Resource, Error: std::error::Error>) {
        let new_resource = match new_resource.try_into() {
            Ok(r) => r,
            Err(e) => {
                tracing::debug!("{e}");
                return;
            }
        };

        if let Some(resource) = self.resources_by_id.get(&new_resource.id()) {
            if resource.has_different_address(&new_resource) {
                self.remove_resource(resource.id());
            }
        }

        self.resources_by_id
            .insert(new_resource.id(), new_resource.clone());

        if !self.is_resource_enabled(&(new_resource.id())) {
            self.emit_resources_changed(); // We still have a new resource but it is disabled, let the client know.
            return;
        }

        let activated = match &new_resource {
            Resource::Dns(dns) => self.stub_resolver.add_resource(dns.id, dns.address.clone()),
            Resource::Cidr(cidr) => {
                let existing = self.active_cidr_resources.exact_match(cidr.address);

                match existing {
                    Some(existing) => existing.id != cidr.id,
                    None => true,
                }
            }
            Resource::Internet(resource) => {
                self.internet_resource.replace(resource.id) != Some(resource.id)
            }
        };

        if activated {
            let name = new_resource.name();
            let address = new_resource.address_string().map(tracing::field::display);
            let sites = new_resource.sites_string();

            tracing::info!(%name, address, %sites, "Activating resource");
        }

        if matches!(new_resource, Resource::Cidr(_)) {
            self.maybe_update_cidr_resources();
        }

        self.maybe_update_tun_routes();
        self.emit_resources_changed();
    }

    #[tracing::instrument(level = "debug", skip_all, fields(?id))]
    pub fn remove_resource(&mut self, id: ResourceId) {
        self.disable_resource(id);

        if self
            .resources_by_id
            .remove(&id)
            .is_some_and(|r| matches!(r, Resource::Cidr(_)))
        {
            self.maybe_update_cidr_resources();
        };

        self.maybe_update_tun_routes();
        self.emit_resources_changed();
    }

    /// Emit a [`ClientEvent::ResourcesChanged`] event.
    ///
    /// Each instance of this event contains the latest state of the resources.
    /// To not spam clients with multiple updates, we remove all prior instances of that event.
    fn emit_resources_changed(&mut self) {
        self.buffered_events
            .retain(|e| !matches!(e, ClientEvent::ResourcesChanged { .. }));
        self.buffered_events
            .push_back(ClientEvent::ResourcesChanged {
                resources: self.resources(),
            });
    }

    fn disable_resource(&mut self, id: ResourceId) {
        let Some(resource) = self.resources_by_id.get(&id) else {
            return;
        };

        match resource {
            Resource::Dns(_) => self.stub_resolver.remove_resource(id),
            Resource::Cidr(_) => {}
            Resource::Internet(_) => {
                if self.internet_resource.is_some_and(|r_id| r_id == id) {
                    self.internet_resource = None;
                }
            }
        }

        let name = resource.name();
        let address = resource.address_string().map(tracing::field::display);
        let sites = resource.sites_string();

        tracing::info!(%name, address, %sites, "Deactivating resource");

        self.pending_flows.remove(&id);

        let Some(peer) = peer_by_resource_mut(&self.resources_gateways, &mut self.peers, id) else {
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

        self.resources_gateways.remove(&id);

        // Clear DNS resource NAT state for all domains resolved for this DNS resource.
        for domain in self
            .stub_resolver
            .resolved_resources()
            .filter_map(|(domain, candidate, _)| (candidate == &id).then_some(domain))
        {
            self.dns_resource_nat_by_gateway
                .retain(|(_, candidate), _| candidate != domain);
        }
    }

    fn update_dns_mapping(&mut self) {
        let Some(config) = self.tun_config.clone() else {
            // For the Tauri clients this can happen because it's called immediately after phoenix_channel's connect, before on_set_interface_config
            tracing::debug!("Unable to update DNS servers without interface configuration");

            return;
        };

        let effective_dns_servers =
            effective_dns_servers(self.upstream_dns.clone(), self.system_resolvers.clone());

        if HashSet::<&DnsServer>::from_iter(effective_dns_servers.iter())
            == HashSet::from_iter(self.dns_mapping.right_values())
        {
            tracing::debug!(servers = ?effective_dns_servers, "Effective DNS servers are unchanged");

            return;
        }

        let dns_mapping = sentinel_dns_mapping(
            &effective_dns_servers,
            self.dns_mapping()
                .left_values()
                .copied()
                .map(Into::into)
                .collect_vec(),
        );

        let (ipv4_routes, ipv6_routes) = self.routes().partition_map(|route| match route {
            IpNetwork::V4(v4) => itertools::Either::Left(v4),
            IpNetwork::V6(v6) => itertools::Either::Right(v6),
        });

        let new_tun_config = TunConfig {
            ip: config.ip,
            dns_by_sentinel: dns_mapping
                .iter()
                .map(|(sentinel_dns, effective_dns)| (*sentinel_dns, effective_dns.address()))
                .collect::<BiMap<_, _>>(),
            search_domain: config.search_domain,
            ipv4_routes,
            ipv6_routes,
        };

        self.set_dns_mapping(dns_mapping);
        self.maybe_update_tun_config(new_tun_config);
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
    buffered_transmits: &mut VecDeque<Transmit<'static>>,
) {
    let Some(enc_packet) = node
        .encapsulate(gid, packet, now)
        .inspect_err(|e| tracing::debug!(%gid, "Failed to encapsulate: {e}"))
        .ok()
        .flatten()
    else {
        return;
    };

    buffered_transmits.push_back(enc_packet.to_transmit().into_owned());
}

fn handle_p2p_control_packet(
    gid: GatewayId,
    fz_p2p_control: ip_packet::FzP2pControlSlice,
    dns_resource_nat_by_gateway: &mut BTreeMap<(GatewayId, DomainName), DnsResourceNatState>,
    node: &mut ClientNode<GatewayId, RelayId>,
    buffered_transmits: &mut VecDeque<Transmit<'static>>,
    now: Instant,
) {
    use p2p_control::dns_resource_nat;

    match fz_p2p_control.event_type() {
        p2p_control::DOMAIN_STATUS_EVENT => {
            let Ok(res) = dns_resource_nat::decode_domain_status(fz_p2p_control)
                .inspect_err(|e| tracing::debug!("{e:#}"))
            else {
                return;
            };

            if res.status != dns_resource_nat::NatStatus::Active {
                tracing::debug!(%gid, domain = %res.domain, "DNS resource NAT is not active");
                return;
            }

            let Some(nat_state) = dns_resource_nat_by_gateway.get_mut(&(gid, res.domain.clone()))
            else {
                tracing::debug!(%gid, domain = %res.domain, "No DNS resource NAT state, ignoring response");
                return;
            };

            tracing::debug!(%gid, domain = %res.domain, num_buffered_packets = %nat_state.num_buffered_packets(), "DNS resource NAT is active");

            let buffered_packets = nat_state.confirm();

            for packet in buffered_packets {
                encapsulate_and_buffer(packet, gid, now, node, buffered_transmits);
            }
        }
        code => {
            tracing::debug!(code = %code.into_u8(), "Unknown control protocol");
        }
    }
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

fn effective_dns_servers(
    upstream_dns: Vec<DnsServer>,
    default_resolvers: Vec<IpAddr>,
) -> Vec<DnsServer> {
    let mut upstream_dns = upstream_dns.into_iter().filter_map(not_sentinel).peekable();
    if upstream_dns.peek().is_some() {
        return upstream_dns.collect();
    }

    let mut dns_servers = default_resolvers
        .into_iter()
        .map(|ip| {
            DnsServer::IpPort(IpDnsServer {
                address: (ip, DNS_PORT).into(),
            })
        })
        .filter_map(not_sentinel)
        .peekable();

    if dns_servers.peek().is_none() {
        tracing::info!(
            "No system default DNS servers available! Can't initialize resolver. DNS resources won't work."
        );
        return Vec::new();
    }

    dns_servers.collect()
}

fn not_sentinel(srv: DnsServer) -> Option<DnsServer> {
    let is_v4_dns = IpNetwork::V4(DNS_SENTINELS_V4).contains(srv.ip());
    let is_v6_dns = IpNetwork::V6(DNS_SENTINELS_V6).contains(srv.ip());

    (!is_v4_dns && !is_v6_dns).then_some(srv)
}

fn sentinel_dns_mapping(
    dns: &[DnsServer],
    old_sentinels: Vec<IpNetwork>,
) -> BiMap<IpAddr, DnsServer> {
    let mut ip_provider = IpProvider::for_stub_dns_servers(old_sentinels);

    dns.iter()
        .cloned()
        .map(|i| {
            (
                ip_provider
                    .get_proxy_ip_for(&i.ip())
                    .expect("We only support up to 256 IPv4 DNS servers and 256 IPv6 DNS servers"),
                i,
            )
        })
        .collect()
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

fn maybe_mangle_dns_response_from_upstream_dns_server(
    mut packet: IpPacket,
    udp_dns_sockets_by_upstream_and_query_id: &mut ExpiringMap<(SocketAddr, u16), SocketAddr>,
) -> IpPacket {
    let src_ip = packet.source();

    let Some(udp) = packet.as_udp() else {
        return packet;
    };

    let src_port = udp.source_port();
    let src_socket = SocketAddr::new(src_ip, src_port);

    let Ok(message) = dns_types::Response::parse(udp.payload()) else {
        return packet;
    };

    let Some(original_dst) =
        udp_dns_sockets_by_upstream_and_query_id.remove(&(src_socket, message.id()))
    else {
        return packet;
    };

    tracing::trace!(server = %src_ip, query_id = %message.id(), domain = %message.domain(), "Received UDP DNS response via tunnel");

    packet.set_src(original_dst.ip());
    packet
        .as_udp_mut()
        .expect("we parsed it as a UDP packet earlier")
        .set_source_port(original_dst.port());

    packet.update_checksum();

    packet
}

/// What triggered us to establish a connection to a Gateway.
enum ConnectionTrigger {
    /// A packet received on the TUN device with a destination IP that maps to one of our resources.
    PacketForResource(IpPacket),
    /// A UDP DNS query that needs to be resolved within a particular site that we aren't connected to yet.
    ///
    /// This packet isn't mangled yet to point to the Gateway's TUN device IP because at the time of buffering, that IP is unknown.
    UdpDnsQueryForSite(IpPacket),
    /// A TCP DNS query that needs to be resolved within a particular site that we aren't connected to yet.
    TcpDnsQueryForSite(dns_over_tcp::Query),
}

impl From<IpPacket> for ConnectionTrigger {
    fn from(v: IpPacket) -> Self {
        Self::PacketForResource(v)
    }
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

    pub fn for_stub_dns_servers(exclusions: Vec<IpNetwork>) -> Self {
        IpProvider::new(DNS_SENTINELS_V4, DNS_SENTINELS_V6, exclusions)
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
    fn sentinel_dns_works() {
        let servers = dns_list();
        let sentinel_dns = sentinel_dns_mapping(&servers, vec![]);

        for server in servers {
            assert!(
                sentinel_dns
                    .get_by_right(&server)
                    .is_some_and(|s| sentinel_ranges().iter().any(|e| e.contains(*s)))
            )
        }
    }

    #[test]
    fn sentinel_dns_excludes_old_ones() {
        let servers = dns_list();
        let sentinel_dns_old = sentinel_dns_mapping(&servers, vec![]);
        let sentinel_dns_new = sentinel_dns_mapping(
            &servers,
            sentinel_dns_old
                .left_values()
                .copied()
                .map(Into::into)
                .collect_vec(),
        );

        assert!(
            HashSet::<&IpAddr>::from_iter(sentinel_dns_old.left_values())
                .is_disjoint(&HashSet::from_iter(sentinel_dns_new.left_values()))
        )
    }

    impl ClientState {
        pub fn for_test() -> ClientState {
            ClientState::new(rand::random(), Instant::now())
        }
    }

    fn sentinel_ranges() -> Vec<IpNetwork> {
        vec![
            IpNetwork::V4(DNS_SENTINELS_V4),
            IpNetwork::V6(DNS_SENTINELS_V6),
        ]
    }

    fn dns_list() -> Vec<DnsServer> {
        vec![
            dns("1.1.1.1:53"),
            dns("1.0.0.1:53"),
            dns("[2606:4700:4700::1111]:53"),
        ]
    }

    fn dns(address: &str) -> DnsServer {
        DnsServer::IpPort(IpDnsServer {
            address: address.parse().unwrap(),
        })
    }

    fn ip(addr: &str) -> IpAddr {
        addr.parse().unwrap()
    }
}

#[cfg(all(test, feature = "proptest"))]
mod proptests {
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

        client_state.add_resource(Resource::Cidr(resource1.clone()));
        client_state.add_resource(Resource::Cidr(resource2.clone()));

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

        client_state.add_resource(Resource::Cidr(resource1.clone()));
        client_state.add_resource(Resource::Dns(resource2.clone()));

        assert_eq!(
            hashset(client_state.resources()),
            hashset([
                ResourceView::Cidr(resource1.clone().with_status(ResourceStatus::Unknown)),
                ResourceView::Dns(resource2.clone().with_status(ResourceStatus::Unknown))
            ])
        );

        client_state.add_resource(Resource::Cidr(resource3.clone()));

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
        client_state.add_resource(Resource::Cidr(resource.clone()));

        let updated_resource = CidrResource {
            address: new_address,
            ..resource
        };

        client_state.add_resource(Resource::Cidr(updated_resource.clone()));

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
        client_state.add_resource(Resource::Dns(resource.clone()));

        let dns_as_cidr_resource = CidrResource {
            address,
            id: resource.id,
            name: resource.name,
            address_description: resource.address_description,
            sites: resource.sites,
        };

        client_state.add_resource(Resource::Cidr(dns_as_cidr_resource.clone()));

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
        client_state.add_resource(Resource::Dns(dns_resource.clone()));
        client_state.add_resource(Resource::Cidr(cidr_resource.clone()));

        client_state.remove_resource(dns_resource.id);

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

        client_state.remove_resource(cidr_resource.id);

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
        client_state.add_resource(Resource::Dns(dns_resource1));
        client_state.add_resource(Resource::Cidr(cidr_resource1));

        client_state.set_resources(vec![
            Resource::Dns(dns_resource2.clone()),
            Resource::Cidr(cidr_resource2.clone()),
        ]);

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
            client_state.add_resource(r.clone())
        }

        let first_resource = resources_online.first().unwrap();
        client_state
            .resources_gateways
            .insert(first_resource.id(), gateway);
        client_state
            .gateways_site
            .insert(gateway, first_resource.sites().iter().next().unwrap().id);

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
            client_state.add_resource(r.clone())
        }
        let first_resources = resources.first().unwrap();
        client_state
            .resources_gateways
            .insert(first_resources.id(), gateway);
        client_state
            .gateways_site
            .insert(gateway, first_resources.sites().iter().next().unwrap().id);

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
        client_state.add_resource(single_site_resource.clone());
        for r in &multi_site_resources {
            client_state.add_resource(r.clone())
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
