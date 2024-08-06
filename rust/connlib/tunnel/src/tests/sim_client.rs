use super::{
    reference::{private_key, PrivateKey, ResourceDst},
    sim_net::{any_ip_stack, any_port, host, Host},
    sim_relay::{map_explode, SimRelay},
    strategies::latency,
    IcmpIdentifier, IcmpSeq, QueryId,
};
use crate::ClientState;
use bimap::BiMap;
use connlib_shared::{
    messages::{
        client::{ResourceDescription, ResourceDescriptionCidr, ResourceDescriptionDns},
        ClientId, DnsServer, GatewayId, Interface, RelayId, ResourceId,
    },
    proptest::{client_id, domain_name},
    DomainName,
};
use domain::{
    base::{Message, Rtype, ToName},
    rdata::AllRecordData,
};
use ip_network::{Ipv4Network, Ipv6Network};
use ip_network_table::IpNetworkTable;
use ip_packet::{IpPacket, MutableIpPacket, Packet as _};
use itertools::Itertools as _;
use prop::collection;
use proptest::prelude::*;
use snownet::Transmit;
use std::{
    collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
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
    pub(crate) dns_by_sentinel: BiMap<IpAddr, SocketAddr>,

    pub(crate) sent_dns_queries: HashMap<QueryId, IpPacket<'static>>,
    pub(crate) received_dns_responses: HashMap<QueryId, IpPacket<'static>>,

    pub(crate) sent_icmp_requests: HashMap<(u16, u16), IpPacket<'static>>,
    pub(crate) received_icmp_replies: HashMap<(u16, u16), IpPacket<'static>>,

    buffer: Vec<u8>,
}

impl SimClient {
    pub(crate) fn new(id: ClientId, sut: ClientState) -> Self {
        Self {
            id,
            sut,
            dns_records: Default::default(),
            dns_by_sentinel: Default::default(),
            sent_dns_queries: Default::default(),
            received_dns_responses: Default::default(),
            sent_icmp_requests: Default::default(),
            received_icmp_replies: Default::default(),
            buffer: vec![0u8; (1 << 16) - 1],
        }
    }

    /// Returns the _effective_ DNS servers that connlib is using.
    pub(crate) fn effective_dns_servers(&self) -> BTreeSet<SocketAddr> {
        self.dns_by_sentinel.right_values().copied().collect()
    }

    pub(crate) fn send_dns_query_for(
        &mut self,
        domain: DomainName,
        r_type: Rtype,
        query_id: u16,
        dns_server: SocketAddr,
        now: Instant,
    ) -> Option<Transmit<'static>> {
        let Some(dns_server) = self.dns_by_sentinel.get_by_right(&dns_server).copied() else {
            tracing::error!(%dns_server, "Unknown DNS server");
            return None;
        };

        tracing::debug!(%dns_server, %domain, "Sending DNS query");

        let src = self
            .sut
            .tunnel_ip_for(dns_server)
            .expect("tunnel should be initialised");

        let packet = ip_packet::make::dns_query(
            domain,
            r_type,
            SocketAddr::new(src, 9999), // An application would pick a random source port that is free.
            SocketAddr::new(dns_server, 53),
            query_id,
        );

