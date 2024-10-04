mod resource;

pub(crate) use resource::{CidrResource, Resource};
#[cfg(all(feature = "proptest", test))]
pub(crate) use resource::{DnsResource, InternetResource};

use crate::dns::StubResolver;
use crate::messages::{DnsServer, Interface as InterfaceConfig, IpDnsServer};
use crate::messages::{IceCredentials, SecretKey};
use crate::peer_store::PeerStore;
use crate::{dns, p2p_control, TunConfig};
use anyhow::Context;
use bimap::BiMap;
use connlib_model::{
    DomainName, GatewayId, PublicKey, RelayId, ResourceId, ResourceStatus, ResourceView,
};
use connlib_model::{Site, SiteId};
use firezone_logging::{
    anyhow_dyn_err, err_with_src, telemetry_event, unwrap_or_debug, unwrap_or_warn,
};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_network_table::IpNetworkTable;
use ip_packet::{IpPacket, UdpSlice, MAX_DATAGRAM_PAYLOAD};
use itertools::Itertools;

use crate::peer::GatewayOnClient;
use crate::utils::earliest;
use crate::ClientEvent;
use domain::base::Message;
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
const MAX_REMEMBERED_GATEWAYS: NonZeroUsize = unsafe { NonZeroUsize::new_unchecked(100) };

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
    /// DNS queries that had their destination IP mangled because the servers is a CIDR resource.
    ///
    /// The [`Instant`] tracks when the DNS query expires.
    mangled_dns_queries: HashMap<(SocketAddr, u16), Instant>,
    /// Manages internal dns records and emits forwarding event when not internally handled
    stub_resolver: StubResolver,

    /// Configuration of the TUN device, when it is up.
    tun_config: Option<TunConfig>,

    /// Resources that have been disabled by the UI
    disabled_resources: BTreeSet<ResourceId>,

    tcp_dns_client: dns_over_tcp::Client,
    tcp_dns_server: dns_over_tcp::Server,
    /// Tracks the socket on which we received a TCP DNS query by the ID of the recursive DNS query we issued.
    tcp_dns_sockets_by_upstream_and_query_id:
        HashMap<(SocketAddr, u16), dns_over_tcp::SocketHandle>,

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
    Pending { sent_at: Instant },
    Confirmed,
}

impl DnsResourceNatState {
    fn confirm(&mut self) {
        *self = Self::Confirmed;
    }
}

struct PendingFlow {
    last_intent_sent_at: Instant,
}

impl ClientState {
    pub(crate) fn new(
        known_hosts: BTreeMap<String, Vec<IpAddr>>,
        seed: [u8; 32],
        now: Instant,
    ) -> Self {
        Self {
            resources_gateways: Default::default(),
            active_cidr_resources: IpNetworkTable::new(),
            resources_by_id: Default::default(),
            peers: Default::default(),
            dns_mapping: Default::default(),
            buffered_events: Default::default(),
            tun_config: Default::default(),
            buffered_packets: Default::default(),
            node: ClientNode::new(seed),
            system_resolvers: Default::default(),
            sites_status: Default::default(),
            gateways_site: Default::default(),
            mangled_dns_queries: Default::default(),
            stub_resolver: StubResolver::new(known_hosts),
            disabled_resources: Default::default(),
            buffered_transmits: Default::default(),
            internet_resource: None,
            recently_connected_gateways: LruCache::new(MAX_REMEMBERED_GATEWAYS),
            upstream_dns: Default::default(),
            buffered_dns_queries: Default::default(),
            tcp_dns_client: dns_over_tcp::Client::new(now, seed),
            tcp_dns_server: dns_over_tcp::Server::new(now),
            tcp_dns_sockets_by_upstream_and_query_id: Default::default(),
            pending_flows: Default::default(),
            dns_resource_nat_by_gateway: BTreeMap::new(),
        }
    }

    #[cfg(all(test, feature = "proptest"))]
    pub(crate) fn tunnel_ip4(&self) -> Option<Ipv4Addr> {
        Some(self.tun_config.as_ref()?.ip4)
    }

