use chrono::{DateTime, Utc};
use connlib_shared::{
    messages::{
        client::{ResourceDescriptionCidr, ResourceDescriptionDns, SiteId},
        ClientId, DnsServer, GatewayId, RelayId, ResourceId,
    },
    proptest::cidr_resource,
    DomainName,
};
use firezone_relay::{AddressFamily, AllocationPort, ClientSocket, PeerSocket};
use hickory_proto::rr::RecordType;
use ip_network_table::IpNetworkTable;
use proptest::{
    sample,
    strategy::{Just, Strategy, Union},
    test_runner::Config,
};
use proptest_state_machine::ReferenceStateMachine;
use rand::rngs::StdRng;
use snownet::{RelaySocket, Transmit};
use std::{
    borrow::Cow,
    collections::{HashMap, HashSet, VecDeque},
    fmt,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
    str::FromStr,
    time::{Duration, Instant, SystemTime},
};
use tracing::Span;

mod assertions;
mod strategies;
mod sut;

use assertions::*;
use strategies::*;
use sut::*;

proptest_state_machine::prop_state_machine! {
    #![proptest_config(Config {
        cases: 1000,
        .. Config::default()
    })]

    #[test]
    fn run_tunnel_test(sequential 1..20 => TunnelTest);
}

/// The reference state machine of the tunnel.
///
/// This is the "expected" part of our test.
#[derive(Clone, Debug)]
pub(crate) struct ReferenceState {
    now: Instant,
    utc_now: DateTime<Utc>,
    client: SimNode<ClientId, PrivateKey>,
    gateway: SimNode<GatewayId, PrivateKey>,
    relay: SimRelay<u64>,

    /// The DNS resolvers configured on the client outside of connlib.
    system_dns_resolvers: Vec<IpAddr>,
    /// The upstream DNS resolvers configured in the portal.
    upstream_dns_resolvers: Vec<DnsServer>,

    /// The CIDR resources the client is aware of.
    client_cidr_resources: IpNetworkTable<ResourceDescriptionCidr>,
    /// The DNS resources the client is aware of.
    client_dns_resources: HashMap<ResourceId, ResourceDescriptionDns>,

    /// The IPs the client knows about.
    ///
    /// We resolve A as well as AAAA records at the time of first access.
    /// Those are stored in `global_dns_records`.
    ///
    /// The client's DNS records is a subset of the global DNS records because we remember all results from the DNS queries but only return what was asked for (A or AAAA).
    /// On a repeated query, we will access those previously resolved IPs.
    ///
    /// Essentially, the client's DNS records represents the addresses a client application (like a browser) would _actually_ know about.
    client_dns_records: HashMap<DomainName, Vec<IpAddr>>,

    /// The CIDR resources the client is connected to.
    client_connected_cidr_resources: HashSet<ResourceId>,

    /// All IP addresses a domain resolves to in our test.
    ///
    /// This is used to e.g. mock DNS resolution on the gateway.
    global_dns_records: HashMap<DomainName, HashSet<IpAddr>>,

    /// The expected ICMP handshakes.
    expected_icmp_handshakes: VecDeque<(ResourceDst, IcmpSeq, IcmpIdentifier)>,
    /// The expected DNS handshakes.
    expected_dns_handshakes: VecDeque<QueryId>,
}

type QueryId = u16;
type IcmpSeq = u16;
type IcmpIdentifier = u16;

/// The possible transitions of the state machine.
#[derive(Clone, Debug)]
pub(crate) enum Transition {
    /// Add a new CIDR resource to the client.
    AddCidrResource(ResourceDescriptionCidr),
    /// Send an ICMP packet to non-resource IP.
    SendICMPPacketToNonResourceIp {
        dst: IpAddr,
        seq: u16,
        identifier: u16,
    },
    /// Send an ICMP packet to an IP we resolved via DNS but is not a resource.
    SendICMPPacketToResolvedNonResourceIp {
        idx: sample::Index,
        seq: u16,
        identifier: u16,
    },
    /// Send an ICMP packet to a resource.
    SendICMPPacketToResource {
        idx: sample::Index,
        seq: u16,
        identifier: u16,
        src: PacketSource,
    },

