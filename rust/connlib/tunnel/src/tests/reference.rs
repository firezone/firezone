use super::{
    composite_strategy::CompositeStrategy, sim_node::*, sim_relay::*, strategies::*, transition::*,
    IcmpIdentifier, IcmpSeq, QueryId,
};
use chrono::{DateTime, Utc};
use connlib_shared::{
    messages::{
        client::{ResourceDescriptionCidr, ResourceDescriptionDns},
        ClientId, DnsServer, GatewayId, ResourceId,
    },
    proptest::*,
    DomainName,
};
use hickory_proto::rr::RecordType;
use ip_network_table::IpNetworkTable;
use itertools::Itertools;
use proptest::{prelude::*, sample};
use proptest_state_machine::ReferenceStateMachine;
use std::{
    collections::{BTreeMap, BTreeSet, HashSet, VecDeque},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
    time::{Duration, Instant},
};

/// The reference state machine of the tunnel.
///
/// This is the "expected" part of our test.
#[derive(Clone, Debug)]
pub(crate) struct ReferenceState {
    pub(crate) now: Instant,
    pub(crate) utc_now: DateTime<Utc>,
    pub(crate) client: SimNode<ClientId, PrivateKey>,
    pub(crate) gateway: SimNode<GatewayId, PrivateKey>,
    pub(crate) relay: SimRelay<u64>,

    /// The DNS resolvers configured on the client outside of connlib.
    pub(crate) system_dns_resolvers: Vec<IpAddr>,
    /// The upstream DNS resolvers configured in the portal.
    pub(crate) upstream_dns_resolvers: Vec<DnsServer>,

    /// The CIDR resources the client is aware of.
    pub(crate) client_cidr_resources: IpNetworkTable<ResourceDescriptionCidr>,
    /// The DNS resources the client is aware of.
    pub(crate) client_dns_resources: BTreeMap<ResourceId, ResourceDescriptionDns>,

    /// The client's DNS records.
    ///
    /// The IPs assigned to a domain by connlib are an implementation detail that we don't want to model in these tests.
    /// Instead, we just remember what _kind_ of records we resolved to be able to sample a matching src IP.
    client_dns_records: BTreeMap<DomainName, HashSet<RecordType>>,

    /// The CIDR resources the client is connected to.
    client_connected_cidr_resources: HashSet<ResourceId>,

    /// The DNS resources the client is connected to.
    client_connected_dns_resources: HashSet<(ResourceId, DomainName)>,

    /// All IP addresses a domain resolves to in our test.
    ///
    /// This is used to e.g. mock DNS resolution on the gateway.
    pub(crate) global_dns_records: BTreeMap<DomainName, HashSet<IpAddr>>,

    /// The expected ICMP handshakes.
    pub(crate) expected_icmp_handshakes: VecDeque<(ResourceDst, IcmpSeq, IcmpIdentifier)>,
    /// The expected DNS handshakes.
    pub(crate) expected_dns_handshakes: VecDeque<QueryId>,
}

#[derive(Debug, Clone)]
pub(crate) enum ResourceDst {
    Cidr(IpAddr),
    Dns(DomainName),
}

/// Implementation of our reference state machine.
///
/// The logic in here represents what we expect the [`ClientState`] & [`GatewayState`] to do.
/// Care has to be taken that we don't implement things in a buggy way here.
/// After all, if your test has bugs, it won't catch any in the actual implementation.
impl ReferenceStateMachine for ReferenceState {
    type State = Self;
    type Transition = Transition;

