use super::{
    QueryId,
    dns_records::DnsRecords,
    reference::{PrivateKey, private_key},
    sim_net::{Host, any_ip_stack, host},
    sim_relay::{SimRelay, map_explode},
    strategies::latency,
    transition::{DPort, Destination, DnsQuery, DnsTransport, Identifier, SPort, Seq},
};
use crate::{
    ClientState, DnsMapping, DnsResourceRecord, dns,
    messages::{UpstreamDo53, UpstreamDoH},
    proptest::*,
};
use crate::{
    client::{CidrResource, DnsResource, InternetResource, Resource},
    messages::Interface,
};
use chrono::{DateTime, Utc};
use connlib_model::{ClientId, GatewayId, RelayId, ResourceId, ResourceStatus, Site, SiteId};
use dns_types::{DomainName, Query, RecordData, RecordType};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_network_table::IpNetworkTable;
use ip_packet::{Icmpv4Type, Icmpv6Type, IpPacket, Layer4Protocol};
use itertools::Itertools as _;
use proptest::prelude::*;
use snownet::Transmit;
use std::{
    collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque},
    iter, mem,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    num::NonZeroU16,
    time::Instant,
};

/// Simulation state for a particular client.
pub(crate) struct SimClient {
    pub(crate) id: ClientId,

    pub(crate) sut: ClientState,

    /// The DNS records created on the client as a result of received DNS responses.
    ///
    /// This contains results from both, queries to DNS resources and non-resources.
    pub(crate) dns_records: HashMap<DomainName, Vec<IpAddr>>,

    /// The current DNS resource records emitted by the client.
    ///
    /// In a real system, these would be cached on the local file system
    /// or somewhere where they survive a restart.
    pub(crate) dns_resource_record_cache: BTreeSet<DnsResourceRecord>,

    /// Bi-directional mapping between connlib's sentinel DNS IPs and the effective DNS servers.
    dns_by_sentinel: DnsMapping,

    pub(crate) routes: BTreeSet<IpNetwork>,

    /// The search-domain emitted by connlib.
    pub(crate) search_domain: Option<DomainName>,

    pub(crate) resource_status: BTreeMap<ResourceId, ResourceStatus>,

    pub(crate) sent_udp_dns_queries: HashMap<(dns::Upstream, QueryId, u16), IpPacket>,
    pub(crate) received_udp_dns_responses: BTreeMap<(dns::Upstream, QueryId, u16), IpPacket>,

    pub(crate) sent_tcp_dns_queries: HashSet<(dns::Upstream, QueryId)>,
    pub(crate) received_tcp_dns_responses: BTreeSet<(dns::Upstream, QueryId)>,

    pub(crate) sent_icmp_requests: HashMap<(Seq, Identifier), IpPacket>,
    pub(crate) received_icmp_replies: BTreeMap<(Seq, Identifier), IpPacket>,

    pub(crate) sent_udp_requests: HashMap<(SPort, DPort), IpPacket>,
    pub(crate) received_udp_replies: BTreeMap<(SPort, DPort), IpPacket>,

    pub(crate) tcp_dns_client: dns_over_tcp::Client,

    /// TCP connections to resources.
    pub(crate) tcp_client: crate::tests::tcp::Client,
    pub(crate) failed_tcp_packets: BTreeMap<(SPort, DPort), IpPacket>,
}

impl SimClient {
    pub(crate) fn new(id: ClientId, sut: ClientState, now: Instant) -> Self {
        Self {
            id,
            sut,
            dns_records: Default::default(),
            dns_by_sentinel: Default::default(),
            sent_udp_dns_queries: Default::default(),
            received_udp_dns_responses: Default::default(),
            sent_tcp_dns_queries: Default::default(),
            received_tcp_dns_responses: Default::default(),
            sent_icmp_requests: Default::default(),
            received_icmp_replies: Default::default(),
            sent_udp_requests: Default::default(),
            received_udp_replies: Default::default(),
            routes: Default::default(),
            search_domain: Default::default(),
            resource_status: Default::default(),
            tcp_dns_client: dns_over_tcp::Client::new(now, [0u8; 32]),
            tcp_client: crate::tests::tcp::Client::new(now),
            failed_tcp_packets: Default::default(),
            dns_resource_record_cache: Default::default(),
        }
    }

    pub(crate) fn restart(
        &mut self,
        key: PrivateKey,
        is_internet_resource_active: bool,
        now: Instant,
        utc_now: DateTime<Utc>,
    ) {
        let dns_resource_records = self.dns_resource_record_cache.clone();

        // Overwrite the ClientState with a new key.
        // This is effectively the same as restarting a client / signing out and in again.
        //
        // We keep all the state in `SimClient` which is equivalent to host system.
        // That is where we cache resolved DNS names for example.
        self.sut = ClientState::new(
            key.0,
            dns_resource_records,
            is_internet_resource_active,
            now,
            utc_now
                .signed_duration_since(DateTime::UNIX_EPOCH)
                .to_std()
                .unwrap(),
        );

        self.search_domain = None;
        self.dns_by_sentinel = DnsMapping::default();
        self.routes.clear();
    }

    /// Returns the _effective_ DNS servers that connlib is using.
    pub(crate) fn effective_dns_servers(&self) -> Vec<dns::Upstream> {
        self.dns_by_sentinel.upstream_servers()
    }

    pub(crate) fn effective_search_domain(&self) -> Option<DomainName> {
        self.search_domain.clone()
    }

    pub(crate) fn set_new_dns_servers(&mut self, mapping: DnsMapping) {
        self.dns_by_sentinel = mapping;
        self.tcp_dns_client.reset();
    }

    pub(crate) fn dns_mapping(&self) -> &DnsMapping {
        &self.dns_by_sentinel
    }