    /// Add a new DNS resource to the client.
    AddDnsResource {
        resource: ResourceDescriptionDns,
        /// The DNS records to add together with the resource.
        records: HashMap<DomainName, HashSet<IpAddr>>,
    },
    /// Send a DNS query.
    SendDnsQuery {
        /// The index into the list of global DNS names (includes all DNS resources).
        r_idx: sample::Index,
        /// The type of DNS query we should send.
        r_type: RecordType,
        /// The DNS query ID.
        query_id: u16,
        /// The index into our list of DNS servers.
        dns_server_idx: sample::Index,
    },

    /// The system's DNS servers changed.
    UpdateSystemDnsServers { servers: Vec<IpAddr> },
    /// The upstream DNS servers changed.
    UpdateUpstreamDnsServers { servers: Vec<DnsServer> },

    /// Advance time by this many milliseconds.
    Tick { millis: u64 },
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
                    let r4 = r.ip_stack.as_v4().copied();

                    let c6 = c.ip6_socket.map(|s| *s.ip());
                    let g6 = g.ip6_socket.map(|s| *s.ip());
                    let r6 = r.ip_stack.as_v6().copied();

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
                },
            )
            .boxed()
    }

    /// Defines the [`Strategy`] on how we can [transition](Transition) from the current [`ReferenceState`].
    ///
    /// This is invoked by proptest repeatedly to explore further state transitions.
    /// Here, we should only generate [`Transition`]s that make sense for the current state.
    fn transitions(state: &Self::State) -> proptest::prelude::BoxedStrategy<Self::Transition> {
        let add_cidr_resource = cidr_resource(8).prop_map(Transition::AddCidrResource);
        let add_non_wildcard_dns_resource = non_wildcard_dns_resource();
        let add_star_wildcard_dns_resource = star_wildcard_dns_resource();
        let add_question_mark_wildcard_dns_resource = question_mark_wildcard_dns_resource();
        let tick = (0..=1000u64).prop_map(|millis| Transition::Tick { millis });
        let set_system_dns_servers =
            system_dns_servers().prop_map(|servers| Transition::UpdateSystemDnsServers { servers });
        let set_upstream_dns_servers = upstream_dns_servers()
            .prop_map(|servers| Transition::UpdateUpstreamDnsServers { servers });

        let mut strategies = vec![
            (1, add_cidr_resource.boxed()),
            (1, add_non_wildcard_dns_resource.boxed()),
            (1, add_star_wildcard_dns_resource.boxed()),
            (1, add_question_mark_wildcard_dns_resource.boxed()),
            (1, tick.boxed()),
            (1, set_system_dns_servers.boxed()),
            (1, set_upstream_dns_servers.boxed()),
            (1, icmp_to_random_ip().boxed()),
        ];

        if !state.client_cidr_resources.is_empty() {
            strategies.push((3, icmp_to_cidr_resource().boxed()));
        }

        if !state.client_dns_resources.is_empty() {
            strategies.extend([(3, dns_query().boxed())]);
        }

        if !state.resolved_ips_for_non_resources().is_empty() {
            strategies.push((1, icmp_to_resolved_non_resource().boxed()));
        }

        Union::new_weighted(strategies).boxed()
    }

    /// Apply the transition to our reference state.
    ///
    /// Here is where we implement the "expected" logic.
    fn apply(mut state: Self::State, transition: &Self::Transition) -> Self::State {
        match transition {
            Transition::AddCidrResource(r) => {
                state.client_cidr_resources.insert(r.address, r.clone());
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
                r_idx,
                r_type,
                dns_server_idx,
                query_id,
                ..
            } => {
                let (domain, all_ips) = state.sample_domain(r_idx);
                let dns_server = state.sample_dns_server(dns_server_idx);

                match state.dns_query_via_cidr_resource(dns_server.ip(), &domain) {
                    Some(resource)
                        if !state.client_connected_cidr_resources.contains(&resource) =>
                    {
                        state.client_connected_cidr_resources.insert(resource);
                    }
                    Some(_) | None => {
                        // Depending on the DNS query type, we filter the resolved addresses.
                        let ips_resolved_by_query = all_ips.iter().copied().filter({
                            #[allow(clippy::wildcard_enum_match_arm)]
                            match r_type {
                                RecordType::A => {
                                    &(|ip: &IpAddr| ip.is_ipv4()) as &dyn Fn(&IpAddr) -> bool
                                }
                                RecordType::AAAA => {
                                    &(|ip: &IpAddr| ip.is_ipv6()) as &dyn Fn(&IpAddr) -> bool
                                }
                                _ => unimplemented!(),
                            }
                        });

                        state
                            .client_dns_records
                            .entry(domain.clone())
                            .or_default()
                            .extend(ips_resolved_by_query);
                        state.expected_dns_handshakes.push_back(*query_id);
                        state.client_dns_records.entry(domain).or_default().sort();
                    }
                }
            }
            Transition::SendICMPPacketToNonResourceIp { .. }
            | Transition::SendICMPPacketToResolvedNonResourceIp { .. } => {
                // Packets to non-resources are dropped, no state change required.
            }
            Transition::SendICMPPacketToResource {
                idx,
                seq,
                identifier,
                src,
            } => {
                let dst = state
                    .sample_resource_dst(idx, *src)
                    .expect("Transition to only be sampled if we have at least one resource");

                state.on_icmp_packet(*src, dst, *seq, *identifier);
            }
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
                    let any_real_ip_overlaps_with_cidr_resource =
                        resolved_ips.iter().any(|resolved_ip| {
                            state
                                .client_cidr_resources
                                .longest_match(*resolved_ip)
                                .is_some()
                        });

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
            } => {
                let is_valid_icmp_packet = state.is_valid_icmp_packet(seq, identifier);
                let is_cidr_resource = state.client_cidr_resources.longest_match(*dst).is_some();
                let is_dns_resource = state.dns_resource_by_ip(*dst).is_some();

                is_valid_icmp_packet && !is_cidr_resource && !is_dns_resource
            }
            Transition::SendICMPPacketToResolvedNonResourceIp {
                idx,
                seq,
                identifier,
            } => {
                if state.sample_resolved_non_resource_dst(idx).is_none() {
                    return false;
                }

                state.is_valid_icmp_packet(seq, identifier)
            }
            Transition::SendICMPPacketToResource {
                idx,
                seq,
                identifier,
                src,
            } => {
                if state.sample_resource_dst(idx, *src).is_none() {
                    return false;
                };

                state.is_valid_icmp_packet(seq, identifier)
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
            Transition::SendDnsQuery { .. } => !state.global_dns_records.is_empty(),
        }
    }
}