    fn init_state() -> proptest::prelude::BoxedStrategy<Self::State> {
        (
            sim_node_prototype(client_id()),
            sim_node_prototype(gateway_id()),
            sim_relay_prototype(),
            system_dns_servers(),
            upstream_dns_servers(),
            global_dns_records(), // Start out with a set of global DNS records so we have something to resolve outside of DNS resources.
            Just(Instant::now()),
            Just(Utc::now()),
        )
            .prop_filter(
                "client and gateway priv key must be different",
                |(c, g, _, _, _, _, _, _)| c.state != g.state,
            )
            .prop_filter(
                "client, gateway and relay ip must be different",
                |(c, g, r, _, _, _, _, _)| {
                    let c4 = c.ip4_socket.map(|s| *s.ip());
                    let g4 = g.ip4_socket.map(|s| *s.ip());
                    let r4 = r.ip_stack().as_v4().copied();

                    let c6 = c.ip6_socket.map(|s| *s.ip());
                    let g6 = g.ip6_socket.map(|s| *s.ip());
                    let r6 = r.ip_stack().as_v6().copied();

                    let c4_eq_g4 = c4.is_some_and(|c| g4.is_some_and(|g| c == g));
                    let c6_eq_g6 = c6.is_some_and(|c| g6.is_some_and(|g| c == g));
                    let c4_eq_r4 = c4.is_some_and(|c| r4.is_some_and(|r| c == r));
                    let c6_eq_r6 = c6.is_some_and(|c| r6.is_some_and(|r| c == r));
                    let g4_eq_r4 = g4.is_some_and(|g| r4.is_some_and(|r| g == r));
                    let g6_eq_r6 = g6.is_some_and(|g| r6.is_some_and(|r| g == r));

                    !c4_eq_g4 && !c6_eq_g6 && !c4_eq_r4 && !c6_eq_r6 && !g4_eq_r4 && !g6_eq_r6
                },
            )
            .prop_filter(
                "at least one DNS server needs to be reachable",
                |(c, _, _, system_dns, upstream_dns, _, _, _)| {
                    // TODO: PRODUCTION CODE DOES NOT HANDLE THIS!

                    if !upstream_dns.is_empty() {
                        if c.ip4_socket.is_none() && upstream_dns.iter().all(|s| s.ip().is_ipv4()) {
                            return false;
                        }
                        if c.ip6_socket.is_none() && upstream_dns.iter().all(|s| s.ip().is_ipv6()) {
                            return false;
                        }

                        return true;
                    }

                    if c.ip4_socket.is_none() && system_dns.iter().all(|s| s.is_ipv4()) {
                        return false;
                    }
                    if c.ip6_socket.is_none() && system_dns.iter().all(|s| s.is_ipv6()) {
                        return false;
                    }

                    true
                },
            )
            .prop_map(
                |(
                    client,
                    gateway,
                    relay,
                    system_dns_resolvers,
                    upstream_dns_resolvers,
                    global_dns_records,
                    now,
                    utc_now,
                )| Self {
                    now,
                    utc_now,
                    client,
                    gateway,
                    relay,
                    system_dns_resolvers,
                    upstream_dns_resolvers,
                    global_dns_records,
                    client_cidr_resources: IpNetworkTable::new(),
                    client_connected_cidr_resources: Default::default(),
                    expected_icmp_handshakes: Default::default(),
                    client_dns_resources: Default::default(),
                    client_dns_records: Default::default(),
                    expected_dns_handshakes: Default::default(),
                    client_connected_dns_resources: Default::default(),
                },
            )
            .boxed()
    }