    pub(crate) fn send_dns_query_for(
        &mut self,
        domain: DomainName,
        r_type: RecordType,
        query_id: u16,
        upstream: dns::Upstream,
        dns_transport: DnsTransport,
        now: Instant,
    ) -> Option<Transmit> {
        let Some(sentinel) = self.dns_by_sentinel.sentinel_by_upstream(&upstream) else {
            tracing::error!(%upstream, "Unknown DNS server");
            return None;
        };

        tracing::debug!(%sentinel, %domain, "Sending DNS query");

        let src = self
            .sut
            .tunnel_ip_for(sentinel)
            .expect("tunnel should be initialised");

        let query = Query::new(domain, r_type).with_id(query_id);

        match dns_transport {
            DnsTransport::Udp { local_port } => {
                let packet =
                    ip_packet::make::udp_packet(src, sentinel, local_port, 53, query.into_bytes())
                        .unwrap();

                self.sent_udp_dns_queries
                    .insert((upstream, query_id, local_port), packet.clone());
                self.encapsulate(packet, now)
            }
            DnsTransport::Tcp => {
                self.tcp_dns_client
                    .send_query(SocketAddr::new(sentinel, 53), query)
                    .unwrap();
                self.sent_tcp_dns_queries.insert((upstream, query_id));

                None
            }
        }
    }

    pub fn connect_tcp(&mut self, src: IpAddr, dst: IpAddr, sport: SPort, dport: DPort) {
        let local = SocketAddr::new(src, sport.0);
        let remote = SocketAddr::new(dst, dport.0);

        if let Err(e) = self.tcp_client.connect(local, remote) {
            tracing::error!("TCP connect failed: {e:#}")
        }
    }

    pub(crate) fn encapsulate(
        &mut self,
        packet: IpPacket,
        now: Instant,
    ) -> Option<snownet::Transmit> {
        self.update_sent_requests(&packet);

        let Some(transmit) = self.sut.handle_tun_input(packet, now) else {
            self.sut.handle_timeout(now); // If we handled the packet internally, make sure to advance state.
            return None;
        };

        Some(transmit)
    }

    pub fn poll_outbound(&mut self) -> Option<IpPacket> {
        self.tcp_dns_client
            .poll_outbound()
            .or_else(|| self.tcp_client.poll_outbound())
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.tcp_dns_client.handle_timeout(now);
        self.tcp_client.handle_timeout(now);

        if self.sut.poll_timeout().is_some_and(|(t, _)| t <= now) {
            self.sut.handle_timeout(now)
        }
    }

    fn update_sent_requests(&mut self, packet: &IpPacket) {
        if let Some(icmp) = packet.as_icmpv4()
            && let Icmpv4Type::EchoRequest(echo) = icmp.icmp_type()
        {
            self.sent_icmp_requests
                .insert((Seq(echo.seq), Identifier(echo.id)), packet.clone());
            return;
        }

        if let Some(icmp) = packet.as_icmpv6()
            && let Icmpv6Type::EchoRequest(echo) = icmp.icmp_type()
        {
            self.sent_icmp_requests
                .insert((Seq(echo.seq), Identifier(echo.id)), packet.clone());
            return;
        }

        if let Some(udp) = packet.as_udp() {
            self.sent_udp_requests.insert(
                (SPort(udp.source_port()), DPort(udp.destination_port())),
                packet.clone(),
            );
        }
    }

    pub(crate) fn receive(&mut self, transmit: Transmit, now: Instant) {
        let Some(packet) = self.sut.handle_network_input(
            transmit.dst,
            transmit.src.unwrap(),
            &transmit.payload,
            now,
        ) else {
            self.sut.handle_timeout(now);
            return;
        };

        self.on_received_packet(packet);
    }

    /// Process an IP packet received on the client.
    pub(crate) fn on_received_packet(&mut self, packet: IpPacket) {
        match packet.icmp_error() {
            Ok(Some((failed_packet, _))) => {
                match failed_packet.layer4_protocol() {
                    Layer4Protocol::Udp { src, dst } => {
                        self.received_udp_replies
                            .insert((SPort(dst), DPort(src)), packet);
                    }
                    Layer4Protocol::Tcp { src, dst } => {
                        self.failed_tcp_packets
                            .insert((SPort(src), DPort(dst)), packet.clone());

                        // Allow the client to process the ICMP error.
                        self.tcp_client.handle_inbound(packet);
                    }
                    Layer4Protocol::Icmp { seq, id } => {
                        self.received_icmp_replies
                            .insert((Seq(seq), Identifier(id)), packet);
                    }
                }

                return;
            }
            Ok(None) => {}
            Err(e) => {
                tracing::error!("Failed to extract ICMP unreachable destination: {e:#}")
            }
        }

        if let Some(udp) = packet.as_udp() {
            if udp.source_port() == 53 {
                let response = dns_types::Response::parse(udp.payload())
                    .expect("ip packets on port 53 to be DNS packets");

                // Map back to upstream socket so we can assert on it correctly.
                let sentinel = packet.source();
                let Some(upstream) = self.dns_by_sentinel.upstream_by_sentinel(sentinel) else {
                    tracing::error!(%sentinel, mapping = ?self.dns_by_sentinel, "Unknown DNS server");
                    return;
                };

                self.received_udp_dns_responses.insert(
                    (upstream, response.id(), udp.destination_port()),
                    packet.clone(),
                );

                if !response.truncated() {
                    self.handle_dns_response(&response);
                }

                return;
            }

            self.received_udp_replies.insert(
                (SPort(udp.source_port()), DPort(udp.destination_port())),
                packet.clone(),
            );
            return;
        }

        if self.tcp_dns_client.accepts(&packet) {
            self.tcp_dns_client.handle_inbound(packet);
            return;
        }

        if self.tcp_client.accepts(&packet) {
            self.tcp_client.handle_inbound(packet);
            return;
        }

        if let Some(icmp) = packet.as_icmpv4()
            && let Icmpv4Type::EchoReply(echo) = icmp.icmp_type()
        {
            self.received_icmp_replies
                .insert((Seq(echo.seq), Identifier(echo.id)), packet.clone());
            return;
        }

        if let Some(icmp) = packet.as_icmpv6()
            && let Icmpv6Type::EchoReply(echo) = icmp.icmp_type()
        {
            self.received_icmp_replies
                .insert((Seq(echo.seq), Identifier(echo.id)), packet.clone());
            return;
        }

        tracing::error!(?packet, "Unhandled packet");
    }