/// Several helper functions to make the reference state more readable.
impl ReferenceState {
    #[tracing::instrument(level = "debug", skip_all, fields(dst, resource))]
    fn on_icmp_packet(&mut self, src: PacketSource, dst: ResourceDst, seq: u16, identifier: u16) {
        match &dst {
            ResourceDst::Cidr(ip_dst) => {
                tracing::Span::current().record("dst", tracing::field::display(ip_dst));

                // Second, if we are not yet connected, check if we have a resource for this IP.
                let Some((_, resource)) = self.client_cidr_resources.longest_match(*ip_dst) else {
                    tracing::debug!("No resource corresponds to IP");
                    return;
                };

                if self.client_connected_cidr_resources.contains(&resource.id)
                    && src.originates_from_client()
                {
                    tracing::debug!("Connected to CIDR resource, expecting packet to be routed");
                    self.expected_icmp_handshakes
                        .push_back((dst, seq, identifier));
                    return;
                }

                // If we have a resource, the first packet will initiate a connection to the gateway.
                tracing::debug!(
                    "Not connected to resource, expecting to trigger connection intent"
                );
                self.client_connected_cidr_resources.insert(resource.id);
            }
            ResourceDst::Dns(domain) => {
                tracing::Span::current().record("dst", tracing::field::display(domain));

                if self.client_dns_records.contains_key(domain) && src.originates_from_client() {
                    tracing::debug!("Connected to DNS resource, expecting packet to be routed");
                    self.expected_icmp_handshakes
                        .push_back((dst, seq, identifier));
                    return;
                }
            }
        }
    }

