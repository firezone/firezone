use crate::{dns::DnsQuery, ClientEvent, ClientState, GatewayEvent, GatewayState, Request};
use bimap::BiMap;
use chrono::{DateTime, Utc};
use connlib_shared::{
    messages::{
        client::{ResourceDescription, ResourceDescriptionCidr, ResourceDescriptionDns, SiteId},
        gateway, ClientId, DnsServer, GatewayId, Interface, RelayId, ResourceId,
    },
    proptest::{cidr_resource, dns_resource, domain_label, domain_name},
    DomainName, StaticSecret,
};
use firezone_relay::{AddressFamily, AllocationPort, ClientSocket, PeerSocket};
use hickory_proto::{
    op::{MessageType, Query},
    rr::{rdata, RData, Record, RecordType},
    serialize::binary::BinDecodable,
};
use hickory_resolver::lookup::Lookup;
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_network_table::IpNetworkTable;
use ip_packet::{IpPacket, MutableIpPacket, Packet};
use pretty_assertions::assert_eq;
use proptest::{
    arbitrary::any,
    collection, prop_oneof, sample,
    strategy::{Just, Strategy, Union},
    test_runner::Config,
};
use proptest_state_machine::{ReferenceStateMachine, StateMachineTest};
use rand::{rngs::StdRng, SeedableRng};
use secrecy::ExposeSecret;
use snownet::{RelaySocket, Transmit};
use std::{
    borrow::Cow,
    collections::{hash_map::Entry, HashMap, HashSet, VecDeque},
    fmt,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
    ops::ControlFlow,
    str::FromStr,
    sync::Arc,
    time::{Duration, Instant, SystemTime},
};
use tracing::{debug_span, error_span, subscriber::DefaultGuard, Span};
use tracing_subscriber::{util::SubscriberInitExt as _, EnvFilter};

proptest_state_machine::prop_state_machine! {
    #![proptest_config(Config {
        cases: 1000,
        .. Config::default()
    })]

    #[test]
    fn run_tunnel_test(sequential 1..20 => TunnelTest);
}

/// The actual system-under-test.
///
/// [`proptest`] manipulates this using [`Transition`]s and we assert it against [`ReferenceState`].
struct TunnelTest {
    now: Instant,
    utc_now: DateTime<Utc>,

    client: SimNode<ClientId, ClientState>,
    gateway: SimNode<GatewayId, GatewayState>,
    relay: SimRelay<firezone_relay::Server<StdRng>>,
    portal: SimPortal,

    /// The DNS records created on the client as a result of received DNS responses.
    ///
    /// This contains results from both, queries to DNS resources and non-resources.
    client_dns_records: HashMap<DomainName, Vec<IpAddr>>,

    /// Bi-directional mapping between connlib's sentinel DNS IPs and the effective DNS servers.
    client_dns_by_sentinel: BiMap<IpAddr, SocketAddr>,

    client_sent_dns_queries: HashMap<QueryId, IpPacket<'static>>,
    client_received_dns_responses: HashMap<QueryId, IpPacket<'static>>,

    client_sent_icmp_requests: HashMap<(u16, u16), IpPacket<'static>>,
    client_received_icmp_replies: HashMap<(u16, u16), IpPacket<'static>>,
    gateway_received_icmp_requests: VecDeque<IpPacket<'static>>,

    #[allow(dead_code)]
    logger: DefaultGuard,
}

/// The reference state machine of the tunnel.
///
/// This is the "expected" part of our test.
#[derive(Clone, Debug)]
struct ReferenceState {
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
enum Transition {
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

impl StateMachineTest for TunnelTest {
    type SystemUnderTest = Self;
    type Reference = ReferenceState;

    // Initialize the system under test from our reference state.
    fn init_test(
        ref_state: &<Self::Reference as ReferenceStateMachine>::State,
    ) -> Self::SystemUnderTest {
        let logger = tracing_subscriber::fmt()
            .with_test_writer()
            .with_env_filter(EnvFilter::from_default_env())
            .finish()
            .set_default();

        // Construct client, gateway and relay from the initial state.
        let mut client = ref_state.client.map_state(
            |key| ClientState::new(StaticSecret::from(key.0)),
            debug_span!("client"),
        );
        let mut gateway = ref_state.gateway.map_state(
            |key| GatewayState::new(StaticSecret::from(key.0)),
            debug_span!("gateway"),
        );
        let relay = SimRelay {
            state: firezone_relay::Server::new(
                ref_state.relay.ip_stack,
                rand::rngs::StdRng::seed_from_u64(ref_state.relay.state),
                3478,
                49152,
                65535,
            ),
            ip_stack: ref_state.relay.ip_stack,
            id: ref_state.relay.id,
            span: error_span!("relay"),
            allocations: ref_state.relay.allocations.clone(),
            buffer: ref_state.relay.buffer.clone(),
        };
        let portal = SimPortal {
            _client: client.id,
            gateway: gateway.id,
            _relay: relay.id,
        };

        // Configure client and gateway with the relay.

        client.state.update_relays(
            HashSet::default(),
            HashSet::from([relay.explode("client")]),
            ref_state.now,
        );
        let _ = client.state.update_interface_config(Interface {
            ipv4: client.tunnel_ip4,
            ipv6: client.tunnel_ip6,
            upstream_dns: ref_state.upstream_dns_resolvers.clone(),
        });
        let _ = client
            .state
            .update_system_resolvers(ref_state.system_dns_resolvers.clone());

        gateway.state.update_relays(
            HashSet::default(),
            HashSet::from([relay.explode("gateway")]),
            ref_state.now,
        );

        let mut this = Self {
            now: ref_state.now,
            utc_now: ref_state.utc_now,
            client,
            gateway,
            portal,
            logger,
            relay,
            client_dns_records: Default::default(),
            client_dns_by_sentinel: Default::default(),
            client_sent_icmp_requests: Default::default(),
            client_received_icmp_replies: Default::default(),
            gateway_received_icmp_requests: Default::default(),
            client_received_dns_responses: Default::default(),
            client_sent_dns_queries: Default::default(),
        };

        let mut buffered_transmits = VecDeque::new();
        this.advance(ref_state, &mut buffered_transmits); // Perform initial setup before we apply the first transition.

        this
    }