    pub(crate) fn update_relays<'a>(
        &mut self,
        to_remove: impl Iterator<Item = RelayId>,
        to_add: impl Iterator<Item = (&'a RelayId, &'a Host<SimRelay>)> + 'a,
        now: Instant,
    ) {
        self.sut.update_relays(
            to_remove.collect(),
            map_explode(to_add, "client").collect(),
            now,
        )
    }

    pub(crate) fn handle_dns_response(&mut self, response: &dns_types::Response) {
        for record in response.records() {
            #[expect(clippy::wildcard_enum_match_arm)]
            let ip = match record.data() {
                RecordData::A(a) => IpAddr::from(a.addr()),
                RecordData::Aaaa(aaaa) => IpAddr::from(aaaa.addr()),
                RecordData::Ptr(_) => {
                    continue;
                }
                RecordData::Txt(_) => {
                    continue;
                }
                RecordData::Srv(_) => {
                    continue;
                }
                unhandled => {
                    panic!("Unexpected record data: {unhandled:?}")
                }
            };

            self.dns_records
                .entry(response.domain())
                .or_default()
                .push(ip);
        }

        // Ensure all IPs are always sorted.
        for ips in self.dns_records.values_mut() {
            ips.sort()
        }
    }
}

/// Reference state for a particular client.
///
/// The reference state machine is designed to be as abstract as possible over connlib's functionality.
/// For example, we try to model connectivity to _resources_ and don't really care, which gateway is being used to route us there.
#[derive(Clone, derive_more::Debug)]
pub struct RefClient {
    pub(crate) id: ClientId,
    pub(crate) key: PrivateKey,
    pub(crate) tunnel_ip4: Ipv4Addr,
    pub(crate) tunnel_ip6: Ipv6Addr,

    /// The DNS resolvers configured on the client outside of connlib.
    #[debug(skip)]
    system_dns_resolvers: Vec<IpAddr>,
    /// The upstream Do53 resolvers configured in the portal.
    #[debug(skip)]
    upstream_do53_resolvers: Vec<UpstreamDo53>,
    /// The upstream DoH resolvers configured in the portal.
    #[debug(skip)]
    upstream_doh_resolvers: Vec<UpstreamDoH>,
    /// The search-domain configured in the portal.
    pub(crate) search_domain: Option<DomainName>,

    routes: Vec<(ResourceId, IpNetwork)>,

    /// Tracks all resources in the order they have been added in.
    ///
    /// When reconnecting to the portal, we simulate them being re-added in the same order.
    #[debug(skip)]
    resources: Vec<Resource>,

    pub(crate) internet_resource_active: bool,

    /// The CIDR resources the client is aware of.
    #[debug(skip)]
    cidr_resources: IpNetworkTable<ResourceId>,

    /// The client's DNS records.
    ///
    /// The IPs assigned to a domain by connlib are an implementation detail that we don't want to model in these tests.
    /// Instead, we just remember what _kind_ of records we resolved to be able to sample a matching src IP.
    #[debug(skip)]
    pub(crate) dns_records: BTreeMap<DomainName, BTreeSet<RecordType>>,

    /// Whether we are connected to the gateway serving the Internet resource.
    #[debug(skip)]
    pub(crate) connected_internet_resource: bool,

    /// The CIDR resources the client is connected to.
    #[debug(skip)]
    pub(crate) connected_cidr_resources: BTreeSet<ResourceId>,

    /// The DNS resources the client is connected to.
    #[debug(skip)]
    pub(crate) connected_dns_resources: BTreeSet<ResourceId>,

    /// The [`ResourceStatus`] of each site.
    #[debug(skip)]
    site_status: BTreeMap<SiteId, ResourceStatus>,

    /// The expected ICMP handshakes.
    #[debug(skip)]
    pub(crate) expected_icmp_handshakes:
        BTreeMap<GatewayId, BTreeMap<u64, (Destination, Seq, Identifier)>>,

    /// The expected UDP handshakes.
    #[debug(skip)]
    pub(crate) expected_udp_handshakes:
        BTreeMap<GatewayId, BTreeMap<u64, (Destination, SPort, DPort)>>,

    /// The expected TCP connections.
    #[debug(skip)]
    pub(crate) expected_tcp_connections: BTreeMap<(IpAddr, Destination, SPort, DPort), ResourceId>,

    /// The expected UDP DNS handshakes.
    #[debug(skip)]
    pub(crate) expected_udp_dns_handshakes: VecDeque<(dns::Upstream, QueryId, u16)>,
    /// The expected TCP DNS handshakes.
    #[debug(skip)]
    pub(crate) expected_tcp_dns_handshakes: VecDeque<(dns::Upstream, QueryId)>,
}