    fn sample_resolved_non_resource_dst(&self, idx: &sample::Index) -> Option<IpAddr> {
        if self.client_dns_records.is_empty()
            || self.client_dns_records.values().all(|ips| ips.is_empty())
        {
            return None;
        }

        let mut dsts = self.resolved_ips_for_non_resources();
        dsts.sort();

        Some(*idx.get(&dsts))
    }

    fn sample_resource_dst(&self, idx: &sample::Index, src: PacketSource) -> Option<ResourceDst> {
        if self.client_cidr_resources.is_empty()
            && (self.client_dns_records.is_empty()
                || self.client_dns_records.values().all(|ips| ips.is_empty()))
        {
            return None;
        }

        let mut dsts = Vec::new();
        dsts.extend(
            self.sample_cidr_resource_dst(idx, src)
                .map(ResourceDst::Cidr),
        );
        dsts.extend(self.sample_resolved_domain(idx, src).map(ResourceDst::Dns));

        if dsts.is_empty() {
            return None;
        }

        Some(idx.get(&dsts).clone())
    }

    fn sample_cidr_resource_dst(&self, idx: &sample::Index, src: PacketSource) -> Option<IpAddr> {
        if self.client_cidr_resources.is_empty() {
            return None;
        }

        let (num_ip4_resources, num_ip6_resources) = self.client_cidr_resources.len();

        let mut ips = Vec::new();

        if num_ip4_resources > 0 && src.is_ipv4() {
            ips.push(self.sample_ipv4_cidr_resource_dst(idx).into())
        }

        if num_ip6_resources > 0 && src.is_ipv6() {
            ips.push(self.sample_ipv6_cidr_resource_dst(idx).into())
        }

        if ips.is_empty() {
            return None;
        }

        Some(*idx.get(&ips))
    }

    /// Samples an [`Ipv4Addr`] from _any_ of our IPv4 CIDR resources.
    fn sample_ipv4_cidr_resource_dst(&self, idx: &sample::Index) -> Ipv4Addr {
        let num_ip4_resources = self.client_cidr_resources.len().0;
        debug_assert!(num_ip4_resources > 0, "cannot sample without any resources");
        let r_idx = idx.index(num_ip4_resources);
        let (network, _) = self
            .client_cidr_resources
            .iter_ipv4()
            .nth(r_idx)
            .expect("index to be in range");

        let num_hosts = network.hosts().len();

        if num_hosts == 0 {
            debug_assert!(network.netmask() == 31 || network.netmask() == 32); // /31 and /32 don't have any hosts

            return network.network_address();
        }

        let addr_idx = idx.index(num_hosts);

        network.hosts().nth(addr_idx).expect("index to be in range")
    }

    /// Samples an [`Ipv6Addr`] from _any_ of our IPv6 CIDR resources.
    fn sample_ipv6_cidr_resource_dst(&self, idx: &sample::Index) -> Ipv6Addr {
        let num_ip6_resources = self.client_cidr_resources.len().1;
        debug_assert!(num_ip6_resources > 0, "cannot sample without any resources");
        let r_idx = idx.index(num_ip6_resources);
        let (network, _) = self
            .client_cidr_resources
            .iter_ipv6()
            .nth(r_idx)
            .expect("index to be in range");

        let num_hosts = network.subnets_with_prefix(128).len();

        let network = if num_hosts == 0 {
            debug_assert!(network.netmask() == 127 || network.netmask() == 128); // /127 and /128 don't have any hosts

            network
        } else {
            let addr_idx = idx.index(num_hosts);

            network
                .subnets_with_prefix(128)
                .nth(addr_idx)
                .expect("index to be in range")
        };

        network.network_address()
    }

    /// An ICMP packet is valid if we didn't yet send an ICMP packet with the same seq and identifier.
    fn is_valid_icmp_packet(&self, seq: &u16, identifier: &u16) -> bool {
        self.expected_icmp_handshakes
            .iter()
            .all(|(_, existing_seq, existing_identifer)| {
                existing_seq != seq && existing_identifer != identifier
            })
    }