    /// Apply a generated state transition to our system under test and assert against the reference state machine.
    ///
    /// This is equivalent to "arrange - act - assert" of a regular test:
    /// 1. We start out in a certain state (arrange)
    /// 2. We apply a [`Transition`] (act)
    /// 3. We assert against the reference state (assert)
    fn apply(
        mut state: Self::SystemUnderTest,
        ref_state: &<Self::Reference as ReferenceStateMachine>::State,
        transition: <Self::Reference as ReferenceStateMachine>::Transition,
    ) -> Self::SystemUnderTest {
        let mut buffered_transmits = VecDeque::new();

        // Act: Apply the transition
        match transition {
            Transition::AddCidrResource(r) => {
                state.client.span.in_scope(|| {
                    state
                        .client
                        .state
                        .add_resources(&[ResourceDescription::Cidr(r)]);
                });
            }
            Transition::AddDnsResource { resource, .. } => state.client.span.in_scope(|| {
                state
                    .client
                    .state
                    .add_resources(&[ResourceDescription::Dns(resource)]);
            }),
            Transition::SendICMPPacketToNonResourceIp {
                dst,
                seq,
                identifier,
            } => {
                let packet = ip_packet::make::icmp_request_packet(
                    state.client.tunnel_ip(dst),
                    dst,
                    seq,
                    identifier,
                );

                buffered_transmits.extend(state.send_ip_packet_client_to_gateway(packet));
            }
            Transition::SendICMPPacketToResolvedNonResourceIp {
                idx,
                seq,
                identifier,
            } => {
                let dst = ref_state
                    .sample_resolved_non_resource_dst(&idx)
                    .expect("Transition to only be sampled if we have at least one non-resource resolved domain");
                let packet = ip_packet::make::icmp_request_packet(
                    state.client.tunnel_ip(dst),
                    dst,
                    seq,
                    identifier,
                );

                buffered_transmits.extend(state.send_ip_packet_client_to_gateway(packet));
            }
            Transition::SendICMPPacketToResource {
                idx,
                seq,
                identifier,
                src,
            } => {
                let dst = ref_state
                    .sample_resource_dst(&idx, src)
                    .expect("Transition to only be sampled if we have at least one resource");
                let dst = dst.into_actual_packet_dst(idx, src, &state.client_dns_records);
                let src = src.into_ip(state.client.tunnel_ip4, state.client.tunnel_ip6);

                let packet = ip_packet::make::icmp_request_packet(src, dst, seq, identifier);

                buffered_transmits.extend(state.send_ip_packet_client_to_gateway(packet));
            }
            Transition::SendDnsQuery {
                r_idx,
                r_type,
                query_id,
                dns_server_idx,
            } => {
                let (domain, _) = ref_state.sample_domain(&r_idx);
                let dns_server = ref_state.sample_dns_server(&dns_server_idx);

                let transmit = state.send_dns_query_for(domain, r_type, query_id, dns_server);

                buffered_transmits.extend(transmit)
            }
            Transition::Tick { millis } => {
                state.now += Duration::from_millis(millis);
            }
            Transition::UpdateSystemDnsServers { servers } => {
                let _ = state.client.state.update_system_resolvers(servers);
            }
            Transition::UpdateUpstreamDnsServers { servers } => {
                let _ = state.client.state.update_interface_config(Interface {
                    ipv4: state.client.tunnel_ip4,
                    ipv6: state.client.tunnel_ip6,
                    upstream_dns: servers,
                });
            }
        };
        state.advance(ref_state, &mut buffered_transmits);
        assert!(buffered_transmits.is_empty()); // Sanity check to ensure we handled all packets.

        // Assert our properties: Check that our actual state is equivalent to our expectation (the reference state).
        assert_icmp_packets_properties(&mut state, ref_state);
        assert_dns_packets_properties(&state, ref_state);
        assert_eq!(
            state.effective_dns_servers(),
            ref_state.expected_dns_servers(),
            "Effective DNS servers should match either system or upstream DNS"
        );

        state
    }
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

impl TunnelTest {
    /// Exhaustively advances all state machines (client, gateway & relay).
    ///
    /// For our tests to work properly, each [`Transition`] needs to advance the state as much as possible.
    /// For example, upon the first packet to a resource, we need to trigger the connection intent and fully establish a connection.
    /// Dispatching a [`Transmit`] (read: packet) to a component can trigger more packets, i.e. receiving a STUN request may trigger a STUN response.
    ///
    /// Consequently, this function needs to loop until no component can make progress at which point we consider the [`Transition`] complete.
    fn advance(
        &mut self,
        ref_state: &ReferenceState,
        buffered_transmits: &mut VecDeque<(Transmit<'static>, Option<SocketAddr>)>,
    ) {
        loop {
            if let Some((transmit, sending_socket)) = buffered_transmits.pop_front() {
                self.dispatch_transmit(
                    transmit,
                    sending_socket,
                    buffered_transmits,
                    &ref_state.global_dns_records,
                );
                continue;
            }

            if let Some(transmit) = self.client.state.poll_transmit() {
                let sending_socket = self.client.sending_socket_for(transmit.dst.ip());

                buffered_transmits.push_back((transmit, sending_socket));
                continue;
            }
            if let Some(event) = self.client.state.poll_event() {
                self.on_client_event(
                    self.client.id,
                    event,
                    &ref_state.client_cidr_resources,
                    &ref_state.client_dns_resources,
                    &ref_state.global_dns_records,
                );
                continue;
            }
            if let Some(query) = self.client.state.poll_dns_queries() {
                self.on_forwarded_dns_query(query, ref_state);
                continue;
            }
            if let Some(packet) = self.client.state.poll_packets() {
                self.on_client_received_packet(packet);
                continue;
            }

            if let Some(transmit) = self.gateway.state.poll_transmit() {
                let sending_socket = self.gateway.sending_socket_for(transmit.dst.ip());

                buffered_transmits.push_back((transmit, sending_socket));
                continue;
            }
            if let Some(event) = self.gateway.state.poll_event() {
                self.on_gateway_event(self.gateway.id, event);
                continue;
            }
            if let Some(message) = self.relay.state.next_command() {
                match message {
                    firezone_relay::Command::SendMessage { payload, recipient } => {
                        let dst = recipient.into_socket();
                        let src = self
                            .relay
                            .sending_socket_for(dst, 3478)
                            .expect("relay to never emit packets without a matching socket");

                        if let ControlFlow::Break(_) = self.try_handle_client(dst, src, &payload) {
                            continue;
                        }

                        if let ControlFlow::Break(_) = self.try_handle_gateway(
                            dst,
                            src,
                            &payload,
                            buffered_transmits,
                            &ref_state.global_dns_records,
                        ) {
                            continue;
                        }

                        panic!("Unhandled packet: {src} -> {dst}")
                    }

                    firezone_relay::Command::CreateAllocation { port, family } => {
                        self.relay.allocations.insert((family, port));
                    }
                    firezone_relay::Command::FreeAllocation { port, family } => {
                        self.relay.allocations.remove(&(family, port));
                    }
                }
                continue;
            }

            if self.handle_timeout(self.now, self.utc_now) {
                continue;
            }

            break;
        }
    }

    /// Returns the _effective_ DNS servers that connlib is using.
    fn effective_dns_servers(&self) -> HashSet<SocketAddr> {
        self.client_dns_by_sentinel
            .right_values()
            .copied()
            .collect()
    }

    /// Forwards time to the given instant iff the corresponding component would like that (i.e. returns a timestamp <= from `poll_timeout`).
    ///
    /// Tying the forwarding of time to the result of `poll_timeout` gives us better coverage because in production, we suspend until the value of `poll_timeout`.
    fn handle_timeout(&mut self, now: Instant, utc_now: DateTime<Utc>) -> bool {
        let mut any_advanced = false;

        if self.client.state.poll_timeout().is_some_and(|t| t <= now) {
            any_advanced = true;

            self.client
                .span
                .in_scope(|| self.client.state.handle_timeout(now));
        };

        if self.gateway.state.poll_timeout().is_some_and(|t| t <= now) {
            any_advanced = true;

            self.gateway
                .span
                .in_scope(|| self.gateway.state.handle_timeout(now, utc_now))
        };

        if self.relay.state.poll_timeout().is_some_and(|t| t <= now) {
            any_advanced = true;

            self.relay
                .span
                .in_scope(|| self.relay.state.handle_timeout(now))
        };

        any_advanced
    }

    fn send_ip_packet_client_to_gateway(
        &mut self,
        packet: MutableIpPacket<'_>,
    ) -> Option<(Transmit<'static>, Option<SocketAddr>)> {
        {
            let packet = packet.to_owned().into_immutable();

            if let Some(icmp) = packet.as_icmp() {
                let echo_request = icmp.as_echo_request().expect("to be echo request");

                self.client_sent_icmp_requests
                    .insert((echo_request.sequence(), echo_request.identifier()), packet);
            }
        }

        {
            let packet = packet.to_owned().into_immutable();

            if let Some(udp) = packet.as_udp() {
                if let Ok(message) = hickory_proto::op::Message::from_bytes(udp.payload()) {
                    debug_assert_eq!(
                        message.message_type(),
                        MessageType::Query,
                        "every DNS message sent from the client should be a DNS query"
                    );

                    self.client_sent_dns_queries.insert(message.id(), packet);
                }
            }
        }

        let transmit = self
            .client
            .span
            .in_scope(|| self.client.state.encapsulate(packet, self.now))?;
        let transmit = transmit.into_owned();
        let sending_socket = self.client.sending_socket_for(transmit.dst.ip());

        Some((transmit, sending_socket))
    }

    fn send_ip_packet_gateway_to_client(
        &mut self,
        packet: MutableIpPacket<'_>,
    ) -> Option<(Transmit<'static>, Option<SocketAddr>)> {
        let transmit = self
            .gateway
            .span
            .in_scope(|| self.gateway.state.encapsulate(packet, self.now))?;
        let transmit = transmit.into_owned();
        let sending_socket = self.gateway.sending_socket_for(transmit.dst.ip());

        Some((transmit, sending_socket))
    }

    /// Dispatches a [`Transmit`] to the correct component.
    ///
    /// This function is basically the "network layer" of our tests.
    /// It takes a [`Transmit`] and checks, which component accepts it, i.e. has configured the correct IP address.
    /// Our tests don't have a concept of a network topology.
    /// This means, components can have IP addresses in completely different subnets, yet this function will still "route" them correctly.
    fn dispatch_transmit(
        &mut self,
        transmit: Transmit,
        sending_socket: Option<SocketAddr>,
        buffered_transmits: &mut VecDeque<(Transmit<'static>, Option<SocketAddr>)>,
        global_dns_records: &HashMap<DomainName, HashSet<IpAddr>>,
    ) {
        let dst = transmit.dst;
        let payload = &transmit.payload;

        let Some(src) = sending_socket else {
            tracing::warn!("Dropping packet to {dst}: no socket");
            return;
        };

        if self
            .try_handle_relay(dst, src, payload, buffered_transmits)
            .is_break()
        {
            return;
        }

        let src = transmit
            .src
            .expect("all packets without src should have been handled via relays");

        if self.try_handle_client(dst, src, payload).is_break() {
            return;
        }

        if self
            .try_handle_gateway(dst, src, payload, buffered_transmits, global_dns_records)
            .is_break()
        {
            return;
        }

        panic!("Unhandled packet: {src} -> {dst}")
    }

    fn try_handle_relay(
        &mut self,
        dst: SocketAddr,
        src: SocketAddr,
        payload: &[u8],
        buffered_transmits: &mut VecDeque<(Transmit<'static>, Option<SocketAddr>)>,
    ) -> ControlFlow<()> {
        if !self.relay.wants(dst) {
            return ControlFlow::Continue(());
        }

        self.relay
            .handle_packet(payload, src, dst, self.now, buffered_transmits);

        ControlFlow::Break(())
    }

    fn try_handle_client(
        &mut self,
        dst: SocketAddr,
        src: SocketAddr,
        payload: &[u8],
    ) -> ControlFlow<()> {
        let mut buffer = [0u8; 2000];

        if !self.client.wants(dst) {
            return ControlFlow::Continue(());
        }

        if let Some(packet) = self.client.span.in_scope(|| {
            self.client
                .state
                .decapsulate(dst, src, payload, self.now, &mut buffer)
        }) {
            self.on_client_received_packet(packet);
        };

        ControlFlow::Break(())
    }

    fn try_handle_gateway(
        &mut self,
        dst: SocketAddr,
        src: SocketAddr,
        payload: &[u8],
        buffered_transmits: &mut VecDeque<(Transmit<'static>, Option<SocketAddr>)>,
        global_dns_records: &HashMap<DomainName, HashSet<IpAddr>>,
    ) -> ControlFlow<()> {
        let mut buffer = [0u8; 2000];

        if !self.gateway.wants(dst) {
            return ControlFlow::Continue(());
        }

        if let Some(packet) = self.gateway.span.in_scope(|| {
            self.gateway
                .state
                .decapsulate(dst, src, payload, self.now, &mut buffer)
        }) {
            let packet = packet.to_owned();

            if packet.as_icmp().is_some() {
                self.gateway_received_icmp_requests
                    .push_back(packet.clone());

                let echo_response = ip_packet::make::icmp_response_packet(packet);
                let maybe_transmit = self.send_ip_packet_gateway_to_client(echo_response);

                buffered_transmits.extend(maybe_transmit);

                return ControlFlow::Break(());
            }

            if packet.as_udp().is_some() {
                let response = ip_packet::make::dns_ok_response(packet, |name| {
                    global_dns_records
                        .get(&hickory_name_to_domain(name.clone()))
                        .cloned()
                        .into_iter()
                        .flatten()
                });

                let maybe_transmit = self.send_ip_packet_gateway_to_client(response);
                buffered_transmits.extend(maybe_transmit);

                return ControlFlow::Break(());
            }

            panic!("Unhandled packet")
        };

        ControlFlow::Break(())
    }

    fn on_client_event(
        &mut self,
        src: ClientId,
        event: ClientEvent,
        client_cidr_resources: &IpNetworkTable<ResourceDescriptionCidr>,
        client_dns_resource: &HashMap<ResourceId, ResourceDescriptionDns>,
        global_dns_records: &HashMap<DomainName, HashSet<IpAddr>>,
    ) {
        match event {
            ClientEvent::NewIceCandidate { candidate, .. } => self.gateway.span.in_scope(|| {
                self.gateway
                    .state
                    .add_ice_candidate(src, candidate, self.now)
            }),
            ClientEvent::InvalidatedIceCandidate { candidate, .. } => self
                .gateway
                .span
                .in_scope(|| self.gateway.state.remove_ice_candidate(src, candidate)),
            ClientEvent::ConnectionIntent {
                resource,
                connected_gateway_ids,
            } => {
                let (gateway, site) = self.portal.handle_connection_intent(
                    resource,
                    connected_gateway_ids,
                    client_cidr_resources,
                    client_dns_resource,
                );

                let request = self
                    .client
                    .span
                    .in_scope(|| {
                        self.client.state.create_or_reuse_connection(
                            resource,
                            gateway,
                            site,
                            HashSet::default(),
                            HashSet::default(),
                        )
                    })
                    .unwrap();

                let resource_id = request.resource_id();

                // Resolve the domain name that we want to talk to to the IP that we generated as part of the Transition for sending a DNS query.
                let resolved_ips = request
                    .domain_name()
                    .into_iter()
                    .flat_map(|domain| global_dns_records.get(&domain).cloned().into_iter())
                    .flat_map(|ips| ips.into_iter().map(IpNetwork::from))
                    .collect();

                let resource = map_client_resource_to_gateway_resource(
                    client_cidr_resources,
                    client_dns_resource,
                    resolved_ips,
                    resource_id,
                );

                match request {
                    Request::NewConnection(new_connection) => {
                        let connection_accepted = self
                            .gateway
                            .span
                            .in_scope(|| {
                                self.gateway.state.accept(
                                    self.client.id,
                                    snownet::Offer {
                                        session_key: new_connection
                                            .client_preshared_key
                                            .expose_secret()
                                            .0
                                            .into(),
                                        credentials: snownet::Credentials {
                                            username: new_connection
                                                .client_payload
                                                .ice_parameters
                                                .username,
                                            password: new_connection
                                                .client_payload
                                                .ice_parameters
                                                .password,
                                        },
                                    },
                                    self.client.state.public_key(),
                                    self.client.tunnel_ip4,
                                    self.client.tunnel_ip6,
                                    HashSet::default(),
                                    HashSet::default(),
                                    new_connection.client_payload.domain,
                                    None, // TODO: How to generate expiry?
                                    resource,
                                    self.now,
                                )
                            })
                            .unwrap();

                        self.client
                            .span
                            .in_scope(|| {
                                self.client.state.accept_answer(
                                    snownet::Answer {
                                        credentials: snownet::Credentials {
                                            username: connection_accepted.ice_parameters.username,
                                            password: connection_accepted.ice_parameters.password,
                                        },
                                    },
                                    resource_id,
                                    self.gateway.state.public_key(),
                                    connection_accepted.domain_response,
                                    self.now,
                                )
                            })
                            .unwrap();
                    }
                    Request::ReuseConnection(reuse_connection) => {
                        if let Some(domain_response) = self.gateway.span.in_scope(|| {
                            self.gateway.state.allow_access(
                                resource,
                                self.client.id,
                                None,
                                reuse_connection.payload,
                            )
                        }) {
                            self.client
                                .span
                                .in_scope(|| {
                                    self.client
                                        .state
                                        .received_domain_parameters(resource_id, domain_response)
                                })
                                .unwrap();
                        };
                    }
                };
            }
            ClientEvent::RefreshResources { .. } => {
                tracing::warn!("Unimplemented");
            }
            ClientEvent::ResourcesChanged { .. } => {
                tracing::warn!("Unimplemented");
            }
            ClientEvent::DnsServersChanged { dns_by_sentinel } => {
                self.client_dns_by_sentinel = dns_by_sentinel;
            }
        }
    }

    fn on_gateway_event(&mut self, src: GatewayId, event: GatewayEvent) {
        match event {
            GatewayEvent::NewIceCandidate { candidate, .. } => self.client.span.in_scope(|| {
                self.client
                    .state
                    .add_ice_candidate(src, candidate, self.now)
            }),
            GatewayEvent::InvalidIceCandidate { candidate, .. } => self
                .client
                .span
                .in_scope(|| self.client.state.remove_ice_candidate(src, candidate)),
        }
    }

    /// Process an IP packet received on the client.
    fn on_client_received_packet(&mut self, packet: IpPacket<'_>) {
        if let Some(icmp) = packet.as_icmp() {
            let echo_reply = icmp.as_echo_reply().expect("to be echo reply");

            self.client_received_icmp_replies.insert(
                (echo_reply.sequence(), echo_reply.identifier()),
                packet.to_owned(),
            );

            return;
        };

        if let Some(udp) = packet.as_udp() {
            if udp.get_source() == 53 {
                let mut message = hickory_proto::op::Message::from_bytes(udp.payload())
                    .expect("ip packets on port 53 to be DNS packets");

                self.client_received_dns_responses
                    .insert(message.id(), packet.to_owned());

                for record in message.take_answers().into_iter() {
                    let domain = hickory_name_to_domain(record.name().clone());

                    let ip = match record.data() {
                        Some(RData::A(rdata::A(ip4))) => IpAddr::from(*ip4),
                        Some(RData::AAAA(rdata::AAAA(ip6))) => IpAddr::from(*ip6),
                        unhandled => {
                            panic!("Unexpected record data: {unhandled:?}")
                        }
                    };

                    self.client_dns_records.entry(domain).or_default().push(ip);
                }

                // Ensure all IPs are always sorted.
                for ips in self.client_dns_records.values_mut() {
                    ips.sort()
                }

                return;
            }
        }

        unimplemented!("Unhandled packet")
    }

    fn send_dns_query_for(
        &mut self,
        domain: DomainName,
        r_type: RecordType,
        query_id: u16,
        dns_server: SocketAddr,
    ) -> Option<(Transmit<'static>, Option<SocketAddr>)> {
        let dns_server = *self
            .client_dns_by_sentinel
            .get_by_right(&dns_server)
            .expect("to have a sentinel DNS server for the sampled one");

        let name = domain_to_hickory_name(domain);

        let src = self.client.tunnel_ip(dns_server);

        let packet = ip_packet::make::dns_query(
            name,
            r_type,
            SocketAddr::new(src, 9999), // An application would pick a random source port that is free.
            SocketAddr::new(dns_server, 53),
            query_id,
        );

        self.send_ip_packet_client_to_gateway(packet)
    }

    // TODO: Should we vary the following things via proptests?
    // - Forwarded DNS query timing out?
    // - hickory error?
    // - TTL?
    fn on_forwarded_dns_query(&mut self, query: DnsQuery<'static>, ref_state: &ReferenceState) {
        let name = query.name.parse::<DomainName>().unwrap(); // TODO: Could `DnsQuery` hold a `DomainName` directly?

        let resolved_ips = &ref_state
            .global_dns_records
            .get(&name)
            .expect("Deferred DNS query to be for known domain");

        let name = domain_to_hickory_name(name);
        let record_type = query.record_type;

        let record_data = resolved_ips
            .iter()
            .filter_map(|ip| match (record_type, ip) {
                (RecordType::A, IpAddr::V4(v4)) => Some(RData::A((*v4).into())),
                (RecordType::AAAA, IpAddr::V6(v6)) => Some(RData::AAAA((*v6).into())),
                (RecordType::A, IpAddr::V6(_)) | (RecordType::AAAA, IpAddr::V4(_)) => None,
                _ => unreachable!(),
            })
            .map(|rdata| Record::from_rdata(name.clone(), 86400_u32, rdata))
            .collect::<Arc<_>>();

        self.client.state.on_dns_result(
            query,
            Ok(Ok(Ok(Lookup::new_with_max_ttl(
                Query::query(name, record_type),
                record_data,
            )))),
        );
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
enum PacketSource {
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

fn map_client_resource_to_gateway_resource(
    client_cidr_resources: &IpNetworkTable<ResourceDescriptionCidr>,
    client_dns_resources: &HashMap<ResourceId, ResourceDescriptionDns>,
    resolved_ips: Vec<IpNetwork>,
    resource_id: ResourceId,
) -> gateway::ResourceDescription<gateway::ResolvedResourceDescriptionDns> {
    let cidr_resource = client_cidr_resources.iter().find_map(|(_, r)| {
        (r.id == resource_id).then_some(gateway::ResourceDescription::Cidr(
            gateway::ResourceDescriptionCidr {
                id: r.id,
                address: r.address,
                name: r.name.clone(),
                filters: Vec::new(),
            },
        ))
    });
    let dns_resource = client_dns_resources.get(&resource_id).map(|r| {
        gateway::ResourceDescription::Dns(gateway::ResolvedResourceDescriptionDns {
            id: r.id,
            name: r.name.clone(),
            filters: Vec::new(),
            domain: r.address.clone(),
            addresses: resolved_ips.clone(),
        })
    });

    cidr_resource
        .or(dns_resource)
        .expect("resource to be a known CIDR or DNS resource")
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

/// Generates a [`Transition`] that sends an ICMP packet to a random IP.
///
/// By chance, it could be that we pick a resource IP here.
/// That is okay as our reference state machine checks separately whether we are pinging a resource here.
fn icmp_to_random_ip() -> impl Strategy<Value = Transition> {
    (any::<IpAddr>(), any::<u16>(), any::<u16>()).prop_map(|(dst, seq, identifier)| {
        Transition::SendICMPPacketToNonResourceIp {
            dst,
            seq,
            identifier,
        }
    })
}

fn icmp_to_cidr_resource() -> impl Strategy<Value = Transition> {
    (
        any::<sample::Index>(),
        any::<u16>(),
        any::<u16>(),
        packet_source(),
    )
        .prop_map(
            move |(r_idx, seq, identifier, src)| Transition::SendICMPPacketToResource {
                idx: r_idx,
                seq,
                identifier,
                src,
            },
        )
}

/// Sample a random [`PacketSource`].
///
/// Packets from random source addresses are tested less frequently.
/// Those are dropped by the gateway so this transition only ensures we have this safe-guard.
fn packet_source() -> impl Strategy<Value = PacketSource> {
    prop_oneof![
        10 => Just(PacketSource::TunnelIp4),
        10 => Just(PacketSource::TunnelIp6),
        1 => any::<IpAddr>().prop_map(PacketSource::Other)
    ]
}

fn icmp_to_resolved_non_resource() -> impl Strategy<Value = Transition> {
    (any::<sample::Index>(), any::<u16>(), any::<u16>()).prop_map(move |(idx, seq, identifier)| {
        Transition::SendICMPPacketToResolvedNonResourceIp {
            idx,
            seq,
            identifier,
        }
    })
}

fn resolved_ips() -> impl Strategy<Value = HashSet<IpAddr>> {
    collection::hash_set(any::<IpAddr>(), 1..6)
}

fn non_wildcard_dns_resource() -> impl Strategy<Value = Transition> {
    (dns_resource(), resolved_ips()).prop_map(|(resource, resolved_ips)| {
        Transition::AddDnsResource {
            records: HashMap::from([(resource.address.parse().unwrap(), resolved_ips)]),
            resource,
        }
    })
}

fn star_wildcard_dns_resource() -> impl Strategy<Value = Transition> {
    dns_resource().prop_flat_map(|r| {
        let wildcard_address = format!("*.{}", r.address);

        let records = subdomain_records(r.address, domain_name(1..3));
        let resource = Just(ResourceDescriptionDns {
            address: wildcard_address,
            ..r
        });

        (resource, records)
            .prop_map(|(resource, records)| Transition::AddDnsResource { records, resource })
    })
}

fn question_mark_wildcard_dns_resource() -> impl Strategy<Value = Transition> {
    dns_resource().prop_flat_map(|r| {
        let wildcard_address = format!("?.{}", r.address);

        let records = subdomain_records(r.address, domain_label());
        let resource = Just(ResourceDescriptionDns {
            address: wildcard_address,
            ..r
        });

        (resource, records)
            .prop_map(|(resource, records)| Transition::AddDnsResource { records, resource })
    })
}

/// A strategy for generating a set of DNS records all nested under the provided base domain.
fn subdomain_records(
    base: String,
    subdomains: impl Strategy<Value = String>,
) -> impl Strategy<Value = HashMap<DomainName, HashSet<IpAddr>>> {
    collection::hash_map(subdomains, resolved_ips(), 1..4).prop_map(move |subdomain_ips| {
        subdomain_ips
            .into_iter()
            .map(|(label, ips)| {
                let domain = format!("{label}.{base}");

                (domain.parse().unwrap(), ips)
            })
            .collect()
    })
}

fn dns_query() -> impl Strategy<Value = Transition> {
    (
        any::<sample::Index>(),
        any::<sample::Index>(),
        prop_oneof![Just(RecordType::A), Just(RecordType::AAAA)],
        any::<u16>(),
    )
        .prop_map(
            move |(r_idx, dns_server_idx, r_type, query_id)| Transition::SendDnsQuery {
                r_idx,
                r_type,
                query_id,
                dns_server_idx,
            },
        )
}

fn client_id() -> impl Strategy<Value = ClientId> {
    (any::<u128>()).prop_map(ClientId::from_u128)
}

fn gateway_id() -> impl Strategy<Value = GatewayId> {
    (any::<u128>()).prop_map(GatewayId::from_u128)
}

/// Generates an IPv4 address for the tunnel interface.
///
/// We use the CG-NAT range for IPv4.
/// See <https://github.com/firezone/firezone/blob/81dfa90f38299595e14ce9e022d1ee919909f124/elixir/apps/domain/lib/domain/network.ex#L7>.
fn tunnel_ip4() -> impl Strategy<Value = Ipv4Addr> {
    any::<sample::Index>().prop_map(|idx| {
        let cgnat_block = Ipv4Network::new(Ipv4Addr::new(100, 64, 0, 0), 11).unwrap();

        let mut hosts = cgnat_block.hosts();

        hosts.nth(idx.index(hosts.len())).unwrap()
    })
}

/// Generates an IPv6 address for the tunnel interface.
///
/// See <https://github.com/firezone/firezone/blob/81dfa90f38299595e14ce9e022d1ee919909f124/elixir/apps/domain/lib/domain/network.ex#L8>.
fn tunnel_ip6() -> impl Strategy<Value = Ipv6Addr> {
    any::<sample::Index>().prop_map(|idx| {
        let cgnat_block =
            Ipv6Network::new(Ipv6Addr::new(64_768, 8_225, 4_369, 0, 0, 0, 0, 0), 107).unwrap();

        let mut subnets = cgnat_block.subnets_with_prefix(128);

        subnets
            .nth(idx.index(subnets.len()))
            .unwrap()
            .network_address()
    })
}

fn sim_node_prototype<ID>(
    id: impl Strategy<Value = ID>,
) -> impl Strategy<Value = SimNode<ID, PrivateKey>>
where
    ID: fmt::Debug,
{
    (
        id,
        any::<[u8; 32]>(),
        firezone_relay::proptest::any_ip_stack(), // We are re-using the strategy here because it is exactly what we need although we are generating a node here and not a relay.
        any::<u16>().prop_filter("port must not be 0", |p| *p != 0),
        any::<u16>().prop_filter("port must not be 0", |p| *p != 0),
        tunnel_ip4(),
        tunnel_ip6(),
    )
        .prop_filter_map(
            "must have at least one socket address",
            |(id, key, ip_stack, v4_port, v6_port, tunnel_ip4, tunnel_ip6)| {
                let ip4_socket = ip_stack.as_v4().map(|ip| SocketAddrV4::new(*ip, v4_port));
                let ip6_socket = ip_stack
                    .as_v6()
                    .map(|ip| SocketAddrV6::new(*ip, v6_port, 0, 0));

                Some(SimNode {
                    id,
                    state: PrivateKey(key),
                    ip4_socket,
                    ip6_socket,
                    tunnel_ip4,
                    tunnel_ip6,
                    span: tracing::Span::none(),
                })
            },
        )
}

fn sim_relay_prototype() -> impl Strategy<Value = SimRelay<u64>> {
    (
        any::<u64>(),
        firezone_relay::proptest::dual_ip_stack(), // For this test, our relays always run in dual-stack mode to ensure connectivity!
        any::<u128>(),
    )
        .prop_map(|(seed, ip_stack, id)| SimRelay {
            id: RelayId::from_u128(id),
            state: seed,
            ip_stack,
            span: tracing::Span::none(),
            allocations: HashSet::new(),
            buffer: vec![0u8; (1 << 16) - 1],
        })
}

fn upstream_dns_servers() -> impl Strategy<Value = Vec<DnsServer>> {
    let ip4_dns_servers = collection::vec(
        any::<Ipv4Addr>().prop_map(|ip| DnsServer::from((ip, 53))),
        1..4,
    );
    let ip6_dns_servers = collection::vec(
        any::<Ipv6Addr>().prop_map(|ip| DnsServer::from((ip, 53))),
        1..4,
    );

    // TODO: PRODUCTION CODE DOES NOT HAVE A SAFEGUARD FOR THIS YET.
    // AN ADMIN COULD CONFIGURE ONLY IPv4 SERVERS IN WHICH CASE WE ARE SCREWED IF THE CLIENT ONLY HAS IPv6 CONNECTIVITY.

    prop_oneof![
        Just(Vec::new()),
        (ip4_dns_servers, ip6_dns_servers).prop_map(|(mut ip4_servers, ip6_servers)| {
            ip4_servers.extend(ip6_servers);

            ip4_servers
        })
    ]
}

fn system_dns_servers() -> impl Strategy<Value = Vec<IpAddr>> {
    collection::vec(any::<IpAddr>(), 1..4) // Always need at least 1 system DNS server. TODO: Should we test what happens if we don't?
}

fn global_dns_records() -> impl Strategy<Value = HashMap<DomainName, HashSet<IpAddr>>> {
    collection::hash_map(
        domain_name(2..4).prop_map(|d| d.parse().unwrap()),
        collection::hash_set(any::<IpAddr>(), 1..6),
        0..15,
    )
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

/// Asserts the following properties for all ICMP handshakes:
/// 1. An ICMP request on the client MUST result in an ICMP response using the same sequence, identifier and flipped src & dst IP.
/// 2. An ICMP request on the gateway MUST target the intended resource:
///     - For CIDR resources, that is the actual CIDR resource IP.
///     - For DNS resources, the IP must match one of the resolved IPs for the domain.
/// 3. For DNS resources, the mapping of proxy IP to actual resource IP must be stable.
fn assert_icmp_packets_properties(state: &mut TunnelTest, ref_state: &ReferenceState) {
    let unexpected_icmp_replies = find_unexpected_entries(
        &ref_state.expected_icmp_handshakes,
        &state.client_received_icmp_replies,
        |(_, seq_a, id_a), (seq_b, id_b)| seq_a == seq_b && id_a == id_b,
    );
    assert_eq!(
        unexpected_icmp_replies,
        Vec::<&IpPacket>::new(),
        "Unexpected ICMP replies on client"
    );

    assert_eq!(
        ref_state.expected_icmp_handshakes.len(),
        state.gateway_received_icmp_requests.len(),
        "Unexpected ICMP requests on gateway"
    );

    tracing::info!(target: "assertions", "✅ Performed the expected {} ICMP handshakes", state.gateway_received_icmp_requests.len());

    let mut mapping = HashMap::new();

    for ((resource_dst, seq, identifier), gateway_received_request) in ref_state
        .expected_icmp_handshakes
        .iter()
        .zip(state.gateway_received_icmp_requests.iter())
    {
        let _guard = tracing::info_span!(target: "assertions", "icmp", %seq, %identifier).entered();

        let client_sent_request = &state
            .client_sent_icmp_requests
            .get(&(*seq, *identifier))
            .expect("to have ICMP request on client");
        let client_received_reply = &state
            .client_received_icmp_replies
            .get(&(*seq, *identifier))
            .expect("to have ICMP reply on client");

        assert_correct_src_and_dst_ips(client_sent_request, client_received_reply);

        assert_eq!(
            gateway_received_request.source(),
            ref_state
                .client
                .tunnel_ip(gateway_received_request.source()),
            "ICMP request on gateway to originate from client"
        );

        match resource_dst {
            ResourceDst::Cidr(resource_dst) => {
                assert_destination_is_cdir_resource(gateway_received_request, resource_dst)
            }
            ResourceDst::Dns(domain) => {
                assert_destination_is_dns_resource(
                    gateway_received_request,
                    &ref_state.global_dns_records,
                    domain,
                );
                assert_proxy_ip_mapping_is_stable(
                    client_sent_request,
                    gateway_received_request,
                    &mut mapping,
                )
            }
        }
    }
}

fn assert_correct_src_and_dst_ips(
    client_sent_request: &IpPacket<'_>,
    client_received_reply: &IpPacket<'_>,
) {
    assert_eq!(
        client_sent_request.destination(),
        client_received_reply.source(),
        "request destination == reply source"
    );

    tracing::info!(target: "assertions", "✅ dst IP of request matches src IP of response: {}", client_sent_request.destination());

    assert_eq!(
        client_sent_request.source(),
        client_received_reply.destination(),
        "request source == reply destination"
    );

    tracing::info!(target: "assertions", "✅ src IP of request matches dst IP of response: {}", client_sent_request.source());
}

fn assert_correct_src_and_dst_udp_ports(
    client_sent_request: &IpPacket<'_>,
    client_received_reply: &IpPacket<'_>,
) {
    let client_sent_request = client_sent_request.unwrap_as_udp();
    let client_received_reply = client_received_reply.unwrap_as_udp();

    assert_eq!(
        client_sent_request.get_destination(),
        client_received_reply.get_source(),
        "request destination == reply source"
    );

    tracing::info!(target: "assertions", "✅ dst port of request matches src port of response: {}", client_sent_request.get_destination());

    assert_eq!(
        client_sent_request.get_source(),
        client_received_reply.get_destination(),
        "request source == reply destination"
    );

    tracing::info!(target: "assertions", "✅ src port of request matches dst port of response: {}", client_sent_request.get_source());
}

fn assert_destination_is_cdir_resource(
    gateway_received_request: &IpPacket<'_>,
    expected_resource: &IpAddr,
) {
    let gateway_dst = gateway_received_request.destination();

    assert_eq!(
        gateway_dst, *expected_resource,
        "ICMP request on gateway to target correct CIDR resource"
    );

    tracing::info!(target: "assertions", "✅ {gateway_dst} is the correct resource");
}

fn assert_destination_is_dns_resource(
    gateway_received_request: &IpPacket<'_>,
    global_dns_records: &HashMap<DomainName, HashSet<IpAddr>>,
    expected_resource: &DomainName,
) {
    let actual_destination = gateway_received_request.destination();
    let possible_resource_ips = global_dns_records
        .get(expected_resource)
        .expect("ICMP packet for DNS resource to target known domain");

    assert!(
        possible_resource_ips.contains(&actual_destination),
        "ICMP request on gateway to target a known resource IP"
    );

    tracing::info!(target: "assertions", "✅ {actual_destination} is a valid IP for {expected_resource}");
}

/// Assert that the mapping of proxy IP to resource destination is stable.
///
/// How connlib assigns proxy IPs for domains is an implementation detail.
/// Yet, we care that it remains stable to ensure that any form of sticky sessions don't get broken (i.e. packets to one IP are always routed to the same IP on the gateway).
/// To assert this, we build up a map as we iterate through all packets that have been sent.
fn assert_proxy_ip_mapping_is_stable(
    client_sent_request: &IpPacket<'_>,
    gateway_received_request: &IpPacket<'_>,
    mapping: &mut HashMap<IpAddr, IpAddr>,
) {
    let client_dst = client_sent_request.destination();
    let gateway_dst = gateway_received_request.destination();

    match mapping.entry(client_dst) {
        Entry::Vacant(v) => {
            // We have to gradually discover connlib's mapping ...
            // For the first packet, we just save the IP that we ended up talking to.
            v.insert(gateway_dst);
        }
        Entry::Occupied(o) => {
            assert_eq!(
                gateway_dst,
                *o.get(),
                "ICMP request on client to target correct same IP of DNS resource"
            );
            tracing::info!(target: "assertions", "✅ {client_dst} maps to {gateway_dst}");
        }
    }
}

fn assert_dns_packets_properties(state: &TunnelTest, ref_state: &ReferenceState) {
    let unexpected_icmp_replies = find_unexpected_entries(
        &ref_state.expected_dns_handshakes,
        &state.client_received_dns_responses,
        |id_a, id_b| id_a == id_b,
    );

    assert_eq!(
        unexpected_icmp_replies,
        Vec::<&IpPacket>::new(),
        "Unexpected DNS replies on client"
    );

    for query_id in ref_state.expected_dns_handshakes.iter() {
        let _guard = tracing::info_span!(target: "assertions", "dns", %query_id).entered();

        let client_sent_query = state
            .client_sent_dns_queries
            .get(query_id)
            .expect("to have DNS query on client");
        let client_received_response = state
            .client_received_dns_responses
            .get(query_id)
            .expect("to have DNS response on client");

        assert_correct_src_and_dst_ips(client_sent_query, client_received_response);
        assert_correct_src_and_dst_udp_ports(client_sent_query, client_received_response);
    }
}

fn find_unexpected_entries<'a, E, K, V>(
    expected: &VecDeque<E>,
    actual: &'a HashMap<K, V>,
    is_equal: impl Fn(&E, &K) -> bool,
) -> Vec<&'a V> {
    actual
        .iter()
        .filter(|(k, _)| !expected.iter().any(|e| is_equal(e, k)))
        .map(|(_, v)| v)
        .collect()
}