impl RefClient {
    /// Initialize the [`ClientState`].
    ///
    /// This simulates receiving the `init` message from the portal.
    pub(crate) fn init(self, now: Instant, utc_now: DateTime<Utc>) -> SimClient {
        let mut client_state = ClientState::new(
            self.key.0,
            Default::default(),
            self.internet_resource_active,
            now,
            utc_now
                .signed_duration_since(DateTime::UNIX_EPOCH)
                .to_std()
                .unwrap(),
        ); // Cheating a bit here by reusing the key as seed.
        client_state.update_interface_config(Interface {
            ipv4: self.tunnel_ip4,
            ipv6: self.tunnel_ip6,
            upstream_dns: Vec::new(),
            upstream_do53: self.upstream_do53_resolvers.clone(),
            upstream_doh: self.upstream_doh_resolvers,
            search_domain: self.search_domain.clone(),
        });
        client_state.update_system_resolvers(self.system_dns_resolvers.clone());

        SimClient::new(self.id, client_state, now)
    }

    pub(crate) fn disconnect_resource(&mut self, resource: &ResourceId) {
        for _ in self.routes.extract_if(.., |(r, _)| r == resource) {}

        self.connected_cidr_resources.remove(resource);
        self.connected_dns_resources.remove(resource);

        if self.internet_resource().is_some_and(|r| r == *resource) {
            self.connected_internet_resource = false;
        }

        let Some(site) = self.site_for_resource(*resource) else {
            tracing::error!(%resource, "No site for resource");
            return;
        };

        // If this was the last resource we were connected to for this site,
        // the connection will be GC'd.
        if self
            .connected_resources()
            .all(|r| self.site_for_resource(r).is_some_and(|s| s != site))
        {
            tracing::debug!(
                last_resource = %resource,
                site = %site.id,
                "We are no longer connected to any resources in this site"
            );

            self.site_status.remove(&site.id);
        }
    }

    pub(crate) fn set_internet_resource_state(&mut self, active: bool) {
        let resource = self
            .resources
            .iter()
            .find(|r| matches!(r, Resource::Internet(_)));

        self.internet_resource_active = active;

        let Some(resource) = resource else {
            return;
        };

        if active {
            self.routes
                .push((resource.id(), Ipv4Network::DEFAULT_ROUTE.into()));
            self.routes
                .push((resource.id(), Ipv6Network::DEFAULT_ROUTE.into()));
        } else {
            self.disconnect_resource(&resource.id());
        }
    }

    pub(crate) fn remove_resource(&mut self, resource: &ResourceId) {
        self.disconnect_resource(resource);

        if self.internet_resource().is_some_and(|r| r == *resource) {
            self.internet_resource_active = false;
        }

        self.resources.retain(|r| r.id() != *resource);

        self.cidr_resources = self.recalculate_cidr_routes();
    }