    /// Defines the [`Strategy`] on how we can [transition](Transition) from the current [`ReferenceState`].
    ///
    /// This is invoked by proptest repeatedly to explore further state transitions.
    /// Here, we should only generate [`Transition`]s that make sense for the current state.
    fn transitions(state: &Self::State) -> proptest::prelude::BoxedStrategy<Self::Transition> {
        CompositeStrategy::default()
            .with(
                1,
                (0..=1000u64).prop_map(|millis| Transition::Tick { millis }),
            )
            .with(
                1,
                system_dns_servers()
                    .prop_map(|servers| Transition::UpdateSystemDnsServers { servers }),
            )
            .with(
                1,
                upstream_dns_servers()
                    .prop_map(|servers| Transition::UpdateUpstreamDnsServers { servers }),
            )
            .with(1, cidr_resource(8).prop_map(Transition::AddCidrResource))
            .with(
                1,
                prop_oneof![
                    non_wildcard_dns_resource(),
                    star_wildcard_dns_resource(),
                    question_mark_wildcard_dns_resource(),
                ],
            )
            .with_if_not_empty(10, state.ipv4_cidr_resource_dsts(), |ip4_resources| {
                icmp_to_cidr_resource(
                    packet_source_v4(state.client.tunnel_ip4),
                    sample::select(ip4_resources),
                )
            })
            .with_if_not_empty(10, state.ipv6_cidr_resource_dsts(), |ip6_resources| {
                icmp_to_cidr_resource(
                    packet_source_v6(state.client.tunnel_ip6),
                    sample::select(ip6_resources),
                )
            })
            .with_if_not_empty(10, state.resolved_v4_domains(), |dns_v4_domains| {
                icmp_to_dns_resource(
                    packet_source_v4(state.client.tunnel_ip4),
                    sample::select(dns_v4_domains),
                )
            })
            .with_if_not_empty(10, state.resolved_v6_domains(), |dns_v6_domains| {
                icmp_to_dns_resource(
                    packet_source_v6(state.client.tunnel_ip6),
                    sample::select(dns_v6_domains),
                )
            })
            .with_if_not_empty(
                10,
                (
                    state.all_domains(),
                    state.v4_dns_servers(),
                    state.client.ip4_socket,
                ),
                |(domains, v4_dns_servers, _)| {
                    dns_query(sample::select(domains), sample::select(v4_dns_servers))
                },
            )
            .with_if_not_empty(
                10,
                (
                    state.all_domains(),
                    state.v6_dns_servers(),
                    state.client.ip6_socket,
                ),
                |(domains, v6_dns_servers, _)| {
                    dns_query(sample::select(domains), sample::select(v6_dns_servers))
                },
            )
            .with_if_not_empty(
                1,
                state.resolved_ip4_for_non_resources(),
                |resolved_non_resource_ip4s| {
                    ping_random_ip(
                        packet_source_v4(state.client.tunnel_ip4),
                        sample::select(resolved_non_resource_ip4s),
                    )
                },
            )
            .with_if_not_empty(
                1,
                state.resolved_ip6_for_non_resources(),
                |resolved_non_resource_ip6s| {
                    ping_random_ip(
                        packet_source_v6(state.client.tunnel_ip6),
                        sample::select(resolved_non_resource_ip6s),
                    )
                },
            )
            .with_if_not_empty(1, state.all_resources(), |resources| {
                sample::select(resources).prop_map(Transition::RemoveResource)
            })
            .boxed()
    }

    /// Apply the transition to our reference state.
    ///
    /// Here is where we implement the "expected" logic.
    fn apply(mut state: Self::State, transition: &Self::Transition) -> Self::State {
        match transition {
            Transition::AddCidrResource(r) => {
                state.client_cidr_resources.insert(r.address, r.clone());
            }
            Transition::RemoveResource(id) => {
                state.client_cidr_resources.retain(|_, r| &r.id != id);
                state.client_connected_cidr_resources.remove(id);
                state.client_dns_resources.remove(id);
            }
            Transition::AddDnsResource {
                resource: new_resource,
                records,
            } => {
                let existing_resource = state
                    .client_dns_resources
                    .insert(new_resource.id, new_resource.clone());

                // For the client, there is no difference between a DNS resource and a truly global DNS name.
                // We store all records in the same map to follow the same model.
                state.global_dns_records.extend(records.clone());

                // If a resource is updated (i.e. same ID but different address) and we are currently connected, we disconnect from it.
                if let Some(resource) = existing_resource {
                    if new_resource.address != resource.address {
                        state.client_connected_cidr_resources.remove(&resource.id);

                        state
                            .global_dns_records
                            .retain(|name, _| !matches_domain(&resource.address, name));

                        // TODO: IN PRODUCTION, WE CANNOT DO THIS.
                        // CHANGING A DNS RESOURCE BREAKS CLIENT UNTIL THEY DECIDE TO RE-QUERY THE RESOURCE.
                        // WE DO THIS HERE TO ENSURE THE TEST DOESN'T RUN INTO THIS.
                        state
                            .client_dns_records
                            .retain(|name, _| !matches_domain(&resource.address, name));
                    }
                }
            }
            Transition::SendDnsQuery {
                domain,
                r_type,
                dns_server,
                query_id,
                ..
            } => match state.dns_query_via_cidr_resource(dns_server.ip(), domain) {
                Some(resource) if !state.client_connected_cidr_resources.contains(&resource) => {
                    state.client_connected_cidr_resources.insert(resource);
                }
                Some(_) | None => {
                    state
                        .client_dns_records
                        .entry(domain.clone())
                        .or_default()
                        .insert(*r_type);
                    state.expected_dns_handshakes.push_back(*query_id);
                }
            },
            Transition::SendICMPPacketToNonResourceIp { .. } => {
                // Packets to non-resources are dropped, no state change required.
            }
            Transition::SendICMPPacketToCidrResource {
                src,
                dst,
                seq,
                identifier,
                ..
            } => {
                state.on_icmp_packet_to_cidr(*src, *dst, *seq, *identifier);
            }
            Transition::SendICMPPacketToDnsResource {
                src,
                dst,
                seq,
                identifier,
                ..
            } => state.on_icmp_packet_to_dns(*src, dst.clone(), *seq, *identifier),
            Transition::Tick { millis } => state.now += Duration::from_millis(*millis),
            Transition::UpdateSystemDnsServers { servers } => {
                state.system_dns_resolvers.clone_from(servers);
            }
            Transition::UpdateUpstreamDnsServers { servers } => {
                state.upstream_dns_resolvers.clone_from(servers);
            }
        };

        state
    }