        self.encapsulate(packet, now)
    }

    pub(crate) fn encapsulate(
        &mut self,
        packet: MutableIpPacket<'static>,
        now: Instant,
    ) -> Option<snownet::Transmit<'static>> {
        {
            let packet = packet.to_owned().into_immutable();

            if let Some(icmp) = packet.as_icmp() {
                let echo_request = icmp.as_echo_request().expect("to be echo request");

                self.sent_icmp_requests
                    .insert((echo_request.sequence(), echo_request.identifier()), packet);
            }
        }

        {
            let packet = packet.to_owned().into_immutable();

            if let Some(udp) = packet.as_udp() {
                if let Ok(message) = Message::from_slice(udp.payload()) {
                    debug_assert!(
                        !message.header().qr(),
                        "every DNS message sent from the client should be a DNS query"
                    );

                    self.sent_dns_queries.insert(message.header().id(), packet);
                }
            }
        }

        Some(self.sut.encapsulate(packet, now)?.into_owned())
    }

    pub(crate) fn receive(&mut self, transmit: Transmit, now: Instant) {
        let Some(packet) = self.sut.decapsulate(
            transmit.dst,
            transmit.src.unwrap(),
            &transmit.payload,
            now,
            &mut self.buffer,
        ) else {
            return;
        };
        let packet = packet.to_owned();

        self.on_received_packet(packet);
    }

    /// Process an IP packet received on the client.
    pub(crate) fn on_received_packet(&mut self, packet: IpPacket<'_>) {
        if let Some(icmp) = packet.as_icmp() {
            let echo_reply = icmp.as_echo_reply().expect("to be echo reply");

            self.received_icmp_replies.insert(
                (echo_reply.sequence(), echo_reply.identifier()),
                packet.to_owned(),
            );

            return;
        };

        if let Some(udp) = packet.as_udp() {
            if udp.get_source() == 53 {
                let message = Message::from_slice(udp.payload())
                    .expect("ip packets on port 53 to be DNS packets");

                self.received_dns_responses
                    .insert(message.header().id(), packet.to_owned());

                for record in message.answer().unwrap() {
                    let record = record.unwrap();
                    let domain = record.owner().to_name();

                    #[allow(clippy::wildcard_enum_match_arm)]
                    let ip = match record
                        .into_any_record::<AllRecordData<_, _>>()
                        .unwrap()
                        .data()
                    {
                        AllRecordData::A(a) => IpAddr::from(a.addr()),
                        AllRecordData::Aaaa(aaaa) => IpAddr::from(aaaa.addr()),
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

                return;
            }
        }

        unimplemented!("Unhandled packet")
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
}

/// Reference state for a particular client.
///
/// The reference state machine is designed to be as abstract as possible over connlib's functionality.
/// For example, we try to model connectivity to _resources_ and don't really care, which gateway is being used to route us there.
#[derive(Clone, derivative::Derivative)]
#[derivative(Debug)]
pub struct RefClient {
    pub(crate) id: ClientId,
    pub(crate) key: PrivateKey,
    pub(crate) known_hosts: HashMap<String, Vec<IpAddr>>,
    pub(crate) tunnel_ip4: Ipv4Addr,
    pub(crate) tunnel_ip6: Ipv6Addr,

    /// The DNS resolvers configured on the client outside of connlib.
    pub(crate) system_dns_resolvers: Vec<IpAddr>,
    /// The upstream DNS resolvers configured in the portal.
    pub(crate) upstream_dns_resolvers: Vec<DnsServer>,

    pub(crate) internet_resource: Option<ResourceId>,

    /// The CIDR resources the client is aware of.
    #[derivative(Debug = "ignore")]
    pub(crate) cidr_resources: IpNetworkTable<ResourceDescriptionCidr>,
    /// The DNS resources the client is aware of.
    #[derivative(Debug = "ignore")]
    pub(crate) dns_resources: BTreeMap<ResourceId, ResourceDescriptionDns>,

    /// The client's DNS records.
    ///
    /// The IPs assigned to a domain by connlib are an implementation detail that we don't want to model in these tests.
    /// Instead, we just remember what _kind_ of records we resolved to be able to sample a matching src IP.
    #[derivative(Debug = "ignore")]
    pub(crate) dns_records: BTreeMap<DomainName, HashSet<Rtype>>,

    /// Whether we are connected to the gateway serving the Internet resource.
    pub(crate) connected_internet_resources: bool,

    /// The CIDR resources the client is connected to.
    #[derivative(Debug = "ignore")]
    pub(crate) connected_cidr_resources: HashSet<ResourceId>,

    /// The DNS resources the client is connected to.
    #[derivative(Debug = "ignore")]
    pub(crate) connected_dns_resources: HashSet<(ResourceId, DomainName)>,

    /// Actively disabled resources by the UI
    #[derivative(Debug = "ignore")]
    pub(crate) disabled_resources: HashSet<ResourceId>,

    /// The expected ICMP handshakes.
    ///
    /// This is indexed by gateway because our assertions rely on the order of the sent packets.
    #[derivative(Debug = "ignore")]
    pub(crate) expected_icmp_handshakes:
        HashMap<GatewayId, VecDeque<(ResourceDst, IcmpSeq, IcmpIdentifier)>>,
    /// The expected DNS handshakes.
    #[derivative(Debug = "ignore")]
    pub(crate) expected_dns_handshakes: VecDeque<QueryId>,
}

impl RefClient {
    /// Initialize the [`ClientState`].
    ///
    /// This simulates receiving the `init` message from the portal.
    pub(crate) fn init(self) -> SimClient {
        assert!(self.upstream_dns_resolvers.is_empty());
        assert!(self.system_dns_resolvers.is_empty());

        let mut client_state = ClientState::new(self.key, self.known_hosts, self.key.0); // Cheating a bit here by reusing the key as seed.
        let _ = client_state.update_interface_config(Interface {
            ipv4: self.tunnel_ip4,
            ipv6: self.tunnel_ip6,
            upstream_dns: vec![],
        });
        let _ = client_state.update_system_resolvers(vec![]);

        SimClient::new(self.id, client_state)
    }

    pub(crate) fn disconnect_resource(&mut self, resource: &ResourceId) {
        self.connected_cidr_resources.remove(resource);
        self.connected_dns_resources.retain(|(r, _)| r != resource);
    }

    pub(crate) fn reset_connections(&mut self) {
        self.connected_cidr_resources.clear();
        self.connected_dns_resources.clear();
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

    #[tracing::instrument(level = "debug", skip_all, fields(dst, resource))]
    pub(crate) fn on_icmp_packet_to_internet(
        &mut self,
        src: IpAddr,
        dst: IpAddr,
        seq: u16,
        identifier: u16,
        gateway_by_resource: impl Fn(ResourceId) -> Option<GatewayId>,
    ) {
        tracing::Span::current().record("dst", tracing::field::display(dst));

        // Second, if we are not yet connected, check if we have a resource for this IP.
        let Some(rid) = self.internet_resource else {
            tracing::debug!("No internet resource");
            return;
        };
        tracing::Span::current().record("resource", tracing::field::display(rid));

        let Some(gateway) = gateway_by_resource(rid) else {
            tracing::error!("No gateway for resource");
            return;
        };

        if self.connected_internet_resources && self.is_tunnel_ip(src) {
            tracing::debug!("Connected to Internet resource, expecting packet to be routed");
            self.expected_icmp_handshakes
                .entry(gateway)
                .or_default()
                .push_back((ResourceDst::Internet(dst), seq, identifier));
            return;
        }

        // If we have a resource, the first packet will initiate a connection to the gateway.
        tracing::debug!("Not connected to resource, expecting to trigger connection intent");
        self.connected_internet_resources = true;
    }

    #[tracing::instrument(level = "debug", skip_all, fields(dst, resource))]
    pub(crate) fn on_icmp_packet_to_cidr(
        &mut self,
        src: IpAddr,
        dst: IpAddr,
        seq: u16,
        identifier: u16,
        gateway_by_resource: impl Fn(ResourceId) -> Option<GatewayId>,
    ) {
        tracing::Span::current().record("dst", tracing::field::display(dst));

        // Second, if we are not yet connected, check if we have a resource for this IP.
        let Some(rid) = self.cidr_resource_by_ip(dst) else {
            tracing::debug!("No resource corresponds to IP");
            return;
        };
        tracing::Span::current().record("resource", tracing::field::display(rid));

        if self.disabled_resources.contains(&rid) {
            return;
        }

        let Some(gateway) = gateway_by_resource(rid) else {
            tracing::error!("No gateway for resource");
            return;
        };

        if self.is_connected_to_cidr(rid) && self.is_tunnel_ip(src) {
            tracing::debug!("Connected to CIDR resource, expecting packet to be routed");
            self.expected_icmp_handshakes
                .entry(gateway)
                .or_default()
                .push_back((ResourceDst::Cidr(dst), seq, identifier));
            return;
        }

        // If we have a resource, the first packet will initiate a connection to the gateway.
        tracing::debug!("Not connected to resource, expecting to trigger connection intent");
        self.connected_cidr_resources.insert(rid);
    }

    #[tracing::instrument(level = "debug", skip_all, fields(dst, resource))]
    pub(crate) fn on_icmp_packet_to_dns(
        &mut self,
        src: IpAddr,
        dst: DomainName,
        seq: u16,
        identifier: u16,
        gateway_by_resource: impl Fn(ResourceId) -> Option<GatewayId>,
    ) {
        tracing::Span::current().record("dst", tracing::field::display(&dst));

        let Some(resource) = self.dns_resource_by_domain(&dst) else {
            tracing::debug!("No resource corresponds to IP");
            return;
        };

        tracing::Span::current().record("resource", tracing::field::display(resource));

        let Some(gateway) = gateway_by_resource(resource) else {
            tracing::error!("No gateway for resource");
            return;
        };

        if self
            .connected_dns_resources
            .contains(&(resource, dst.clone()))
            && self.is_tunnel_ip(src)
        {
            tracing::debug!("Connected to DNS resource, expecting packet to be routed");
            self.expected_icmp_handshakes
                .entry(gateway)
                .or_default()
                .push_back((ResourceDst::Dns(dst), seq, identifier));
            return;
        }

        debug_assert!(
            self.dns_records.iter().any(|(name, _)| name == &dst),
            "Should only sample ICMPs to domains that we resolved"
        );

        tracing::debug!("Not connected to resource, expecting to trigger connection intent");
        if !self.disabled_resources.contains(&resource) {
            self.connected_dns_resources.insert((resource, dst));
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

    pub(crate) fn is_connected_to_cidr(&self, id: ResourceId) -> bool {
        self.connected_cidr_resources.contains(&id)
    }

    pub(crate) fn is_known_host(&self, name: &str) -> bool {
        self.known_hosts.contains_key(name)
    }

    pub(crate) fn dns_resource_by_domain(&self, domain: &DomainName) -> Option<ResourceId> {
        self.dns_resources
            .values()
            .filter(|r| is_subdomain(&domain.to_string(), &r.address))
            .sorted_by_key(|r| r.address.len())
            .rev()
            .map(|r| r.id)
            .find(|id| !self.disabled_resources.contains(id))
    }

    fn resolved_domains(&self) -> impl Iterator<Item = (DomainName, HashSet<Rtype>)> + '_ {
        self.dns_records
            .iter()
            .filter(|(domain, _)| self.dns_resource_by_domain(domain).is_some())
            .map(|(domain, ips)| (domain.clone(), ips.clone()))
    }

    /// An ICMP packet is valid if we didn't yet send an ICMP packet with the same seq and identifier.
    pub(crate) fn is_valid_icmp_packet(&self, seq: &u16, identifier: &u16) -> bool {
        self.expected_icmp_handshakes.values().flatten().all(
            |(_, existing_seq, existing_identifer)| {
                existing_seq != seq && existing_identifer != identifier
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

    pub(crate) fn v4_dns_servers(&self) -> Vec<SocketAddrV4> {
        self.expected_dns_servers()
            .into_iter()
            .filter_map(|s| match s {
                SocketAddr::V4(v4) => Some(v4),
                SocketAddr::V6(_) => None,
            })
            .collect()
    }

    pub(crate) fn v6_dns_servers(&self) -> Vec<SocketAddrV6> {
        self.expected_dns_servers()
            .into_iter()
            .filter_map(|s| match s {
                SocketAddr::V6(v6) => Some(v6),
                SocketAddr::V4(_) => None,
            })
            .collect()
    }

    pub(crate) fn cidr_resource_by_ip(&self, ip: IpAddr) -> Option<ResourceId> {
        self.cidr_resources
            .longest_match(ip)
            .map(|(_, r)| r.id)
            .filter(|id| !self.disabled_resources.contains(id))
    }

    pub(crate) fn resolved_ip4_for_non_resources(
        &self,
        global_dns_records: &BTreeMap<DomainName, HashSet<IpAddr>>,
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
        global_dns_records: &BTreeMap<DomainName, HashSet<IpAddr>>,
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
        global_dns_records: &'a BTreeMap<DomainName, HashSet<IpAddr>>,
    ) -> impl Iterator<Item = IpAddr> + 'a {
        self.dns_records
            .iter()
            .filter_map(|(domain, _)| {
                self.dns_resource_by_domain(domain)
                    .is_none()
                    .then_some(global_dns_records.get(domain))
            })
            .flatten()
            .flatten()
            .copied()
    }

    /// Returns the CIDR resource we will forward the DNS query for the given name to.
    ///
    /// DNS servers may be resources, in which case queries that need to be forwarded actually need to be encapsulated.
    pub(crate) fn dns_query_via_cidr_resource(
        &self,
        dns_server: IpAddr,
        domain: &DomainName,
    ) -> Option<ResourceId> {
        // If we are querying a DNS resource, we will issue a connection intent to the DNS resource, not the CIDR resource.
        if self.dns_resource_by_domain(domain).is_some() {
            return None;
        }

        self.cidr_resource_by_ip(dns_server)
    }

    pub(crate) fn all_resource_ids(&self) -> Vec<ResourceId> {
        let cidr_resources = self.cidr_resources.iter().map(|(_, r)| r.id);
        let dns_resources = self.dns_resources.keys().copied();

        Vec::from_iter(cidr_resources.chain(dns_resources))
    }

    pub(crate) fn has_resource(&self, resource_id: ResourceId) -> bool {
        if self.dns_resources.contains_key(&resource_id) {
            return true;
        }

        if self.cidr_resources.iter().any(|(_, r)| r.id == resource_id) {
            return true;
        }

        if self.internet_resource.is_some_and(|r| r == resource_id) {
            return true;
        }

        false
    }

    pub(crate) fn all_resources(&self) -> Vec<ResourceDescription> {
        let cidr_resources = self
            .cidr_resources
            .iter()
            .map(|(_, r)| r)
            .cloned()
            .map(ResourceDescription::Cidr);
        let dns_resources = self
            .dns_resources
            .values()
            .cloned()
            .map(ResourceDescription::Dns);

        Vec::from_iter(cidr_resources.chain(dns_resources))
    }
}

fn is_subdomain(name: &str, record: &str) -> bool {
    if name == record {
        return true;
    }
    let Some((first, end)) = record.split_once('.') else {
        return false;
    };
    match first {
        "*" => name.ends_with(end) && name.strip_suffix(end).is_some_and(|n| n.ends_with('.')),
        "?" => {
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
) -> impl Strategy<Value = Host<RefClient>> {
    host(
        any_ip_stack(),
        any_port(),
        ref_client(tunnel_ip4s, tunnel_ip6s),
        latency(300), // TODO: Increase with #6062.
    )
}

fn ref_client(
    tunnel_ip4s: impl Strategy<Value = Ipv4Addr>,
    tunnel_ip6s: impl Strategy<Value = Ipv6Addr>,
) -> impl Strategy<Value = RefClient> {
    (
        tunnel_ip4s,
        tunnel_ip6s,
        client_id(),
        private_key(),
        known_hosts(),
    )
        .prop_map(
            move |(tunnel_ip4, tunnel_ip6, id, key, known_hosts)| RefClient {
                id,
                key,
                known_hosts,
                tunnel_ip4,
                tunnel_ip6,
                system_dns_resolvers: Default::default(),
                upstream_dns_resolvers: Default::default(),
                internet_resource: Default::default(),
                cidr_resources: IpNetworkTable::new(),
                dns_resources: Default::default(),
                dns_records: Default::default(),
                connected_cidr_resources: Default::default(),
                connected_dns_resources: Default::default(),
                connected_internet_resources: Default::default(),
                expected_icmp_handshakes: Default::default(),
                expected_dns_handshakes: Default::default(),
                disabled_resources: Default::default(),
            },
        )
}

fn known_hosts() -> impl Strategy<Value = HashMap<String, Vec<IpAddr>>> {
    collection::hash_map(
        domain_name(2..4).prop_map(|d| d.parse().unwrap()),
        collection::vec(any::<IpAddr>(), 1..6),
        0..15,
    )
}