    pub(crate) fn connected_resources(&self) -> impl Iterator<Item = ResourceId> + '_ {
        iter::empty()
            .chain(self.connected_cidr_resources.clone())
            .chain(self.connected_dns_resources.clone())
            .chain(
                self.connected_internet_resource
                    .then(|| self.internet_resource())
                    .flatten(),
            )
    }

    fn recalculate_cidr_routes(&mut self) -> IpNetworkTable<ResourceId> {
        let mut table = IpNetworkTable::<ResourceId>::new();
        for resource in self.resources.iter().sorted_by_key(|r| r.id()) {
            let Resource::Cidr(resource) = resource else {
                continue;
            };

            if let Some(overlapping_resource) = table.exact_match(resource.address)
                && self.is_connected_to_internet_or_cidr(*overlapping_resource)
            {
                tracing::debug!(%overlapping_resource, rid = %resource.id, address = %resource.address, "Already connected to resource with this exact address, retaining existing route");

                continue;
            }

            tracing::debug!(rid = %resource.id, address = %resource.address, "Adding CIDR route");

            table.insert(resource.address, resource.id);
        }

        table
    }

    pub(crate) fn restart(&mut self, key: PrivateKey) {
        self.search_domain = None;
        self.routes.clear();

        self.key = key;

        self.reset_connections();
        self.readd_all_resources();
    }

    pub(crate) fn reset_connections(&mut self) {
        self.connected_cidr_resources.clear();
        self.connected_dns_resources.clear();
        self.connected_internet_resource = false;

        for status in self.site_status.values_mut() {
            *status = ResourceStatus::Unknown;
        }
    }

    pub(crate) fn add_internet_resource(&mut self, resource: InternetResource) {
        self.resources.push(Resource::Internet(resource.clone()));

        if self.internet_resource_active {
            self.routes
                .push((resource.id, Ipv4Network::DEFAULT_ROUTE.into()));
            self.routes
                .push((resource.id, Ipv6Network::DEFAULT_ROUTE.into()));
        }
    }

    pub(crate) fn add_cidr_resource(&mut self, r: CidrResource) {
        let address = r.address;
        let r = Resource::Cidr(r);
        let rid = r.id();

        if let Some(existing) = self.resources.iter().find(|existing| existing.id() == rid)
            && (existing.has_different_address(&r) || existing.has_different_site(&r))
        {
            self.remove_resource(&existing.id());
        }

        self.resources.push(r);
        self.cidr_resources = self.recalculate_cidr_routes();
        self.routes.push((rid, address));

        if self.expected_tcp_connections.values().contains(&rid) {
            self.set_resource_online(rid);
        }
    }

    pub(crate) fn add_dns_resource(&mut self, r: DnsResource) {
        let r = Resource::Dns(r);
        let rid = r.id();

        if let Some(existing) = self.resources.iter().find(|existing| existing.id() == rid)
            && (existing.has_different_address(&r)
                || existing.has_different_ip_stack(&r)
                || existing.has_different_site(&r))
        {
            self.remove_resource(&existing.id());
        }

        self.resources.push(r);

        if self.expected_tcp_connections.values().contains(&rid) {
            self.set_resource_online(rid);
        }
    }

    /// Re-adds all resources in the order they have been initially added.
    pub(crate) fn readd_all_resources(&mut self) {
        self.cidr_resources = IpNetworkTable::new();

        for resource in mem::take(&mut self.resources) {
            match resource {
                Resource::Dns(d) => self.add_dns_resource(d),
                Resource::Cidr(c) => self.add_cidr_resource(c),
                Resource::Internet(i) => self.add_internet_resource(i),
            }
        }
    }

    pub(crate) fn expected_resource_status(&self) -> BTreeMap<ResourceId, ResourceStatus> {
        self.resources
            .iter()
            .filter_map(|r| {
                let status = self
                    .site_status
                    .get(&r.site().ok()?.id)
                    .copied()
                    .unwrap_or(ResourceStatus::Unknown);

                Some((r.id(), status))
            })
            .collect()
    }

    /// Returns the list of resources where we are not "sure" whether they are online or unknown.
    ///
    /// Resources with TCP connections have an automatic retry and therefore, modelling their exact online/unknown state is difficult.
    pub(crate) fn maybe_online_resources(&self) -> BTreeSet<ResourceId> {
        let resources_with_tcp_connections = self
            .expected_tcp_connections
            .values()
            .copied()
            .collect::<BTreeSet<_>>();

        let maybe_online_sites = resources_with_tcp_connections
            .into_iter()
            .flat_map(|r| self.site_for_resource(r))
            .collect::<BTreeSet<_>>();

        self.resources
            .iter()
            .filter_map(move |r| {
                maybe_online_sites
                    .contains(r.site().unwrap())
                    .then_some(r.id())
            })
            .collect()
    }

    pub(crate) fn tunnel_ip_for(&self, dst: IpAddr) -> IpAddr {
        match dst {
            IpAddr::V4(_) => self.tunnel_ip4.into(),
            IpAddr::V6(_) => self.tunnel_ip6.into(),
        }
    }

    pub(crate) fn on_icmp_packet(
        &mut self,
        dst: Destination,
        seq: Seq,
        identifier: Identifier,
        payload: u64,
        gateway_by_resource: impl Fn(ResourceId) -> Option<GatewayId>,
        gateway_by_ip: impl Fn(IpAddr) -> Option<GatewayId>,
    ) {
        self.on_packet(
            dst.clone(),
            (dst, seq, identifier),
            |ref_client| &mut ref_client.expected_icmp_handshakes,
            payload,
            gateway_by_resource,
            gateway_by_ip,
        );
    }

    pub(crate) fn on_udp_packet(
        &mut self,
        dst: Destination,
        sport: SPort,
        dport: DPort,
        payload: u64,
        gateway_by_resource: impl Fn(ResourceId) -> Option<GatewayId>,
        gateway_by_ip: impl Fn(IpAddr) -> Option<GatewayId>,
    ) {
        self.on_packet(
            dst.clone(),
            (dst, sport, dport),
            |ref_client| &mut ref_client.expected_udp_handshakes,
            payload,
            gateway_by_resource,
            gateway_by_ip,
        );
    }

    #[tracing::instrument(level = "debug", skip_all, fields(dst, resource, gateway))]
    fn on_packet<E>(
        &mut self,
        dst: Destination,
        packet_id: E,
        map: impl FnOnce(&mut Self) -> &mut BTreeMap<GatewayId, BTreeMap<u64, E>>,
        payload: u64,
        gateway_by_resource: impl Fn(ResourceId) -> Option<GatewayId>,
        gateway_by_ip: impl Fn(IpAddr) -> Option<GatewayId>,
    ) {
        let gateway = if dst.ip_addr().is_some_and(crate::is_peer) {
            let Some(gateway) = gateway_by_ip(dst.ip_addr().unwrap()) else {
                tracing::error!("Unknown gateway");
                return;
            };
            tracing::Span::current().record("gateway", tracing::field::display(gateway));

            gateway
        } else {
            let Some(resource) = self.resource_by_dst(&dst) else {
                tracing::warn!("Unknown resource");
                return;
            };

            tracing::Span::current().record("resource", tracing::field::display(resource));

            let Some(gateway) = gateway_by_resource(resource) else {
                tracing::error!("No gateway for resource");
                return;
            };

            tracing::Span::current().record("gateway", tracing::field::display(gateway));

            self.connect_to_resource(resource, dst);
            self.set_resource_online(resource);

            gateway
        };

        tracing::debug!(%payload, "Sending packet");

        map(self)
            .entry(gateway)
            .or_default()
            .insert(payload, packet_id);
    }

    pub(crate) fn on_connect_tcp(
        &mut self,
        src: IpAddr,
        dst: Destination,
        sport: SPort,
        dport: DPort,
    ) {
        let Some(resource) = self.resource_by_dst(&dst) else {
            tracing::warn!("Unknown resource");
            return;
        };

        self.connect_to_resource(resource, dst.clone());
        self.set_resource_online(resource);

        self.expected_tcp_connections
            .insert((src, dst, sport, dport), resource);
    }

    fn connect_to_resource(&mut self, resource: ResourceId, destination: Destination) {
        match destination {
            Destination::DomainName { .. } => {
                self.connected_dns_resources.insert(resource);
            }
            Destination::IpAddr(_) => self.connect_to_internet_or_cidr_resource(resource),
        }
    }

    fn set_resource_online(&mut self, rid: ResourceId) {
        let Some(site) = self.site_for_resource(rid) else {
            tracing::error!(%rid, "Unknown resource or multi-site resource");
            return;
        };

        let previous = self.site_status.insert(site.id, ResourceStatus::Online);

        if previous.is_none_or(|s| s != ResourceStatus::Online) {
            tracing::debug!(%rid, sid = %site.id, "Resource is now online");
        }
    }

    fn is_connected_to_internet_or_cidr(&self, resource: ResourceId) -> bool {
        self.is_connected_to_cidr(resource) || self.is_connected_to_internet(resource)
    }

    fn connect_to_internet_or_cidr_resource(&mut self, rid: ResourceId) {
        if self.internet_resource_active
            && let Some(internet) = self.internet_resource()
            && internet == rid
        {
            self.connected_internet_resource = true;
            return;
        }

        if self.cidr_resources.iter().any(|(_, r)| *r == rid) {
            let is_new = self.connected_cidr_resources.insert(rid);

            if is_new {
                tracing::debug!(%rid, "Now connected to CIDR resource");
            }
        }
    }

    pub(crate) fn on_dns_query(&mut self, query: &DnsQuery) {
        self.dns_records
            .entry(query.domain.clone())
            .or_default()
            .insert(query.r_type);

        match query.transport {
            DnsTransport::Udp { local_port } => {
                self.expected_udp_dns_handshakes.push_back((
                    query.dns_server.clone(),
                    query.query_id,
                    local_port,
                ));
            }
            DnsTransport::Tcp => {
                self.expected_tcp_dns_handshakes
                    .push_back((query.dns_server.clone(), query.query_id));
            }
        }

        if let Some(resource) = self.is_site_specific_dns_query(query) {
            self.set_resource_online(resource);
            self.connected_dns_resources.insert(resource);
            return;
        }

        if let Some(resource) = self.dns_query_via_resource(query) {
            self.connect_to_internet_or_cidr_resource(resource);
            self.set_resource_online(resource);
        }
    }

    pub(crate) fn ipv4_cidr_resource_dsts(&self) -> Vec<Ipv4Network> {
        self.cidr_resources
            .iter_ipv4()
            .map(|(n, _)| n)
            .collect_vec()
    }

    pub(crate) fn ipv6_cidr_resource_dsts(&self) -> Vec<Ipv6Network> {
        self.cidr_resources
            .iter_ipv6()
            .map(|(n, _)| n)
            .collect_vec()
    }

    fn is_connected_to_internet(&self, id: ResourceId) -> bool {
        self.active_internet_resource() == Some(id) && self.connected_internet_resource
    }

    fn is_connected_to_cidr(&self, id: ResourceId) -> bool {
        self.connected_cidr_resources.contains(&id)
    }

    fn site_for_resource(&self, resource: ResourceId) -> Option<Site> {
        let site = self
            .resources
            .iter()
            .find_map(|r| (r.id() == resource).then_some(r.site()))?
            .ok()?
            .clone();

        Some(site)
    }

    pub(crate) fn active_internet_resource(&self) -> Option<ResourceId> {
        self.internet_resource_active
            .then(|| self.internet_resource())
            .flatten()
    }

    fn resource_by_dst(&self, destination: &Destination) -> Option<ResourceId> {
        match destination {
            Destination::DomainName { name, .. } => {
                if let Some(r) = self.dns_resource_by_domain(name) {
                    return Some(r.id);
                }
            }
            Destination::IpAddr(addr) => {
                if let Some(id) = self.cidr_resource_by_ip(*addr) {
                    return Some(id);
                }
            }
        }

        self.active_internet_resource()
    }

    pub(crate) fn dns_resource_by_domain(&self, domain: &DomainName) -> Option<DnsResource> {
        self.resources
            .iter()
            .cloned()
            .filter_map(|r| r.into_dns())
            .filter(|r| is_subdomain(&domain.to_string(), &r.address))
            .sorted_by_key(|r| r.address.len())
            .next_back()
    }

    fn resolved_domains(&self) -> impl Iterator<Item = (DomainName, BTreeSet<RecordType>)> + '_ {
        self.dns_records
            .iter()
            .filter(|(domain, _)| self.dns_resource_by_domain(domain).is_some())
            .map(|(domain, ips)| (domain.clone(), ips.clone()))
    }

    /// An ICMP packet is valid if we didn't yet send an ICMP packet with the same seq, identifier and payload.
    pub(crate) fn is_valid_icmp_packet(
        &self,
        seq: &Seq,
        identifier: &Identifier,
        payload: &u64,
    ) -> bool {
        self.expected_icmp_handshakes.values().flatten().all(
            |(existig_payload, (_, existing_seq, existing_identifier))| {
                existing_seq != seq
                    && existing_identifier != identifier
                    && existig_payload != payload
            },
        )
    }

    /// An UDP packet is valid if we didn't yet send an UDP packet with the same sport, dport and payload.
    pub(crate) fn is_valid_udp_packet(&self, sport: &SPort, dport: &DPort, payload: &u64) -> bool {
        self.expected_udp_handshakes.values().flatten().all(
            |(existig_payload, (_, existing_sport, existing_dport))| {
                existing_dport != dport && existing_sport != sport && existig_payload != payload
            },
        )
    }

    pub(crate) fn resolved_v4_domains(&self) -> Vec<DomainName> {
        self.resolved_domains()
            .filter_map(|(domain, records)| {
                records
                    .iter()
                    .any(|r| matches!(r, &RecordType::A))
                    .then_some(domain)
            })
            .filter(|d| {
                self.dns_resource_by_domain(d)
                    .is_some_and(|r| r.ip_stack.supports_ipv4())
            })
            .collect()
    }

    pub(crate) fn resolved_v6_domains(&self) -> Vec<DomainName> {
        self.resolved_domains()
            .filter_map(|(domain, records)| {
                records
                    .iter()
                    .any(|r| matches!(r, &RecordType::AAAA))
                    .then_some(domain)
            })
            .filter(|d| {
                self.dns_resource_by_domain(d)
                    .is_some_and(|r| r.ip_stack.supports_ipv6())
            })
            .collect()
    }

    /// Returns the DNS servers that we expect connlib to use.
    ///
    /// If there are upstream Do53 servers configured in the portal, it should use those.
    /// If there are no custom servers defined, it should use the DoH servers specified in the portal.
    /// Otherwise it should use whatever was configured on the system prior to connlib starting.
    ///
    /// This purposely returns a `Vec` so we also assert the order!
    pub(crate) fn expected_dns_servers(&self) -> Vec<dns::Upstream> {
        if !self.upstream_do53_resolvers.is_empty() {
            return self
                .upstream_do53_resolvers
                .iter()
                .map(|u| dns::Upstream::Do53 {
                    server: SocketAddr::new(u.ip, 53),
                })
                .collect();
        }

        if !self.upstream_doh_resolvers.is_empty() {
            return self
                .upstream_doh_resolvers
                .iter()
                .map(|u| dns::Upstream::DoH {
                    server: u.url.clone(),
                })
                .collect();
        }

        self.system_dns_resolvers
            .iter()
            .map(|ip| dns::Upstream::Do53 {
                server: SocketAddr::new(*ip, 53),
            })
            .collect()
    }

    pub(crate) fn expected_search_domain(&self) -> Option<DomainName> {
        self.search_domain.clone()
    }

    pub(crate) fn expected_routes(&self) -> BTreeSet<IpNetwork> {
        iter::empty()
            .chain(self.routes.iter().map(|(_, r)| *r))
            .chain(default_routes_v4())
            .chain(default_routes_v6())
            .collect()
    }

    pub(crate) fn cidr_resource_by_ip(&self, ip: IpAddr) -> Option<ResourceId> {
        // Manually implement `longest_match` because we need to filter disabled resources _before_ we match.
        let (_, r) = self
            .cidr_resources
            .matches(ip)
            .sorted_by(|(n1, _), (n2, _)| n1.netmask().cmp(&n2.netmask()).reverse()) // Highest netmask is most specific.
            .next()?;

        Some(*r)
    }

    pub(crate) fn resolved_ip4_for_non_resources(
        &self,
        global_dns_records: &DnsRecords,
        at: Instant,
    ) -> Vec<Ipv4Addr> {
        self.resolved_ips_for_non_resources(global_dns_records, at)
            .filter_map(|ip| match ip {
                IpAddr::V4(v4) => Some(v4),
                IpAddr::V6(_) => None,
            })
            .collect()
    }

    pub(crate) fn resolved_ip6_for_non_resources(
        &self,
        global_dns_records: &DnsRecords,
        at: Instant,
    ) -> Vec<Ipv6Addr> {
        self.resolved_ips_for_non_resources(global_dns_records, at)
            .filter_map(|ip| match ip {
                IpAddr::V6(v6) => Some(v6),
                IpAddr::V4(_) => None,
            })
            .collect()
    }

    fn resolved_ips_for_non_resources<'a>(
        &'a self,
        global_dns_records: &'a DnsRecords,
        at: Instant,
    ) -> impl Iterator<Item = IpAddr> + 'a {
        self.dns_records
            .iter()
            .filter_map(move |(domain, _)| {
                self.dns_resource_by_domain(domain)
                    .is_none()
                    .then_some(global_dns_records.domain_ips_iter(domain, at))
            })
            .flatten()
    }

    /// Returns the resource we will forward the DNS query for the given name to.
    ///
    /// DNS servers may be resources, in which case queries that need to be forwarded actually need to be encapsulated.
    pub(crate) fn dns_query_via_resource(&self, query: &DnsQuery) -> Option<ResourceId> {
        // Unless we are using upstream resolvers, DNS queries are never routed through the tunnel.
        if self.upstream_do53_resolvers.is_empty() {
            return None;
        }

        // If we are querying a DNS resource, we will issue a connection intent to the DNS resource, not the CIDR resource.
        if self.dns_resource_by_domain(&query.domain).is_some()
            && matches!(
                query.r_type,
                RecordType::A | RecordType::AAAA | RecordType::PTR
            )
        {
            return None;
        }

        let server = match query.dns_server {
            dns::Upstream::Do53 { server } => server,
            dns::Upstream::DoH { .. } => return None,
        };

        let maybe_active_cidr_resource = self.cidr_resource_by_ip(server.ip());
        let maybe_active_internet_resource = self.active_internet_resource();

        maybe_active_cidr_resource.or(maybe_active_internet_resource)
    }

    pub(crate) fn is_site_specific_dns_query(&self, query: &DnsQuery) -> Option<ResourceId> {
        if !matches!(query.r_type, RecordType::SRV | RecordType::TXT) {
            return None;
        }

        Some(self.dns_resource_by_domain(&query.domain)?.id)
    }

    pub(crate) fn all_resource_ids(&self) -> Vec<ResourceId> {
        self.resources.iter().map(|r| r.id()).collect()
    }

    pub(crate) fn has_resource(&self, resource_id: ResourceId) -> bool {
        self.resources.iter().any(|r| r.id() == resource_id)
    }

    pub(crate) fn all_resources(&self) -> Vec<Resource> {
        self.resources.clone()
    }

    fn internet_resource(&self) -> Option<ResourceId> {
        self.resources.iter().find_map(|r| match r {
            Resource::Dns(_) => None,
            Resource::Cidr(_) => None,
            Resource::Internet(internet_resource) => Some(internet_resource.id),
        })
    }

    pub(crate) fn system_dns_resolvers(&self) -> Vec<IpAddr> {
        self.system_dns_resolvers.clone()
    }

    pub(crate) fn set_system_dns_resolvers(&mut self, servers: &Vec<IpAddr>) {
        self.system_dns_resolvers.clone_from(servers);
    }

    pub(crate) fn set_upstream_do53_resolvers(&mut self, servers: &Vec<UpstreamDo53>) {
        self.upstream_do53_resolvers.clone_from(servers);
    }

    pub(crate) fn set_upstream_doh_resolvers(&mut self, servers: &Vec<UpstreamDoH>) {
        self.upstream_doh_resolvers.clone_from(servers);
    }

    pub(crate) fn set_upstream_search_domain(&mut self, domain: Option<&DomainName>) {
        self.search_domain = domain.cloned()
    }

    pub(crate) fn upstream_do53_resolvers(&self) -> Vec<UpstreamDo53> {
        self.upstream_do53_resolvers.clone()
    }

    pub(crate) fn upstream_doh_resolvers(&self) -> Vec<UpstreamDoH> {
        self.upstream_doh_resolvers.clone()
    }

    pub(crate) fn has_tcp_connection(
        &self,
        src: IpAddr,
        dst: Destination,
        sport: SPort,
        dport: DPort,
    ) -> bool {
        self.expected_tcp_connections
            .contains_key(&(src, dst, sport, dport))
    }

    pub(crate) fn tcp_connection_tuple_to_resource(
        &self,
        resource: ResourceId,
    ) -> Option<(SPort, DPort)> {
        self.expected_tcp_connections
            .iter()
            .find_map(|((_, _, sport, dport), res)| (resource == *res).then_some((*sport, *dport)))
    }
}