    /// Any additional checks on whether a particular [`Transition`] can be applied to a certain state.
    fn preconditions(state: &Self::State, transition: &Self::Transition) -> bool {
        match transition {
            Transition::AddCidrResource(r) => {
                // TODO: PRODUCTION CODE DOES NOT HANDLE THIS!

                if r.address.is_ipv6() && state.gateway.ip6_socket.is_none() {
                    return false;
                }

                if r.address.is_ipv4() && state.gateway.ip4_socket.is_none() {
                    return false;
                }

                // TODO: PRODUCTION CODE DOES NOT HANDLE THIS!
                for dns_resolved_ip in state.global_dns_records.values().flat_map(|ip| ip.iter()) {
                    // If the CIDR resource overlaps with an IP that a DNS record resolved to, we have problems ...
                    if r.address.contains(*dns_resolved_ip) {
                        return false;
                    }
                }

                true
            }
            Transition::AddDnsResource { records, .. } => {
                // TODO: Should we allow adding a DNS resource if we don't have an DNS resolvers?

                // TODO: For these tests, we assign the resolved IP of a DNS resource as part of this transition.
                // Connlib cannot know, when a DNS record expires, thus we currently don't allow to add DNS resources where the same domain resolves to different IPs

                for (name, resolved_ips) in records {
                    if state.global_dns_records.contains_key(name) {
                        return false;
                    }

                    // TODO: PRODUCTION CODE DOES NOT HANDLE THIS.
                    let any_real_ip_overlaps_with_cidr_resource = resolved_ips
                        .iter()
                        .any(|resolved_ip| state.cidr_resource_by_ip(*resolved_ip).is_some());

                    if any_real_ip_overlaps_with_cidr_resource {
                        return false;
                    }
                }

                true
            }
            Transition::Tick { .. } => true,
            Transition::SendICMPPacketToNonResourceIp {
                dst,
                seq,
                identifier,
                ..
            } => {
                let is_valid_icmp_packet = state.is_valid_icmp_packet(seq, identifier);
                let is_cidr_resource = state.client_cidr_resources.longest_match(*dst).is_some();

                is_valid_icmp_packet && !is_cidr_resource
            }
            Transition::SendICMPPacketToCidrResource {
                seq, identifier, ..
            } => state.is_valid_icmp_packet(seq, identifier),
            Transition::SendICMPPacketToDnsResource {
                seq,
                identifier,
                dst,
                src,
                ..
            } => {
                state.is_valid_icmp_packet(seq, identifier)
                    && state
                        .client_dns_records
                        .get(dst)
                        .is_some_and(|r| match src {
                            IpAddr::V4(_) => r.contains(&RecordType::A),
                            IpAddr::V6(_) => r.contains(&RecordType::AAAA),
                        })
            }
            Transition::UpdateSystemDnsServers { servers } => {
                // TODO: PRODUCTION CODE DOES NOT HANDLE THIS!

                if state.client.ip4_socket.is_none() && servers.iter().all(|s| s.is_ipv4()) {
                    return false;
                }
                if state.client.ip6_socket.is_none() && servers.iter().all(|s| s.is_ipv6()) {
                    return false;
                }

                true
            }
            Transition::UpdateUpstreamDnsServers { servers } => {
                // TODO: PRODUCTION CODE DOES NOT HANDLE THIS!

                if state.client.ip4_socket.is_none() && servers.iter().all(|s| s.ip().is_ipv4()) {
                    return false;
                }
                if state.client.ip6_socket.is_none() && servers.iter().all(|s| s.ip().is_ipv6()) {
                    return false;
                }

                true
            }
            Transition::SendDnsQuery {
                domain, dns_server, ..
            } => {
                state.global_dns_records.contains_key(domain)
                    && state.expected_dns_servers().contains(dns_server)
            }
            Transition::RemoveResource(id) => {
                state.client_cidr_resources.iter().any(|(_, r)| &r.id == id)
                    || state.client_dns_resources.contains_key(id)
            }
        }
    }
}

