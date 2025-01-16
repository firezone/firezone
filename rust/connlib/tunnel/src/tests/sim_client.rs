use super::{
    dns_records::DnsRecords,
    reference::{private_key, PrivateKey},
    sim_net::{any_ip_stack, any_port, host, Host},
    sim_relay::{map_explode, SimRelay},
    strategies::latency,
    transition::{DPort, Destination, DnsQuery, DnsTransport, Identifier, SPort, Seq},
    QueryId,
};
use crate::{
    client::{CidrResource, DnsResource, InternetResource, Resource},
    messages::{DnsServer, Interface},
    DomainName,
};
use crate::{proptest::*, ClientState};
use bimap::BiMap;
use connlib_model::{ClientId, GatewayId, RelayId, ResourceId};
use domain::{
    base::{iana::Opcode, Message, MessageBuilder, Question, Rtype, ToName},
    rdata::AllRecordData,
};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_network_table::IpNetworkTable;
use ip_packet::{Icmpv4Type, Icmpv6Type, IpPacket, Layer4Protocol};
use itertools::Itertools as _;
use proptest::prelude::*;
use snownet::Transmit;
use std::{
    collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque},
    mem,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
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

    /// Bi-directional mapping between connlib's sentinel DNS IPs and the effective DNS servers.
    dns_by_sentinel: BiMap<IpAddr, SocketAddr>,

    pub(crate) ipv4_routes: BTreeSet<Ipv4Network>,
    pub(crate) ipv6_routes: BTreeSet<Ipv6Network>,

    pub(crate) sent_udp_dns_queries: HashMap<(SocketAddr, QueryId), IpPacket>,
    pub(crate) received_udp_dns_responses: BTreeMap<(SocketAddr, QueryId), IpPacket>,

    pub(crate) sent_tcp_dns_queries: HashSet<(SocketAddr, QueryId)>,
    pub(crate) received_tcp_dns_responses: BTreeSet<(SocketAddr, QueryId)>,

    pub(crate) sent_icmp_requests: HashMap<(Seq, Identifier), IpPacket>,
    pub(crate) received_icmp_replies: BTreeMap<(Seq, Identifier), IpPacket>,

    pub(crate) sent_tcp_requests: HashMap<(SPort, DPort), IpPacket>,
    pub(crate) received_tcp_replies: BTreeMap<(SPort, DPort), IpPacket>,

    pub(crate) sent_udp_requests: HashMap<(SPort, DPort), IpPacket>,
    pub(crate) received_udp_replies: BTreeMap<(SPort, DPort), IpPacket>,

    pub(crate) tcp_dns_client: dns_over_tcp::Client,
}