// This function only works on the tests because we are limited to resources with a single wildcard at the beginning of the resource.
// This limitation doesn't exists in production.
fn is_subdomain(name: &str, record: &str) -> bool {
    if name == record {
        return true;
    }
    let Some((first, end)) = record.split_once('.') else {
        return false;
    };
    match first {
        "**" => name.ends_with(end) && name.strip_suffix(end).is_some_and(|n| n.ends_with('.')),
        "*" => {
            name.ends_with(end)
                && name
                    .strip_suffix(end)
                    .is_some_and(|n| n.ends_with('.') && n.matches('.').count() == 1)
        }
        _ => false,
    }
}

pub(crate) fn ref_client_host(
    tunnel_ip4s: impl Strategy<Value = Ipv4Addr>,
    tunnel_ip6s: impl Strategy<Value = Ipv6Addr>,
    system_dns: impl Strategy<Value = Vec<IpAddr>>,
    upstream_do53: impl Strategy<Value = Vec<UpstreamDo53>>,
    upstream_doh: impl Strategy<Value = Vec<UpstreamDoH>>,
    search_domain: impl Strategy<Value = Option<DomainName>>,
) -> impl Strategy<Value = Host<RefClient>> {
    host(
        any_ip_stack(),
        listening_port(),
        ref_client(
            tunnel_ip4s,
            tunnel_ip6s,
            system_dns,
            upstream_do53,
            upstream_doh,
            search_domain,
        ),
        latency(250), // TODO: Increase with #6062.
    )
}