/// Pub(crate) functions used across the test suite.
impl ReferenceState {
    /// Returns the DNS servers that we expect connlib to use.
    ///
    /// If there are upstream DNS servers configured in the portal, it should use those.
    /// Otherwise it should use whatever was configured on the system prior to connlib starting.
    pub(crate) fn expected_dns_servers(&self) -> BTreeSet<SocketAddr> {
        if !self.upstream_dns_resolvers.is_empty() {
            return self
                .upstream_dns_resolvers
                .iter()
                .map(|s| s.address())
                .collect();
        }

        self.system_dns_resolvers
            .iter()
            .map(|ip| SocketAddr::new(*ip, 53))
            .collect()
    }
}

/// Several helper functions to make the reference state more readable.
impl ReferenceState {
    #[tracing::instrument(level = "debug", skip_all, fields(dst, resource))]
    fn on_icmp_packet_to_cidr(&mut self, src: IpAddr, dst: IpAddr, seq: u16, identifier: u16) {
        tracing::Span::current().record("dst", tracing::field::display(dst));

        // Second, if we are not yet connected, check if we have a resource for this IP.
        let Some((_, resource)) = self.client_cidr_resources.longest_match(dst) else {
            tracing::debug!("No resource corresponds to IP");
            return;
        };

        if self.client_connected_cidr_resources.contains(&resource.id)
            && self.client.is_tunnel_ip(src)
        {
            tracing::debug!("Connected to CIDR resource, expecting packet to be routed");
            self.expected_icmp_handshakes
                .push_back((ResourceDst::Cidr(dst), seq, identifier));
            return;
        }

        // If we have a resource, the first packet will initiate a connection to the gateway.
        tracing::debug!("Not connected to resource, expecting to trigger connection intent");
        self.client_connected_cidr_resources.insert(resource.id);
    }

    #[tracing::instrument(level = "debug", skip_all, fields(dst, resource))]
    fn on_icmp_packet_to_dns(&mut self, src: IpAddr, dst: DomainName, seq: u16, identifier: u16) {
        tracing::Span::current().record("dst", tracing::field::display(&dst));

        let Some(resource) = self.dns_resource_by_domain(&dst) else {
            return;
        };

        if self
            .client_connected_dns_resources
            .contains(&(resource, dst.clone()))
            && self.client.is_tunnel_ip(src)
        {
            tracing::debug!("Connected to DNS resource, expecting packet to be routed");
            self.expected_icmp_handshakes
                .push_back((ResourceDst::Dns(dst), seq, identifier));
            return;
        }

        if self.client_dns_records.iter().any(|(name, _)| name == &dst) {
            self.client_connected_dns_resources.insert((resource, dst));
        }
    }

    fn ipv4_cidr_resource_dsts(&self) -> Vec<Ipv4Addr> {
        let mut ips = vec![];

        // This is an imperative loop on purpose because `ip-network` appears to have a bug with its `size_hint` and thus `.extend` does not work reliably?
        for (network, _) in self.client_cidr_resources.iter_ipv4() {
            if network.netmask() == 31 || network.netmask() == 32 {
                ips.push(network.network_address());
            } else {
                for ip in network.hosts() {
                    ips.push(ip)
                }
            }
        }

        ips
    }

    fn ipv6_cidr_resource_dsts(&self) -> Vec<Ipv6Addr> {
        let mut ips = vec![];

        // This is an imperative loop on purpose because `ip-network` appears to have a bug with its `size_hint` and thus `.extend` does not work reliably?
        for (network, _) in self.client_cidr_resources.iter_ipv6() {
            if network.netmask() == 127 || network.netmask() == 128 {
                ips.push(network.network_address());
            } else {
                for ip in network
                    .subnets_with_prefix(128)
                    .map(|i| i.network_address())
                {
                    ips.push(ip)
                }
            }
        }

        ips
    }