impl SimClient {
    pub(crate) fn new(id: ClientId, sut: ClientState, now: Instant) -> Self {
        let mut tcp_dns_client = dns_over_tcp::Client::new(now, [0u8; 32]);
        tcp_dns_client.set_source_interface(Ipv4Addr::LOCALHOST, Ipv6Addr::LOCALHOST);

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
            sent_tcp_requests: Default::default(),
            received_tcp_replies: Default::default(),
            sent_udp_requests: Default::default(),
            received_udp_replies: Default::default(),
            ipv4_routes: Default::default(),
            ipv6_routes: Default::default(),
            tcp_dns_client,
        }
    }

    /// Returns the _effective_ DNS servers that connlib is using.
    pub(crate) fn effective_dns_servers(&self) -> BTreeSet<SocketAddr> {
        self.dns_by_sentinel.right_values().copied().collect()
    }

    pub(crate) fn set_new_dns_servers(&mut self, mapping: BiMap<IpAddr, SocketAddr>) {
        if self.dns_by_sentinel != mapping {
            self.tcp_dns_client
                .set_resolvers(
                    mapping
                        .left_values()
                        .map(|ip| SocketAddr::new(*ip, 53))
                        .collect(),
                )
                .unwrap();
        }

        self.dns_by_sentinel = mapping;
    }

    pub(crate) fn dns_mapping(&self) -> &BiMap<IpAddr, SocketAddr> {
        &self.dns_by_sentinel
    }

    pub(crate) fn send_dns_query_for(
        &mut self,
        domain: DomainName,
        r_type: Rtype,
        query_id: u16,
        upstream: SocketAddr,
        dns_transport: DnsTransport,
        now: Instant,
    ) -> Option<Transmit<'static>> {
        let Some(sentinel) = self.dns_by_sentinel.get_by_right(&upstream).copied() else {
            tracing::error!(%upstream, "Unknown DNS server");
            return None;
        };

        tracing::debug!(%sentinel, %domain, "Sending DNS query");

        let src = self
            .sut
            .tunnel_ip_for(sentinel)
            .expect("tunnel should be initialised");

        // Create the DNS query message
        let mut msg_builder = MessageBuilder::new_vec();

        msg_builder.header_mut().set_opcode(Opcode::QUERY);
        msg_builder.header_mut().set_rd(true);
        msg_builder.header_mut().set_id(query_id);

        // Create the query
        let mut question_builder = msg_builder.question();
        question_builder
            .push(Question::new_in(domain, r_type))
            .unwrap();

        let message = question_builder.into_message();

        match dns_transport {
            DnsTransport::Udp => {
                let packet = ip_packet::make::udp_packet(
                    src,
                    sentinel,
                    9999, // An application would pick a free source port.
                    53,
                    message.as_octets().to_vec(),
                )
                .unwrap();

                self.sent_udp_dns_queries
                    .insert((upstream, query_id), packet.clone());
                self.encapsulate(packet, now)
            }
            DnsTransport::Tcp => {
                self.tcp_dns_client
                    .send_query(SocketAddr::new(sentinel, 53), message)
                    .unwrap();
                self.sent_tcp_dns_queries.insert((upstream, query_id));

                None
            }
        }
    }

    pub(crate) fn encapsulate(
        &mut self,
        packet: IpPacket,
        now: Instant,
    ) -> Option<snownet::Transmit<'static>> {
        self.update_sent_requests(&packet);

        let Some(enc_packet) = self.sut.handle_tun_input(packet, now) else {
            self.sut.handle_timeout(now); // If we handled the packet internally, make sure to advance state.
            return None;
        };

        Some(enc_packet.to_transmit().into_owned())
    }

    fn update_sent_requests(&mut self, packet: &IpPacket) {
        if let Some(icmp) = packet.as_icmpv4() {
            if let Icmpv4Type::EchoRequest(echo) = icmp.icmp_type() {
                self.sent_icmp_requests
                    .insert((Seq(echo.seq), Identifier(echo.id)), packet.clone());
                return;
            }
        }

        if let Some(icmp) = packet.as_icmpv6() {
            if let Icmpv6Type::EchoRequest(echo) = icmp.icmp_type() {
                self.sent_icmp_requests
                    .insert((Seq(echo.seq), Identifier(echo.id)), packet.clone());
                return;
            }
        }

        if let Some(tcp) = packet.as_tcp() {
            self.sent_tcp_requests.insert(
                (SPort(tcp.source_port()), DPort(tcp.destination_port())),
                packet.clone(),
            );
            return;
        }

        if let Some(udp) = packet.as_udp() {
            self.sent_udp_requests.insert(
                (SPort(udp.source_port()), DPort(udp.destination_port())),
                packet.clone(),
            );

            return;
        }

        tracing::error!("Sent a request with an unknown transport protocol");
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
        if let Some((failed_packet, _)) = packet.icmp_unreachable_destination().unwrap() {
            match failed_packet.layer4_protocol() {
                Layer4Protocol::Udp { src, dst } => {
                    self.received_udp_replies
                        .insert((SPort(dst), DPort(src)), packet.clone());
                }
                Layer4Protocol::Tcp { src, dst } => {
                    self.received_tcp_replies
                        .insert((SPort(dst), DPort(src)), packet.clone());
                }
                Layer4Protocol::Icmp { seq, id } => {
                    self.received_icmp_replies
                        .insert((Seq(seq), Identifier(id)), packet.clone());
                }
            }

            return;
        }

        if let Some(udp) = packet.as_udp() {
            if udp.source_port() == 53 {
                let message = Message::from_slice(udp.payload())
                    .expect("ip packets on port 53 to be DNS packets");

                // Map back to upstream socket so we can assert on it correctly.
                let sentinel = SocketAddr::from((packet.source(), udp.source_port()));
                let Some(upstream) = self.upstream_dns_by_sentinel(&sentinel) else {
                    tracing::error!(%sentinel, mapping = ?self.dns_by_sentinel, "Unknown DNS server");
                    return;
                };

                self.received_udp_dns_responses
                    .insert((upstream, message.header().id()), packet.clone());

                if !message.header().tc() {
                    self.handle_dns_response(message);
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

        if let Some(tcp) = packet.as_tcp() {
            self.received_tcp_replies.insert(
                (SPort(tcp.source_port()), DPort(tcp.destination_port())),
                packet.clone(),
            );
            return;
        }

        if let Some(icmp) = packet.as_icmpv4() {
            if let Icmpv4Type::EchoReply(echo) = icmp.icmp_type() {
                self.received_icmp_replies
                    .insert((Seq(echo.seq), Identifier(echo.id)), packet.clone());
                return;
            }
        }

        if let Some(icmp) = packet.as_icmpv6() {
            if let Icmpv6Type::EchoReply(echo) = icmp.icmp_type() {
                self.received_icmp_replies
                    .insert((Seq(echo.seq), Identifier(echo.id)), packet.clone());
                return;
            }
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

    fn upstream_dns_by_sentinel(&self, sentinel: &SocketAddr) -> Option<SocketAddr> {
        let socket = self.dns_by_sentinel.get_by_left(&sentinel.ip())?;

        Some(*socket)
    }

    pub(crate) fn handle_dns_response(&mut self, message: &Message<[u8]>) {
        for record in message.answer().unwrap() {
            let record = record.unwrap();
            let domain = record.owner().to_name();

            #[expect(clippy::wildcard_enum_match_arm)]
            let ip = match record
                .into_any_record::<AllRecordData<_, _>>()
                .unwrap()
                .data()
            {
                AllRecordData::A(a) => IpAddr::from(a.addr()),
                AllRecordData::Aaaa(aaaa) => IpAddr::from(aaaa.addr()),
                AllRecordData::Ptr(_) => {
                    continue;
                }
                AllRecordData::Txt(_) => {
                    continue;
                }
                unhandled => {
                    panic!("Unexpected record data: {unhandled:?}")
                }
            };

            self.dns_records.entry(domain).or_default().push(ip);
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
    /// The upstream DNS resolvers configured in the portal.
    #[debug(skip)]
    upstream_dns_resolvers: Vec<DnsServer>,

    ipv4_routes: BTreeMap<ResourceId, Ipv4Network>,
    ipv6_routes: BTreeMap<ResourceId, Ipv6Network>,

    /// Tracks all resources in the order they have been added in.
    ///
    /// When reconnecting to the portal, we simulate them being re-added in the same order.
    #[debug(skip)]
    resources: Vec<Resource>,

    #[debug(skip)]
    internet_resource: Option<ResourceId>,

    /// The CIDR resources the client is aware of.
    #[debug(skip)]
    cidr_resources: IpNetworkTable<ResourceId>,

    /// The client's DNS records.
    ///
    /// The IPs assigned to a domain by connlib are an implementation detail that we don't want to model in these tests.
    /// Instead, we just remember what _kind_ of records we resolved to be able to sample a matching src IP.
    #[debug(skip)]
    pub(crate) dns_records: BTreeMap<DomainName, BTreeSet<Rtype>>,

    /// Whether we are connected to the gateway serving the Internet resource.
    #[debug(skip)]
    pub(crate) connected_internet_resource: bool,

    /// The CIDR resources the client is connected to.
    #[debug(skip)]
    pub(crate) connected_cidr_resources: HashSet<ResourceId>,

    /// Actively disabled resources by the UI
    #[debug(skip)]
    pub(crate) disabled_resources: BTreeSet<ResourceId>,

    /// The expected ICMP handshakes.
    #[debug(skip)]
    pub(crate) expected_icmp_handshakes:
        BTreeMap<GatewayId, BTreeMap<u64, (Destination, Seq, Identifier)>>,

    /// The expected UDP handshakes.
    #[debug(skip)]
    pub(crate) expected_udp_handshakes:
        BTreeMap<GatewayId, BTreeMap<u64, (Destination, SPort, DPort)>>,

    /// The expected TCP exchanges.
    #[debug(skip)]
    pub(crate) expected_tcp_exchanges:
        BTreeMap<GatewayId, BTreeMap<u64, (Destination, SPort, DPort)>>,

    /// The expected UDP DNS handshakes.
    #[debug(skip)]
    pub(crate) expected_udp_dns_handshakes: VecDeque<(SocketAddr, QueryId)>,
    /// The expected TCP DNS handshakes.
    #[debug(skip)]
    pub(crate) expected_tcp_dns_handshakes: VecDeque<(SocketAddr, QueryId)>,
}

impl RefClient {
    /// Initialize the [`ClientState`].
    ///
    /// This simulates receiving the `init` message from the portal.
    pub(crate) fn init(self, now: Instant) -> SimClient {
        let mut client_state = ClientState::new(self.key.0, now); // Cheating a bit here by reusing the key as seed.
        client_state.update_interface_config(Interface {
            ipv4: self.tunnel_ip4,
            ipv6: self.tunnel_ip6,
            upstream_dns: self.upstream_dns_resolvers.clone(),
        });
        client_state.update_system_resolvers(self.system_dns_resolvers.clone());

        SimClient::new(self.id, client_state, now)
    }

    pub(crate) fn disconnect_resource(&mut self, resource: &ResourceId) {
        self.ipv4_routes.remove(resource);
        self.ipv6_routes.remove(resource);

        self.connected_cidr_resources.remove(resource);

        if self.internet_resource.is_some_and(|r| &r == resource) {
            self.connected_internet_resource = false;
        }
    }

    pub(crate) fn remove_resource(&mut self, resource: &ResourceId) {
        self.disconnect_resource(resource);

        if self.internet_resource.is_some_and(|r| &r == resource) {
            self.internet_resource = None;
        }

        self.resources.retain(|r| r.id() != *resource);

        self.cidr_resources = self.recalculate_cidr_routes();
    }

    fn recalculate_cidr_routes(&mut self) -> IpNetworkTable<ResourceId> {
        let mut table = IpNetworkTable::<ResourceId>::new();
        for resource in self.resources.iter().sorted_by_key(|r| r.id()) {
            let Resource::Cidr(resource) = resource else {
                continue;
            };

            if self.disabled_resources.contains(&resource.id) {
                continue;
            }

            if let Some(overlapping_resource) = table.exact_match(resource.address) {
                if self.is_connected_to_internet_or_cidr(*overlapping_resource) {
                    tracing::debug!(%overlapping_resource, resource = %resource.id, address = %resource.address, "Already connected to resource with this exact address, retaining existing route");

                    continue;
                }
            }

            tracing::debug!(resource = %resource.id, address = %resource.address, "Adding CIDR route");

            table.insert(resource.address, resource.id);
        }

        table
    }

    pub(crate) fn reset_connections(&mut self) {
        self.connected_cidr_resources.clear();
        self.connected_internet_resource = false;
    }

    pub(crate) fn add_internet_resource(&mut self, r: InternetResource) {
        self.internet_resource = Some(r.id);
        self.resources.push(Resource::Internet(r.clone()));

        if self.disabled_resources.contains(&r.id) {
            return;
        }

        self.ipv4_routes.insert(r.id, Ipv4Network::DEFAULT_ROUTE);
        self.ipv6_routes.insert(r.id, Ipv6Network::DEFAULT_ROUTE);
    }

    pub(crate) fn add_cidr_resource(&mut self, r: CidrResource) {
        self.resources.push(Resource::Cidr(r.clone()));
        self.cidr_resources = self.recalculate_cidr_routes();

        if self.disabled_resources.contains(&r.id) {
            return;
        }

        match r.address {
            IpNetwork::V4(v4) => {
                self.ipv4_routes.insert(r.id, v4);
            }
            IpNetwork::V6(v6) => {
                self.ipv6_routes.insert(r.id, v6);
            }
        }
    }

    pub(crate) fn add_dns_resource(&mut self, r: DnsResource) {
        self.resources.push(Resource::Dns(r));
    }

    /// Re-adds all resources in the order they have been initially added.
    pub(crate) fn readd_all_resources(&mut self) {
        self.cidr_resources = IpNetworkTable::new();
        self.internet_resource = None;

        for resource in mem::take(&mut self.resources) {
            match resource {
                Resource::Dns(d) => self.add_dns_resource(d),
                Resource::Cidr(c) => self.add_cidr_resource(c),
                Resource::Internet(i) => self.add_internet_resource(i),
            }
        }
    }

    pub(crate) fn is_tunnel_ip(&self, ip: IpAddr) -> bool {
        match ip {
            IpAddr::V4(ip4) => self.tunnel_ip4 == ip4,
            IpAddr::V6(ip6) => self.tunnel_ip6 == ip6,
        }
    }

    pub(crate) fn tunnel_ip_for(&self, dst: IpAddr) -> IpAddr {
        match dst {
            IpAddr::V4(_) => self.tunnel_ip4.into(),
            IpAddr::V6(_) => self.tunnel_ip6.into(),
        }
    }

    pub(crate) fn on_icmp_packet(
        &mut self,
        src: IpAddr,
        dst: Destination,
        seq: Seq,
        identifier: Identifier,
        payload: u64,
        gateway_by_resource: impl Fn(ResourceId) -> Option<GatewayId>,
    ) {
        self.on_packet(
            src,
            dst.clone(),
            (dst, seq, identifier),
            |ref_client| &mut ref_client.expected_icmp_handshakes,
            payload,
            gateway_by_resource,
        );
    }

    pub(crate) fn on_udp_packet(
        &mut self,
        src: IpAddr,
        dst: Destination,
        sport: SPort,
        dport: DPort,
        payload: u64,
        gateway_by_resource: impl Fn(ResourceId) -> Option<GatewayId>,
    ) {
        self.on_packet(
            src,
            dst.clone(),
            (dst, sport, dport),
            |ref_client| &mut ref_client.expected_udp_handshakes,
            payload,
            gateway_by_resource,
        );
    }

    pub(crate) fn on_tcp_packet(
        &mut self,
        src: IpAddr,
        dst: Destination,
        sport: SPort,
        dport: DPort,
        payload: u64,
        gateway_by_resource: impl Fn(ResourceId) -> Option<GatewayId>,
    ) {
        self.on_packet(
            src,
            dst.clone(),
            (dst, sport, dport),
            |ref_client| &mut ref_client.expected_tcp_exchanges,
            payload,
            gateway_by_resource,
        );
    }

    #[tracing::instrument(level = "debug", skip_all, fields(dst, resource, gateway))]
    fn on_packet<E>(
        &mut self,
        src: IpAddr,
        dst: Destination,
        packet_id: E,
        map: impl FnOnce(&mut Self) -> &mut BTreeMap<GatewayId, BTreeMap<u64, E>>,
        payload: u64,
        gateway_by_resource: impl Fn(ResourceId) -> Option<GatewayId>,
    ) {
        let Some(resource) = self.resource_by_dst(&dst) else {
            return;
        };

        tracing::Span::current().record("resource", tracing::field::display(resource));

        let Some(gateway) = gateway_by_resource(resource) else {
            tracing::error!("No gateway for resource");
            return;
        };

        tracing::Span::current().record("gateway", tracing::field::display(gateway));

        self.connect_to_resource(resource, dst);

        if !self.is_tunnel_ip(src) {
            return;
        }

        tracing::debug!(%payload, "Sending packet to resource");

        map(self)
            .entry(gateway)
            .or_default()
            .insert(payload, packet_id);
    }

    fn connect_to_resource(&mut self, resource: ResourceId, destination: Destination) {
        match destination {
            Destination::DomainName { .. } => {}
            Destination::IpAddr(_) => self.connect_to_internet_or_cidr_resource(resource),
        }
    }

    fn is_connected_to_internet_or_cidr(&self, resource: ResourceId) -> bool {
        self.is_connected_to_cidr(resource) || self.is_connected_to_internet(resource)
    }

    fn connect_to_internet_or_cidr_resource(&mut self, resource: ResourceId) {
        if self.internet_resource.is_some_and(|r| r == resource) {
            self.connected_internet_resource = true;
            return;
        }

        if self.cidr_resources.iter().any(|(_, r)| *r == resource) {
            let is_new = self.connected_cidr_resources.insert(resource);

            if is_new {
                tracing::debug!(%resource, "Now connected to CIDR resource");
            }
        }
    }

    pub(crate) fn on_dns_query(&mut self, query: &DnsQuery) {
        self.dns_records
            .entry(query.domain.clone())
            .or_default()
            .insert(query.r_type);

        match query.transport {
            DnsTransport::Udp => {
                self.expected_udp_dns_handshakes
                    .push_back((query.dns_server, query.query_id));
            }
            DnsTransport::Tcp => {
                self.expected_tcp_dns_handshakes
                    .push_back((query.dns_server, query.query_id));
            }
        }

        if let Some(resource) = self.dns_query_via_resource(query) {
            self.connect_to_internet_or_cidr_resource(resource);
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

    pub(crate) fn active_internet_resource(&self) -> Option<ResourceId> {
        self.internet_resource
            .filter(|r| !self.disabled_resources.contains(r))
    }

    fn resource_by_dst(&self, destination: &Destination) -> Option<ResourceId> {
        match destination {
            Destination::DomainName { name, .. } => {
                if let Some(id) = self.dns_resource_by_domain(name) {
                    return Some(id);
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

    pub(crate) fn dns_resource_by_domain(&self, domain: &DomainName) -> Option<ResourceId> {
        self.resources
            .iter()
            .cloned()
            .filter_map(|r| r.into_dns())
            .filter(|r| is_subdomain(&domain.to_string(), &r.address))
            .sorted_by_key(|r| r.address.len())
            .rev()
            .map(|r| r.id)
            .find(|id| !self.disabled_resources.contains(id))
    }

    fn resolved_domains(&self) -> impl Iterator<Item = (DomainName, BTreeSet<Rtype>)> + '_ {
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

    /// An TCP packet is valid if we didn't yet send an TCP packet with the same sport, dport and payload.
    pub(crate) fn is_valid_tcp_packet(&self, sport: &SPort, dport: &DPort, payload: &u64) -> bool {
        self.expected_tcp_exchanges.values().flatten().all(
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
                    .any(|r| matches!(r, &Rtype::A))
                    .then_some(domain)
            })
            .collect()
    }

    pub(crate) fn resolved_v6_domains(&self) -> Vec<DomainName> {
        self.resolved_domains()
            .filter_map(|(domain, records)| {
                records
                    .iter()
                    .any(|r| matches!(r, &Rtype::AAAA))
                    .then_some(domain)
            })
            .collect()
    }

    /// Returns the DNS servers that we expect connlib to use.
    ///
    /// If there are upstream DNS servers configured in the portal, it should use those.
    /// Otherwise it should use whatever was configured on the system prior to connlib starting.
    pub(crate) fn expected_dns_servers(&self) -> BTreeSet<SocketAddr> {
        if !self.upstream_dns_resolvers.is_empty() {
            return self
                .upstream_dns_resolvers
                .iter()
                .map(DnsServer::address)
                .collect();
        }

        self.system_dns_resolvers
            .iter()
            .map(|ip| SocketAddr::new(*ip, 53))
            .collect()
    }

    pub(crate) fn expected_routes(&self) -> (BTreeSet<Ipv4Network>, BTreeSet<Ipv6Network>) {
        (
            self.ipv4_routes
                .values()
                .cloned()
                .chain(default_routes_v4())
                .collect(),
            self.ipv6_routes
                .values()
                .cloned()
                .chain(default_routes_v6())
                .collect(),
        )
    }

    pub(crate) fn cidr_resource_by_ip(&self, ip: IpAddr) -> Option<ResourceId> {
        // Manually implement `longest_match` because we need to filter disabled resources _before_ we match.
        let (_, r) = self
            .cidr_resources
            .matches(ip)
            .filter(|(_, r)| !self.disabled_resources.contains(r))
            .sorted_by(|(n1, _), (n2, _)| n1.netmask().cmp(&n2.netmask()).reverse()) // Highest netmask is most specific.
            .next()?;

        Some(*r)
    }

    pub(crate) fn resolved_ip4_for_non_resources(
        &self,
        global_dns_records: &DnsRecords,
    ) -> Vec<Ipv4Addr> {
        self.resolved_ips_for_non_resources(global_dns_records)
            .filter_map(|ip| match ip {
                IpAddr::V4(v4) => Some(v4),
                IpAddr::V6(_) => None,
            })
            .collect()
    }

    pub(crate) fn resolved_ip6_for_non_resources(
        &self,
        global_dns_records: &DnsRecords,
    ) -> Vec<Ipv6Addr> {
        self.resolved_ips_for_non_resources(global_dns_records)
            .filter_map(|ip| match ip {
                IpAddr::V6(v6) => Some(v6),
                IpAddr::V4(_) => None,
            })
            .collect()
    }

    fn resolved_ips_for_non_resources<'a>(
        &'a self,
        global_dns_records: &'a DnsRecords,
    ) -> impl Iterator<Item = IpAddr> + 'a {
        self.dns_records
            .iter()
            .filter_map(|(domain, _)| {
                self.dns_resource_by_domain(domain)
                    .is_none()
                    .then_some(global_dns_records.domain_ips_iter(domain))
            })
            .flatten()
    }

    /// Returns the resource we will forward the DNS query for the given name to.
    ///
    /// DNS servers may be resources, in which case queries that need to be forwarded actually need to be encapsulated.
    pub(crate) fn dns_query_via_resource(&self, query: &DnsQuery) -> Option<ResourceId> {
        // Unless we are using upstream resolvers, DNS queries are never routed through the tunnel.
        if self.upstream_dns_resolvers.is_empty() {
            return None;
        }

        // If we are querying a DNS resource, we will issue a connection intent to the DNS resource, not the CIDR resource.
        if self.dns_resource_by_domain(&query.domain).is_some()
            && matches!(query.r_type, Rtype::A | Rtype::AAAA | Rtype::PTR)
        {
            return None;
        }

        let maybe_active_cidr_resource = self.cidr_resource_by_ip(query.dns_server.ip());
        let maybe_active_internet_resource = self.active_internet_resource();

        maybe_active_cidr_resource.or(maybe_active_internet_resource)
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

    pub(crate) fn set_system_dns_resolvers(&mut self, servers: &Vec<IpAddr>) {
        self.system_dns_resolvers.clone_from(servers);
    }

    pub(crate) fn set_upstream_dns_resolvers(&mut self, servers: &Vec<DnsServer>) {
        self.upstream_dns_resolvers.clone_from(servers);
    }

    pub(crate) fn upstream_dns_resolvers(&self) -> Vec<DnsServer> {
        self.upstream_dns_resolvers.clone()
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
    upstream_dns: impl Strategy<Value = Vec<DnsServer>>,
) -> impl Strategy<Value = Host<RefClient>> {
    host(
        any_ip_stack(),
        any_port(),
        ref_client(tunnel_ip4s, tunnel_ip6s, system_dns, upstream_dns),
        latency(300), // TODO: Increase with #6062.
    )
}

fn ref_client(
    tunnel_ip4s: impl Strategy<Value = Ipv4Addr>,
    tunnel_ip6s: impl Strategy<Value = Ipv6Addr>,
    system_dns: impl Strategy<Value = Vec<IpAddr>>,
    upstream_dns: impl Strategy<Value = Vec<DnsServer>>,
) -> impl Strategy<Value = RefClient> {
    (
        tunnel_ip4s,
        tunnel_ip6s,
        system_dns,
        upstream_dns,
        client_id(),
        private_key(),
    )
        .prop_map(
            move |(
                tunnel_ip4,
                tunnel_ip6,
                system_dns_resolvers,
                upstream_dns_resolvers,
                id,
                key,
            )| {
                RefClient {
                    id,
                    key,
                    tunnel_ip4,
                    tunnel_ip6,
                    system_dns_resolvers,
                    upstream_dns_resolvers,
                    internet_resource: Default::default(),
                    cidr_resources: IpNetworkTable::new(),
                    dns_records: Default::default(),
                    connected_cidr_resources: Default::default(),
                    connected_internet_resource: Default::default(),
                    expected_icmp_handshakes: Default::default(),
                    expected_udp_handshakes: Default::default(),
                    expected_tcp_exchanges: Default::default(),
                    expected_udp_dns_handshakes: Default::default(),
                    expected_tcp_dns_handshakes: Default::default(),
                    disabled_resources: Default::default(),
                    resources: Default::default(),
                    ipv4_routes: Default::default(),
                    ipv6_routes: Default::default(),
                }
            },
        )
}

fn default_routes_v4() -> Vec<Ipv4Network> {
    vec![
        Ipv4Network::new(Ipv4Addr::new(100, 96, 0, 0), 11).unwrap(),
        Ipv4Network::new(Ipv4Addr::new(100, 100, 111, 0), 24).unwrap(),
    ]
}

fn default_routes_v6() -> Vec<Ipv6Network> {
    vec![
        Ipv6Network::new(
            Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0x8000, 0, 0, 0, 0),
            107,
        )
        .unwrap(),
        Ipv6Network::new(
            Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0x8000, 0x0100, 0x0100, 0x0111, 0),
            120,
        )
        .unwrap(),
    ]
}