    /// Returns the DNS servers that we expect connlib to use.
    ///
    /// If there are upstream DNS servers configured in the portal, it should use those.
    /// Otherwise it should use whatever was configured on the system prior to connlib starting.
    fn expected_dns_servers(&self) -> HashSet<SocketAddr> {
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

    fn sample_domain(&self, idx: &sample::Index) -> (DomainName, HashSet<IpAddr>) {
        let mut domains = self
            .global_dns_records
            .clone()
            .into_iter()
            .collect::<Vec<_>>();
        domains.sort_by_key(|(domain, _)| domain.clone());

        idx.get(&domains).clone()
    }

    fn sample_dns_server(&self, idx: &sample::Index) -> SocketAddr {
        let mut dns_servers = Vec::from_iter(self.expected_dns_servers());
        dns_servers.sort();

        *idx.get(&dns_servers)
    }

    /// Sample a [`DomainName`] that has been resolved to addresses compatible with the [`PacketSource`] (e.g. has IPv4 addresses if we want to send from an IPv4 address).
    fn sample_resolved_domain(&self, idx: &sample::Index, src: PacketSource) -> Option<DomainName> {
        if self.client_dns_records.is_empty() {
            return None;
        }

        let mut resource_records = self
            .client_dns_records
            .iter()
            .filter(|(domain, _)| self.dns_resource_by_domain(domain).is_some())
            .map(|(domain, ips)| (domain.clone(), ips.clone()))
            .collect::<Vec<_>>();
        if resource_records.is_empty() {
            return None;
        }

        resource_records.sort();

        let (name, mut addr) = idx.get(&resource_records).clone();

        addr.retain(|ip| ip.is_ipv4() == src.is_ipv4());

        if addr.is_empty() {
            return None;
        }

        Some(name)
    }

    fn dns_resource_by_domain(&self, domain: &DomainName) -> Option<ResourceId> {
        self.client_dns_resources
            .values()
            .find_map(|r| matches_domain(&r.address, domain).then_some(r.id))
    }

    fn dns_resource_by_ip(&self, ip: IpAddr) -> Option<ResourceId> {
        let domain = self
            .client_dns_records
            .iter()
            .find_map(|(domain, ips)| ips.contains(&ip).then_some(domain))?;

        self.dns_resource_by_domain(domain)
    }

    fn cidr_resource_by_ip(&self, ip: IpAddr) -> Option<ResourceId> {
        self.client_cidr_resources
            .longest_match(ip)
            .map(|(_, r)| r.id)
    }

    fn resolved_ips_for_non_resources(&self) -> Vec<IpAddr> {
        self.client_dns_records
            .iter()
            .filter_map(|(domain, ips)| {
                self.dns_resource_by_domain(domain).is_none().then_some(ips)
            })
            .flatten()
            .copied()
            .collect()
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
}

fn matches_domain(resource_address: &str, domain: &DomainName) -> bool {
    let name = domain.to_string();

    if resource_address.starts_with('*') || resource_address.starts_with('?') {
        let (_, base) = resource_address.split_once('.').unwrap();

        return name.ends_with(base);
    }

    name == resource_address
}

/// The source of the packet that should be sent through the tunnel.
///
/// In normal operation, this will always be either the tunnel's IPv4 or IPv6 address.
/// A malicious client could send packets with a mangled IP but those must be dropped by gateway.
/// To test this case, we also sometimes send packest from a different IP.
#[derive(Debug, Clone, Copy)]
pub(crate) enum PacketSource {
    TunnelIp4,
    TunnelIp6,
    Other(IpAddr),
}

impl PacketSource {
    fn into_ip(self, tunnel_v4: Ipv4Addr, tunnel_v6: Ipv6Addr) -> IpAddr {
        match self {
            PacketSource::TunnelIp4 => tunnel_v4.into(),
            PacketSource::TunnelIp6 => tunnel_v6.into(),
            PacketSource::Other(ip) => ip,
        }
    }

    fn originates_from_client(&self) -> bool {
        matches!(self, PacketSource::TunnelIp4 | PacketSource::TunnelIp6)
    }

    fn is_ipv4(&self) -> bool {
        matches!(
            self,
            PacketSource::TunnelIp4 | PacketSource::Other(IpAddr::V4(_))
        )
    }

    fn is_ipv6(&self) -> bool {
        matches!(
            self,
            PacketSource::TunnelIp6 | PacketSource::Other(IpAddr::V6(_))
        )
    }
}

#[derive(Debug, Clone)]
enum ResourceDst {
    Cidr(IpAddr),
    Dns(DomainName),
}

impl ResourceDst {
    /// Translates a randomly sampled [`ResourceDst`] into the [`IpAddr`] to be used for the packet.
    ///
    /// For CIDR resources, we use the IP directly.
    /// For DNS resources, we need to pick any of the proxy IPs that connlib gave us for the domain name.
    fn into_actual_packet_dst(
        self,
        idx: sample::Index,
        src: PacketSource,
        client_dns_records: &HashMap<DomainName, Vec<IpAddr>>,
    ) -> IpAddr {
        match self {
            ResourceDst::Cidr(ip) => ip,
            ResourceDst::Dns(domain) => {
                let mut ips = client_dns_records
                    .get(&domain)
                    .expect("DNS records to contain domain name")
                    .clone();

                ips.retain(|ip| ip.is_ipv4() == src.is_ipv4());

                *idx.get(&ips)
            }
        }
    }
}

#[derive(Clone)]
struct SimNode<ID, S> {
    id: ID,
    state: S,

    ip4_socket: Option<SocketAddrV4>,
    ip6_socket: Option<SocketAddrV6>,

    tunnel_ip4: Ipv4Addr,
    tunnel_ip6: Ipv6Addr,

    span: Span,
}

#[derive(Clone)]
struct SimRelay<S> {
    id: RelayId,
    state: S,

    ip_stack: firezone_relay::IpStack,
    allocations: HashSet<(AddressFamily, AllocationPort)>,
    buffer: Vec<u8>,

    span: Span,
}

/// Stub implementation of the portal.
///
/// Currently, we only simulate a connection between a single client and a single gateway on a single site.
#[derive(Debug, Clone)]
struct SimPortal {
    _client: ClientId,
    gateway: GatewayId,
    _relay: RelayId,
}

impl<ID, S> SimNode<ID, S>
where
    ID: Copy,
    S: Copy,
{
    fn map_state<T>(&self, f: impl FnOnce(S) -> T, span: Span) -> SimNode<ID, T> {
        SimNode {
            id: self.id,
            state: f(self.state),
            ip4_socket: self.ip4_socket,
            ip6_socket: self.ip6_socket,
            tunnel_ip4: self.tunnel_ip4,
            tunnel_ip6: self.tunnel_ip6,
            span,
        }
    }
}

impl<ID, S> SimNode<ID, S> {
    fn wants(&self, dst: SocketAddr) -> bool {
        self.ip4_socket.is_some_and(|s| SocketAddr::V4(s) == dst)
            || self.ip6_socket.is_some_and(|s| SocketAddr::V6(s) == dst)
    }

    fn sending_socket_for(&self, dst: impl Into<IpAddr>) -> Option<SocketAddr> {
        Some(match dst.into() {
            IpAddr::V4(_) => self.ip4_socket?.into(),
            IpAddr::V6(_) => self.ip6_socket?.into(),
        })
    }

    fn tunnel_ip(&self, dst: impl Into<IpAddr>) -> IpAddr {
        match dst.into() {
            IpAddr::V4(_) => IpAddr::from(self.tunnel_ip4),
            IpAddr::V6(_) => IpAddr::from(self.tunnel_ip6),
        }
    }
}

impl SimRelay<firezone_relay::Server<StdRng>> {
    fn wants(&self, dst: SocketAddr) -> bool {
        let is_direct = self.matching_listen_socket(dst).is_some_and(|s| s == dst);
        let is_allocation_port = self.allocations.contains(&match dst {
            SocketAddr::V4(_) => (AddressFamily::V4, AllocationPort::new(dst.port())),
            SocketAddr::V6(_) => (AddressFamily::V6, AllocationPort::new(dst.port())),
        });
        let is_allocation_ip = self
            .matching_listen_socket(dst)
            .is_some_and(|s| s.ip() == dst.ip());

        is_direct || (is_allocation_port && is_allocation_ip)
    }

    fn sending_socket_for(&self, dst: SocketAddr, port: u16) -> Option<SocketAddr> {
        Some(match dst {
            SocketAddr::V4(_) => SocketAddr::V4(SocketAddrV4::new(*self.ip_stack.as_v4()?, port)),
            SocketAddr::V6(_) => {
                SocketAddr::V6(SocketAddrV6::new(*self.ip_stack.as_v6()?, port, 0, 0))
            }
        })
    }

    fn explode(&self, username: &str) -> (RelayId, RelaySocket, String, String, String) {
        let relay_socket = match self.ip_stack {
            firezone_relay::IpStack::Ip4(ip4) => RelaySocket::V4(SocketAddrV4::new(ip4, 3478)),
            firezone_relay::IpStack::Ip6(ip6) => {
                RelaySocket::V6(SocketAddrV6::new(ip6, 3478, 0, 0))
            }
            firezone_relay::IpStack::Dual { ip4, ip6 } => RelaySocket::Dual {
                v4: SocketAddrV4::new(ip4, 3478),
                v6: SocketAddrV6::new(ip6, 3478, 0, 0),
            },
        };

        let (username, password) = self.make_credentials(username);

        (
            self.id,
            relay_socket,
            username,
            password,
            "firezone".to_owned(),
        )
    }

    fn matching_listen_socket(&self, other: SocketAddr) -> Option<SocketAddr> {
        match other {
            SocketAddr::V4(_) => Some(SocketAddr::new((*self.ip_stack.as_v4()?).into(), 3478)),
            SocketAddr::V6(_) => Some(SocketAddr::new((*self.ip_stack.as_v6()?).into(), 3478)),
        }
    }

    fn ip4(&self) -> Option<IpAddr> {
        self.ip_stack.as_v4().copied().map(|i| i.into())
    }

    fn ip6(&self) -> Option<IpAddr> {
        self.ip_stack.as_v6().copied().map(|i| i.into())
    }

    fn handle_packet(
        &mut self,
        payload: &[u8],
        sender: SocketAddr,
        dst: SocketAddr,
        now: Instant,
        buffered_transmits: &mut VecDeque<(Transmit<'static>, Option<SocketAddr>)>,
    ) {
        if self.matching_listen_socket(dst).is_some_and(|s| s == dst) {
            self.handle_client_input(payload, ClientSocket::new(sender), now, buffered_transmits);
            return;
        }

        self.handle_peer_traffic(
            payload,
            PeerSocket::new(sender),
            AllocationPort::new(dst.port()),
            buffered_transmits,
        )
    }

    fn handle_client_input(
        &mut self,
        payload: &[u8],
        client: ClientSocket,
        now: Instant,
        buffered_transmits: &mut VecDeque<(Transmit<'static>, Option<SocketAddr>)>,
    ) {
        if let Some((port, peer)) = self
            .span
            .in_scope(|| self.state.handle_client_input(payload, client, now))
        {
            let payload = &payload[4..];

            // The `dst` of the relayed packet is what TURN calls a "peer".
            let dst = peer.into_socket();

            // The `src_ip` is the relay's IP
            let src_ip = match dst {
                SocketAddr::V4(_) => {
                    assert!(
                        self.allocations.contains(&(AddressFamily::V4, port)),
                        "IPv4 allocation to be present if we want to send to an IPv4 socket"
                    );

                    self.ip4().expect("listen on IPv4 if we have an allocation")
                }
                SocketAddr::V6(_) => {
                    assert!(
                        self.allocations.contains(&(AddressFamily::V6, port)),
                        "IPv6 allocation to be present if we want to send to an IPv6 socket"
                    );

                    self.ip6().expect("listen on IPv6 if we have an allocation")
                }
            };

            // The `src` of the relayed packet is the relay itself _from_ the allocated port.
            let src = SocketAddr::new(src_ip, port.value());

            // Check if we need to relay to ourselves (from one allocation to another)
            if self.wants(dst) {
                // When relaying to ourselves, we become our own peer.
                let peer_socket = PeerSocket::new(src);
                // The allocation that the data is arriving on is the `dst`'s port.
                let allocation_port = AllocationPort::new(dst.port());

                self.handle_peer_traffic(payload, peer_socket, allocation_port, buffered_transmits);
                return;
            }

            buffered_transmits.push_back((
                Transmit {
                    src: Some(src),
                    dst,
                    payload: Cow::Owned(payload.to_vec()),
                },
                Some(src),
            ));
        }
    }

    fn handle_peer_traffic(
        &mut self,
        payload: &[u8],
        peer: PeerSocket,
        port: AllocationPort,
        buffered_transmits: &mut VecDeque<(Transmit<'static>, Option<SocketAddr>)>,
    ) {
        if let Some((client, channel)) = self
            .span
            .in_scope(|| self.state.handle_peer_traffic(payload, peer, port))
        {
            let full_length = firezone_relay::ChannelData::encode_header_to_slice(
                channel,
                payload.len() as u16,
                &mut self.buffer[..4],
            );
            self.buffer[4..full_length].copy_from_slice(payload);

            let receiving_socket = client.into_socket();
            let sending_socket = self.matching_listen_socket(receiving_socket).unwrap();

            buffered_transmits.push_back((
                Transmit {
                    src: Some(sending_socket),
                    dst: receiving_socket,
                    payload: Cow::Owned(self.buffer[..full_length].to_vec()),
                },
                Some(sending_socket),
            ));
        }
    }

    fn make_credentials(&self, username: &str) -> (String, String) {
        let expiry = SystemTime::now() + Duration::from_secs(60);

        let secs = expiry
            .duration_since(SystemTime::UNIX_EPOCH)
            .expect("expiry must be later than UNIX_EPOCH")
            .as_secs();

        let password =
            firezone_relay::auth::generate_password(self.state.auth_secret(), expiry, username);

        (format!("{secs}:{username}"), password)
    }
}

impl SimPortal {
    /// Picks, which gateway and site we should connect to for the given resource.
    fn handle_connection_intent(
        &self,
        resource: ResourceId,
        _connected_gateway_ids: HashSet<GatewayId>,
        client_cidr_resources: &IpNetworkTable<ResourceDescriptionCidr>,
        client_dns_resources: &HashMap<ResourceId, ResourceDescriptionDns>,
    ) -> (GatewayId, SiteId) {
        // TODO: Should we somehow vary how many gateways we connect to?
        // TODO: Should we somehow pick, which site to use?

        let cidr_site = client_cidr_resources
            .iter()
            .find_map(|(_, r)| (r.id == resource).then_some(r.sites.first()?.id));

        let dns_site = client_dns_resources
            .get(&resource)
            .and_then(|r| Some(r.sites.first()?.id));

        (
            self.gateway,
            cidr_site
                .or(dns_site)
                .expect("resource to be a known CIDR or DNS resource"),
        )
    }
}

impl<ID: fmt::Debug, S: fmt::Debug> fmt::Debug for SimNode<ID, S> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SimNode")
            .field("id", &self.id)
            .field("state", &self.state)
            .field("ip4_socket", &self.ip4_socket)
            .field("ip6_socket", &self.ip6_socket)
            .field("tunnel_ip4", &self.tunnel_ip4)
            .field("tunnel_ip6", &self.tunnel_ip6)
            .finish()
    }
}

impl<S: fmt::Debug> fmt::Debug for SimRelay<S> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SimRelay")
            .field("id", &self.id)
            .field("ip_stack", &self.ip_stack)
            .field("allocations", &self.allocations)
            .finish()
    }
}

#[derive(Clone, Copy, PartialEq)]
struct PrivateKey([u8; 32]);

impl fmt::Debug for PrivateKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("PrivateKey")
            .field(&hex::encode(self.0))
            .finish()
    }
}

fn hickory_name_to_domain(mut name: hickory_proto::rr::Name) -> DomainName {
    name.set_fqdn(false); // Hack to work around hickory always parsing as FQ
    let name = name.to_string();

    let domain = DomainName::from_chars(name.chars()).unwrap();
    debug_assert_eq!(name, domain.to_string());

    domain
}

fn domain_to_hickory_name(domain: DomainName) -> hickory_proto::rr::Name {
    let domain = domain.to_string();

    let name = hickory_proto::rr::Name::from_str(&domain).unwrap();
    debug_assert_eq!(name.to_string(), domain);

    name
}