    fn resolved_v4_domains(&self) -> Vec<DomainName> {
        self.resolved_domains()
            .filter_map(|(domain, records)| {
                records
                    .iter()
                    .any(|r| matches!(r, RecordType::A))
                    .then_some(domain)
            })
            .collect()
    }

    fn resolved_v6_domains(&self) -> Vec<DomainName> {
        self.resolved_domains()
            .filter_map(|(domain, records)| {
                records
                    .iter()
                    .any(|r| matches!(r, RecordType::AAAA))
                    .then_some(domain)
            })
            .collect()
    }

    fn all_domains(&self) -> Vec<DomainName> {
        self.global_dns_records.keys().cloned().collect()
    }

    fn resolved_domains(&self) -> impl Iterator<Item = (DomainName, HashSet<RecordType>)> + '_ {
        self.client_dns_records
            .iter()
            .filter(|(domain, _)| self.dns_resource_by_domain(domain).is_some())
            .map(|(domain, ips)| (domain.clone(), ips.clone()))
    }

    /// An ICMP packet is valid if we didn't yet send an ICMP packet with the same seq and identifier.
    fn is_valid_icmp_packet(&self, seq: &u16, identifier: &u16) -> bool {
        self.expected_icmp_handshakes
            .iter()
            .all(|(_, existing_seq, existing_identifer)| {
                existing_seq != seq && existing_identifer != identifier
            })
    }

    fn v4_dns_servers(&self) -> Vec<SocketAddrV4> {
        self.expected_dns_servers()
            .into_iter()
            .filter_map(|s| match s {
                SocketAddr::V4(v4) => Some(v4),
                SocketAddr::V6(_) => None,
            })
            .collect()
    }

    fn v6_dns_servers(&self) -> Vec<SocketAddrV6> {
        self.expected_dns_servers()
            .into_iter()
            .filter_map(|s| match s {
                SocketAddr::V6(v6) => Some(v6),
                SocketAddr::V4(_) => None,
            })
            .collect()
    }

    fn dns_resource_by_domain(&self, domain: &DomainName) -> Option<ResourceId> {
        self.client_dns_resources
            .values()
            .filter(|r| is_subdomain(&domain.to_string(), &r.address))
            .sorted_by_key(|r| r.address.len())
            .rev()
            .map(|r| r.id)
            .next()
    }

    fn cidr_resource_by_ip(&self, ip: IpAddr) -> Option<ResourceId> {
        self.client_cidr_resources
            .longest_match(ip)
            .map(|(_, r)| r.id)
    }

    fn resolved_ip4_for_non_resources(&self) -> Vec<Ipv4Addr> {
        self.resolved_ips_for_non_resources()
            .filter_map(|ip| match ip {
                IpAddr::V4(v4) => Some(v4),
                IpAddr::V6(_) => None,
            })
            .collect()
    }

    fn resolved_ip6_for_non_resources(&self) -> Vec<Ipv6Addr> {
        self.resolved_ips_for_non_resources()
            .filter_map(|ip| match ip {
                IpAddr::V6(v6) => Some(v6),
                IpAddr::V4(_) => None,
            })
            .collect()
    }

    fn resolved_ips_for_non_resources(&self) -> impl Iterator<Item = IpAddr> + '_ {
        self.client_dns_records
            .iter()
            .filter_map(|(domain, _)| {
                self.dns_resource_by_domain(domain)
                    .is_none()
                    .then_some(self.global_dns_records.get(domain))
            })
            .flatten()
            .flatten()
            .copied()
    }

    /// Returns the CIDR resource we will forward the DNS query for the given name to.
    ///
    /// DNS servers may be resources, in which case queries that need to be forwarded actually need to be encapsulated.
    fn dns_query_via_cidr_resource(
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

    fn all_resources(&self) -> Vec<ResourceId> {
        let cidr_resources = self.client_cidr_resources.iter().map(|(_, r)| r.id);
        let dns_resources = self.client_dns_resources.keys().copied();

        Vec::from_iter(cidr_resources.chain(dns_resources))
    }
}

fn matches_domain(resource_address: &str, domain: &DomainName) -> bool {
    let name = domain.to_string();

    if resource_address.starts_with('*') || resource_address.starts_with('?') {
        let (_, base) = resource_address.split_once('.').unwrap();

        return name.ends_with(base);
    }

    name == resource_address
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