fn ref_client(
    tunnel_ip4s: impl Strategy<Value = Ipv4Addr>,
    tunnel_ip6s: impl Strategy<Value = Ipv6Addr>,
    system_dns: impl Strategy<Value = Vec<IpAddr>>,
    upstream_do53: impl Strategy<Value = Vec<UpstreamDo53>>,
    upstream_doh: impl Strategy<Value = Vec<UpstreamDoH>>,
    search_domain: impl Strategy<Value = Option<DomainName>>,
) -> impl Strategy<Value = RefClient> {
    (
        tunnel_ip4s,
        tunnel_ip6s,
        system_dns,
        upstream_do53,
        upstream_doh,
        search_domain,
        any::<bool>(),
        client_id(),
        private_key(),
    )
        .prop_map(
            move |(
                tunnel_ip4,
                tunnel_ip6,
                system_dns_resolvers,
                upstream_do53_resolvers,
                upstream_doh_resolvers,
                search_domain,
                internet_resource_active,
                id,
                key,
            )| {
                RefClient {
                    id,
                    key,
                    tunnel_ip4,
                    tunnel_ip6,
                    system_dns_resolvers,
                    upstream_do53_resolvers,
                    upstream_doh_resolvers,
                    search_domain,
                    internet_resource_active,
                    cidr_resources: IpNetworkTable::new(),
                    dns_records: Default::default(),
                    connected_cidr_resources: Default::default(),
                    connected_dns_resources: Default::default(),
                    connected_internet_resource: Default::default(),
                    expected_icmp_handshakes: Default::default(),
                    expected_udp_handshakes: Default::default(),
                    expected_tcp_connections: Default::default(),
                    expected_udp_dns_handshakes: Default::default(),
                    expected_tcp_dns_handshakes: Default::default(),
                    resources: Default::default(),
                    routes: Default::default(),
                    site_status: Default::default(),
                }
            },
        )
}