    #[cfg(all(test, feature = "proptest"))]
    pub(crate) fn tunnel_ip6(&self) -> Option<Ipv6Addr> {
        Some(self.tun_config.as_ref()?.ip6)
    }

    #[cfg(all(test, feature = "proptest"))]
    pub(crate) fn tunnel_ip_for(&self, dst: IpAddr) -> Option<IpAddr> {
        Some(match dst {
            IpAddr::V4(_) => self.tunnel_ip4()?.into(),
            IpAddr::V6(_) => self.tunnel_ip6()?.into(),
        })
    }

    #[cfg(all(test, feature = "proptest"))]
    pub(crate) fn num_connections(&self) -> usize {
        self.node.num_connections()
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
    fn update_dns_resource_nat(&mut self, now: Instant) {
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

            self.peers
                .add_ips_with_resource(gid, proxy_ips.iter().copied(), rid);

            match self
                .dns_resource_nat_by_gateway
                .entry((*gid, domain.clone()))
            {
                Entry::Vacant(v) => {
                    v.insert(DnsResourceNatState::Pending { sent_at: now });
                }
                Entry::Occupied(mut o) => match o.get_mut() {
                    DnsResourceNatState::Confirmed => continue,
                    DnsResourceNatState::Pending { sent_at } => {
                        let time_since_last_attempt = now.duration_since(*sent_at);

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
                    tracing::warn!(
                        error = anyhow_dyn_err(&e),
                        "Failed to create IP packet for `AssignedIp`s event"
                    );
                    continue;
                }
            };

            tracing::debug!(%gid, %domain, "Setting up DNS resource NAT");

            let Some(transmit) = self
                .node
                .encapsulate(*gid, packet, now)
                .inspect_err(|e| tracing::debug!(%gid, "Failed to encapsulate: {e}"))
                .ok()
                .flatten()
            else {
                continue;
            };

            self.buffered_transmits
                .push_back(transmit.to_transmit().into_owned());
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
            handle_p2p_control_packet(gid, fz_p2p_control, &mut self.dns_resource_nat_by_gateway);
            return None;
        }

        let Some(peer) = self.peers.get_mut(&gid) else {
            tracing::error!(%gid, "Couldn't find connection by ID");

            return None;
        };

        peer.ensure_allowed_src(&packet)
            .inspect_err(|e| tracing::debug!(%gid, %local, %from, "{e}"))
            .ok()?;

        let packet = maybe_mangle_dns_response_from_cidr_resource(
            packet,
            &self.dns_mapping,
            &mut self.mangled_dns_queries,
            now,
        );

        Some(packet)
    }

    pub(crate) fn handle_dns_response(&mut self, response: dns::RecursiveResponse) {
        let qid = response.query.header().id();
        let server = response.server;
        let domain = response
            .query
            .sole_question()
            .ok()
            .map(|q| q.into_qname())
            .map(tracing::field::display);

        let _span = tracing::debug_span!("handle_dns_response", %qid, %server, domain).entered();

        match (response.transport, response.message) {
            (dns::Transport::Udp { .. }, Err(e)) if e.kind() == io::ErrorKind::TimedOut => {
                tracing::debug!("Recursive UDP DNS query timed out")
            }
            (dns::Transport::Udp { source }, result) => {
                let message = result
                    .inspect(|message| {
                        tracing::trace!("Received recursive UDP DNS response");

                        if message.header().tc() {
                            tracing::debug!("Upstream DNS server had to truncate response");
                        }
                    })
                    .unwrap_or_else(|e| {
                        telemetry_event!("Recursive UDP DNS query failed: {}", err_with_src(&e));

                        dns::servfail(response.query.for_slice_ref())
                    });

                unwrap_or_warn!(
                    self.try_queue_udp_dns_response(server, source, &message),
                    "Failed to queue UDP DNS response"
                );
            }
            (dns::Transport::Tcp { source }, result) => {
                let message = result
                    .inspect(|_| {
                        tracing::trace!("Received recursive TCP DNS response");
                    })
                    .unwrap_or_else(|e| {
                        telemetry_event!("Recursive TCP DNS query failed: {}", err_with_src(&e));

                        dns::servfail(response.query.for_slice_ref())
                    });

                unwrap_or_warn!(
                    self.tcp_dns_server.send_message(source, message),
                    "Failed to send TCP DNS response"
                );
            }
        }
    }

    fn encapsulate(&mut self, packet: IpPacket, now: Instant) -> Option<snownet::EncryptedPacket> {
        let dst = packet.destination();

        if is_definitely_not_a_resource(dst) {
            return None;
        }

        let Some(resource) = self.get_resource_by_destination(dst) else {
            tracing::trace!(?packet, "Unknown resource");
            return None;
        };

        let Some(peer) = peer_by_resource_mut(&self.resources_gateways, &mut self.peers, resource)
        else {
            self.on_not_connected_resource(resource, now);
            return None;
        };

        // TODO: Don't send packets unless we have a positive response for the DNS resource NAT.

        // TODO: Check DNS resource NAT state for the domain that the destination IP belongs to.
        // Re-send if older than X.

        // if let Some((domain, _)) = self.stub_resolver.resolve_resource_by_ip(&dst) {
        //     if self
        //         .dns_resource_nat_by_gateway
        //         .get(&(peer.id(), domain.clone()))
        //         .is_some_and(|s| s.is_pending())
        //     {
        //         self.update_dns_resource_nat(now);
        //     }
        // }

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
        message: &Message<Vec<u8>>,
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
            truncate_dns_response(message),
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

    #[tracing::instrument(level = "debug", skip_all, fields(%gateway_id))]
    #[expect(clippy::too_many_arguments)]
    pub fn handle_flow_created(
        &mut self,
        resource_id: ResourceId,
        gateway_id: GatewayId,
        gateway_key: PublicKey,
        site_id: SiteId,
        preshared_key: SecretKey,
        client_ice: IceCredentials,
        gateway_ice: IceCredentials,
        now: Instant,
    ) -> anyhow::Result<Result<(), NoTurnServers>> {
        tracing::trace!("Updating resource routing table");

        let resource = self
            .resources_by_id
            .get(&resource_id)
            .context("Unknown resource")?;

        self.pending_flows
            .remove(&resource_id)
            .context("No pending flow for resource")?;

        if let Some(old_gateway_id) = self.resources_gateways.insert(resource_id, gateway_id) {
            if self.peers.get(&old_gateway_id).is_some() {
                assert_eq!(old_gateway_id, gateway_id, "Resources are not expected to change gateways without a previous message, resource_id = {resource_id}");
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
            self.peers.insert(GatewayOnClient::new(gateway_id), &[]);
        };

        // This only works for CIDR & Internet Resource.
        self.peers.add_ips_with_resource(
            &gateway_id,
            resource.addresses().into_iter(),
            &resource_id,
        );

        self.update_dns_resource_nat(now);

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
    fn on_not_connected_resource(&mut self, resource: ResourceId, now: Instant) {
        debug_assert!(self.resources_by_id.contains_key(&resource));

        match self.pending_flows.entry(resource) {
            Entry::Vacant(v) => {
                v.insert(PendingFlow {
                    last_intent_sent_at: now,
                });
            }
            Entry::Occupied(mut o) => {
                let pending_flow = o.get_mut();

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
        self.mangled_dns_queries.clear();
    }

    fn initialise_tcp_dns_client(&mut self) {
        let Some(tun_config) = self.tun_config.as_ref() else {
            return;
        };

        self.tcp_dns_client
            .set_source_interface(tun_config.ip4, tun_config.ip6);

        let upstream_resolvers = self
            .dns_mapping
            .right_values()
            .map(|s| s.address())
            .collect();

        if let Err(e) = self.tcp_dns_client.set_resolvers(upstream_resolvers) {
            tracing::warn!(
                error = anyhow_dyn_err(&e),
                "Failed to connect to upstream DNS resolvers over TCP"
            );
        }
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

        for disabled_resource in &new_disabled_resources {
            self.disable_resource(*disabled_resource);
        }

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
        tracing::trace!(upstream_dns = ?config.upstream_dns, ipv4 = %config.ipv4, ipv6 = %config.ipv6, "Received interface configuration from portal");

        match self.tun_config.as_mut() {
            Some(existing) => {
                // We don't really expect these to change but let's update them anyway.
                existing.ip4 = config.ipv4;
                existing.ip6 = config.ipv6;
            }
            None => {
                let (ipv4_routes, ipv6_routes) = self.routes().partition_map(|route| match route {
                    IpNetwork::V4(v4) => itertools::Either::Left(v4),
                    IpNetwork::V6(v6) => itertools::Either::Right(v6),
                });
                let new_tun_config = TunConfig {
                    ip4: config.ipv4,
                    ip6: config.ipv6,
                    dns_by_sentinel: Default::default(),
                    ipv4_routes,
                    ipv6_routes,
                };

                self.maybe_update_tun_config(new_tun_config);
            }
        }

        self.upstream_dns = config.upstream_dns;

        self.update_dns_mapping()
    }

    pub fn poll_packets(&mut self) -> Option<IpPacket> {
        self.buffered_packets
            .pop_front()
            .or_else(|| self.tcp_dns_server.poll_outbound())
    }

    pub fn poll_timeout(&mut self) -> Option<Instant> {
        // The number of mangled DNS queries is expected to be fairly small because we only track them whilst connecting to a CIDR resource that is a DNS server.
        // Thus, sorting these values on-demand even within `poll_timeout` is expected to be performant enough.
        let next_dns_query_expiry = self.mangled_dns_queries.values().min().copied();

        earliest(
            earliest(
                self.tcp_dns_client.poll_timeout(),
                self.tcp_dns_server.poll_timeout(),
            ),
            earliest(self.node.poll_timeout(), next_dns_query_expiry),
        )
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.node.handle_timeout(now);
        self.drain_node_events();

        self.mangled_dns_queries.retain(|_, exp| now < *exp);

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
                let qid = query_result.query.header().id();
                let known_sockets = &mut self.tcp_dns_sockets_by_upstream_and_query_id;

                let Some(source) = known_sockets.remove(&(server, qid)) else {
                    tracing::warn!(?known_sockets, %server, %qid, "Failed to find TCP socket handle for query result");

                    continue;
                };

                self.handle_dns_response(dns::RecursiveResponse {
                    server,
                    query: query_result.query,
                    message: query_result
                        .result
                        .map_err(|e| io::Error::new(io::ErrorKind::Other, format!("{e:#}"))),
                    transport: dns::Transport::Tcp { source },
                });
                continue;
            }

            break;
        }
    }

    fn handle_udp_dns_query(
        &mut self,
        upstream: SocketAddr,
        mut packet: IpPacket,
        now: Instant,
    ) -> ControlFlow<(), IpPacket> {
        let Some(datagram) = packet.as_udp() else {
            tracing::debug!(?packet, "Not a UDP packet");

            return ControlFlow::Break(());
        };

        let message = match parse_udp_dns_message(&datagram) {
            Ok(message) => message,
            Err(e) => {
                tracing::warn!(
                    error = anyhow_dyn_err(&e),
                    ?packet,
                    "Failed to parse DNS query"
                );
                return ControlFlow::Break(());
            }
        };

        let source = SocketAddr::new(packet.source(), datagram.source_port());

        match self.stub_resolver.handle(message) {
            dns::ResolveStrategy::LocalResponse(response) => {
                unwrap_or_debug!(
                    self.try_queue_udp_dns_response(upstream, source, &response),
                    "Failed to queue UDP DNS response: {}"
                );
                self.update_dns_resource_nat(now);
            }
            dns::ResolveStrategy::Recurse => {
                let query_id = message.header().id();

                if self.should_forward_dns_query_to_gateway(upstream.ip()) {
                    tracing::trace!(server = %upstream, %query_id, "Forwarding UDP DNS query via tunnel");

                    self.mangled_dns_queries
                        .insert((upstream, message.header().id()), now + IDS_EXPIRE);
                    packet.set_dst(upstream.ip());
                    packet.update_checksum();

                    return ControlFlow::Continue(packet);
                }

                let query_id = message.header().id();

                tracing::trace!(server = %upstream, %query_id, "Forwarding UDP DNS query directly via host");

                self.buffered_dns_queries
                    .push_back(dns::RecursiveQuery::via_udp(source, upstream, message));
            }
        }

        ControlFlow::Break(())
    }

    fn handle_tcp_dns_query(&mut self, query: dns_over_tcp::Query, now: Instant) {
        let message = query.message;

        let Some(upstream) = self.dns_mapping.get_by_left(&query.local.ip()) else {
            // This is highly-unlikely but might be possible if our DNS mapping changes whilst the TCP DNS server is processing a request.
            return;
        };
        let server = upstream.address();

        match self.stub_resolver.handle(message.for_slice_ref()) {
            dns::ResolveStrategy::LocalResponse(response) => {
                unwrap_or_debug!(
                    self.tcp_dns_server.send_message(query.socket, response),
                    "Failed to send TCP DNS response: {}"
                );
                self.update_dns_resource_nat(now);
            }
            dns::ResolveStrategy::Recurse => {
                let query_id = message.header().id();

                if self.should_forward_dns_query_to_gateway(server.ip()) {
                    match self.tcp_dns_client.send_query(server, message.clone()) {
                        Ok(()) => {}
                        Err(e) => {
                            tracing::warn!(
                                error = anyhow_dyn_err(&e),
                                "Failed to send recursive TCP DNS query"
                            );

                            unwrap_or_debug!(
                                self.tcp_dns_server.send_message(
                                    query.socket,
                                    dns::servfail(message.for_slice_ref())
                                ),
                                "Failed to send TCP DNS response: {}"
                            );
                            return;
                        }
                    };

                    let existing = self
                        .tcp_dns_sockets_by_upstream_and_query_id
                        .insert((server, query_id), query.socket);

                    debug_assert!(existing.is_none(), "Query IDs should be unique");

                    return;
                }

                tracing::trace!(%server, %query_id, "Forwarding TCP DNS query");

                self.buffered_dns_queries
                    .push_back(dns::RecursiveQuery::via_tcp(query.socket, server, message));
            }
        };
    }

    fn maybe_update_tun_routes(&mut self) {
        self.active_cidr_resources = self.recalculate_active_cidr_resources();

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

        // Ensure we don't emit multiple interface updates in a row.
        self.buffered_events
            .retain(|e| !matches!(e, ClientEvent::TunInterfaceUpdated(_)));

        self.tun_config = Some(new_tun_config.clone());
        self.buffered_events
            .push_back(ClientEvent::TunInterfaceUpdated(new_tun_config));

        self.initialise_tcp_dns_client();
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

    pub(crate) fn reset(&mut self) {
        tracing::info!("Resetting network state");

        self.node.reset();
        self.recently_connected_gateways.clear(); // Ensure we don't have sticky gateways when we roam.
        self.dns_resource_nat_by_gateway.clear();
        self.drain_node_events();

        // Resetting the client will trigger a failed `QueryResult` for each one that is in-progress.
        // Failed queries get translated into `SERVFAIL` responses to the client.
        // This will also allocate new local ports for our outgoing TCP connections.
        self.initialise_tcp_dns_client();
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
            return;
        }

        let added = match &new_resource {
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

        if !added {
            return;
        }

        let name = new_resource.name();
        let address = new_resource.address_string().map(tracing::field::display);
        let sites = new_resource.sites_string();

        tracing::info!(%name, address, %sites, "Activating resource");

        self.maybe_update_tun_routes();
        self.emit_resources_changed();
    }

    #[tracing::instrument(level = "debug", skip_all, fields(?id))]
    pub fn remove_resource(&mut self, id: ResourceId) {
        self.disable_resource(id);
        self.resources_by_id.remove(&id);
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
        let gateway_id = peer.id();

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

        // If there's no allowed ip left we remove the whole peer because there's no point on keeping it around
        if peer.allowed_ips.is_empty() {
            self.peers.remove(&gateway_id);
            self.update_site_status_by_gateway(&gateway_id, ResourceStatus::Unknown);
            // TODO: should we have a Node::remove_connection?
        }

        self.resources_gateways.remove(&id);
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
            ip4: config.ip4,
            ip6: config.ip6,
            dns_by_sentinel: dns_mapping
                .iter()
                .map(|(sentinel_dns, effective_dns)| (*sentinel_dns, effective_dns.address()))
                .collect::<BiMap<_, _>>(),
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

fn parse_udp_dns_message<'b>(datagram: &UdpSlice<'b>) -> anyhow::Result<Message<&'b [u8]>> {
    let port = datagram.destination_port();

    anyhow::ensure!(
        port == DNS_PORT,
        "DNS over UDP is only supported on port 53"
    );

    let message = Message::from_octets(datagram.payload())
        .context("Failed to parse payload as DNS message")?;

    Ok(message)
}

fn handle_p2p_control_packet(
    gid: GatewayId,
    fz_p2p_control: ip_packet::FzP2pControlSlice,
    dns_resource_nat_by_gateway: &mut BTreeMap<(GatewayId, DomainName), DnsResourceNatState>,
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

            tracing::debug!(%gid, domain = %res.domain, "DNS resource NAT is active");

            nat_state.confirm();
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
        tracing::warn!("No system default DNS servers available! Can't initialize resolver. DNS interception will be disabled.");
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

fn maybe_mangle_dns_response_from_cidr_resource(
    mut packet: IpPacket,
    dns_mapping: &BiMap<IpAddr, DnsServer>,
    mangeled_dns_queries: &mut HashMap<(SocketAddr, u16), Instant>,
    now: Instant,
) -> IpPacket {
    let src_ip = packet.source();

    let Some(udp) = packet.as_udp() else {
        return packet;
    };

    let src_port = udp.source_port();
    let src_socket = SocketAddr::new(src_ip, src_port);

    let Some(sentinel) = dns_mapping.get_by_right(&DnsServer::from(src_socket)) else {
        return packet;
    };

    let Ok(message) = domain::base::Message::from_slice(udp.payload()) else {
        return packet;
    };

    let Some(query_sent_at) = mangeled_dns_queries
        .remove(&(src_socket, message.header().id()))
        .map(|expires_at| expires_at - IDS_EXPIRE)
    else {
        return packet;
    };

    let rtt = now.duration_since(query_sent_at);

    let domain = message
        .sole_question()
        .ok()
        .map(|q| q.into_qname())
        .map(tracing::field::display);

    tracing::trace!(server = %src_ip, query_id = %message.header().id(), ?rtt, domain, "Received UDP DNS response via tunnel");

    packet.set_src(*sentinel);
    packet.update_checksum();

    packet
}

fn truncate_dns_response(message: &Message<Vec<u8>>) -> Vec<u8> {
    let mut message_bytes = message.as_octets().to_vec();

    if message_bytes.len() > MAX_DATAGRAM_PAYLOAD {
        tracing::debug!(?message, message_length = %message_bytes.len(), "Too big DNS response, truncating");

        let mut new_message = message.clone();
        new_message.header_mut().set_tc(true);

        let message_truncation = match message.answer() {
            Ok(answer) if answer.pos() <= MAX_DATAGRAM_PAYLOAD => answer.pos(),
            // This should be very unlikely or impossible.
            _ => message.question().pos(),
        };

        message_bytes = new_message.as_octets().to_vec();

        message_bytes.truncate(message_truncation);
    }

    message_bytes
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
            assert!(sentinel_dns
                .get_by_right(&server)
                .is_some_and(|s| sentinel_ranges().iter().any(|e| e.contains(*s))))
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
            ClientState::new(BTreeMap::new(), rand::random(), Instant::now())
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