fn listening_port() -> impl Strategy<Value = u16> {
    prop_oneof![
        Just(52625),
        Just(3478), // Make sure connlib works even if a NAT is re-mapping our public port to a relay port.
        any::<NonZeroU16>().prop_map(|p| p.get()),
    ]
}

fn default_routes_v4() -> Vec<IpNetwork> {
    vec![
        IpNetwork::V4(Ipv4Network::new(Ipv4Addr::new(100, 64, 0, 0), 11).unwrap()),
        IpNetwork::V4(Ipv4Network::new(Ipv4Addr::new(100, 96, 0, 0), 11).unwrap()),
        IpNetwork::V4(Ipv4Network::new(Ipv4Addr::new(100, 100, 111, 0), 24).unwrap()),
    ]
}

fn default_routes_v6() -> Vec<IpNetwork> {
    vec![
        IpNetwork::V6(
            Ipv6Network::new(Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 0), 107).unwrap(),
        ),
        IpNetwork::V6(
            Ipv6Network::new(
                Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0x8000, 0, 0, 0, 0),
                107,
            )
            .unwrap(),
        ),
        IpNetwork::V6(
            Ipv6Network::new(
                Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0x8000, 0x0100, 0x0100, 0x0111, 0),
                120,
            )
            .unwrap(),
        ),
    ]
}
