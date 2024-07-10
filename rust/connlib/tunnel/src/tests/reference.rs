use super::{
    composite_strategy::CompositeStrategy, sim_client::*, sim_gateway::*, sim_net::*, sim_relay::*,
    strategies::*, transition::*,
};
use chrono::{DateTime, Utc};
use connlib_shared::{
    messages::{ClientId, GatewayId, RelayId},
    proptest::*,
    DomainName, StaticSecret,
};
use hickory_proto::rr::RecordType;
use prop::collection;
use proptest::{prelude::*, sample};
use proptest_state_machine::ReferenceStateMachine;
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fmt,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    time::{Duration, Instant},
};

/// The reference state machine of the tunnel.
///
/// This is the "expected" part of our test.
#[derive(Clone, Debug)]
pub(crate) struct ReferenceState {
    pub(crate) now: Instant,
    pub(crate) utc_now: DateTime<Utc>,
    #[allow(clippy::type_complexity)]
    pub(crate) client: Host<RefClient, ClientId>, // TODO: ID will go away once we use a `HashMap` here.
    pub(crate) gateway: Host<RefGateway, GatewayId>,
    pub(crate) relays: HashMap<RelayId, Host<u64, ()>>,

    /// All IP addresses a domain resolves to in our test.
    ///
    /// This is used to e.g. mock DNS resolution on the gateway.
    pub(crate) global_dns_records: BTreeMap<DomainName, HashSet<IpAddr>>,

    pub(crate) network: RoutingTable,
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
        let mut tunnel_ip4s = tunnel_ip4s();
        let mut tunnel_ip6s = tunnel_ip6s();

        (
            ref_client_host(&mut tunnel_ip4s, &mut tunnel_ip6s),
            ref_gateway_host(),
            collection::hash_map(relay_id(), relay_prototype(), 2),
            global_dns_records(), // Start out with a set of global DNS records so we have something to resolve outside of DNS resources.
            Just(Instant::now()),
            Just(Utc::now()),
        )
            .prop_filter_map(
                "network IPs must be unique",
                |(c, g, relays, global_dns, now, utc_now)| {
                    let mut routing_table = RoutingTable::default();

                    if !routing_table.add_host(*c.sim(), &c) {
                        return None;
                    }
                    if !routing_table.add_host(*g.sim(), &g) {
                        return None;
                    };

                    for (id, relay) in &relays {
                        if !routing_table.add_host(*id, relay) {
                            return None;
                        };
                    }

                    Some((c, g, relays, global_dns, now, utc_now, routing_table))
                },
            )
            .prop_filter(
                "client and gateway priv key must be different",
                |(c, g, _, _, _, _, _)| c.inner().key != g.inner().key,
            )
            .prop_map(
                |(client, gateway, relays, global_dns_records, now, utc_now, network)| Self {
                    now,
                    utc_now,
                    client,
                    gateway,
                    relays,
                    global_dns_records,
                    network,
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
            .with(1, roam_client())
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
                    packet_source_v4(state.client.inner().tunnel_ip4),
                    sample::select(ip4_resources),
                )
            })
            .with_if_not_empty(10, state.ipv6_cidr_resource_dsts(), |ip6_resources| {
                icmp_to_cidr_resource(
                    packet_source_v6(state.client.inner().tunnel_ip6),
                    sample::select(ip6_resources),
                )
            })
            .with_if_not_empty(
                10,
                state.client.inner().resolved_v4_domains(),
                |dns_v4_domains| {
                    icmp_to_dns_resource(
                        packet_source_v4(state.client.inner().tunnel_ip4),
                        sample::select(dns_v4_domains),
                    )
                },
            )
            .with_if_not_empty(
                10,
                state.client.inner().resolved_v6_domains(),
                |dns_v6_domains| {
                    icmp_to_dns_resource(
                        packet_source_v6(state.client.inner().tunnel_ip6),
                        sample::select(dns_v6_domains),
                    )
                },
            )
            .with_if_not_empty(
                10,
                (
                    state.all_domains(),
                    state.client.inner().v4_dns_servers(),
                    state.client.ip4,
                ),
                |(domains, v4_dns_servers, _)| {
                    dns_query(sample::select(domains), sample::select(v4_dns_servers))
                },
            )
            .with_if_not_empty(
                10,
                (
                    state.all_domains(),
                    state.client.inner().v6_dns_servers(),
                    state.client.ip6,
                ),
                |(domains, v6_dns_servers, _)| {
                    dns_query(sample::select(domains), sample::select(v6_dns_servers))
                },
            )
            .with_if_not_empty(
                1,
                state
                    .client
                    .inner()
                    .resolved_ip4_for_non_resources(&state.global_dns_records),
                |resolved_non_resource_ip4s| {
                    ping_random_ip(
                        packet_source_v4(state.client.inner().tunnel_ip4),
                        sample::select(resolved_non_resource_ip4s),
                    )
                },
            )
            .with_if_not_empty(
                1,
                state
                    .client
                    .inner()
                    .resolved_ip6_for_non_resources(&state.global_dns_records),
                |resolved_non_resource_ip6s| {
                    ping_random_ip(
                        packet_source_v6(state.client.inner().tunnel_ip6),
                        sample::select(resolved_non_resource_ip6s),
                    )
                },
            )
            .with_if_not_empty(1, state.client.inner().all_resources(), |resources| {
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
                state
                    .client
                    .exec_mut(|client, _| client.cidr_resources.insert(r.address, r.clone()));
            }
            Transition::RemoveResource(id) => {
                state
                    .client
                    .exec_mut(|client, _| client.cidr_resources.retain(|_, r| &r.id != id));
                state
                    .client
                    .exec_mut(|client, _| client.connected_cidr_resources.remove(id));
                state
                    .client
                    .exec_mut(|client, _| client.dns_resources.remove(id));
            }
            Transition::AddDnsResource {
                resource: new_resource,
                records,
            } => {
                let existing_resource = state.client.exec_mut(|client, _| {
                    client
                        .dns_resources
                        .insert(new_resource.id, new_resource.clone())
                });

                // For the client, there is no difference between a DNS resource and a truly global DNS name.
                // We store all records in the same map to follow the same model.
                state.global_dns_records.extend(records.clone());

                // If a resource is updated (i.e. same ID but different address) and we are currently connected, we disconnect from it.
                if let Some(resource) = existing_resource {
                    if new_resource.address != resource.address {
                        state.client.exec_mut(|client, _| {
                            client.connected_cidr_resources.remove(&resource.id)
                        });

                        state
                            .global_dns_records
                            .retain(|name, _| !matches_domain(&resource.address, name));

                        // TODO: IN PRODUCTION, WE CANNOT DO THIS.
                        // CHANGING A DNS RESOURCE BREAKS CLIENT UNTIL THEY DECIDE TO RE-QUERY THE RESOURCE.
                        // WE DO THIS HERE TO ENSURE THE TEST DOESN'T RUN INTO THIS.
                        state.client.exec_mut(|client, _| {
                            client
                                .dns_records
                                .retain(|name, _| !matches_domain(&resource.address, name))
                        });
                    }
                }
            }
            Transition::SendDnsQuery {
                domain,
                r_type,
                dns_server,
                query_id,
                ..
            } => match state
                .client
                .inner()
                .dns_query_via_cidr_resource(dns_server.ip(), domain)
            {
                Some(resource)
                    if !state
                        .client
                        .inner()
                        .connected_cidr_resources
                        .contains(&resource)
                        && !state
                            .client
                            .inner()
                            .known_hosts
                            .contains_key(&domain.to_string()) =>
                {
                    state
                        .client
                        .exec_mut(|client, _| client.connected_cidr_resources.insert(resource));
                }
                Some(_) | None => {
                    state.client.exec_mut(|client, _| {
                        client
                            .dns_records
                            .entry(domain.clone())
                            .or_default()
                            .insert(*r_type)
                    });
                    state
                        .client
                        .exec_mut(|client, _| client.expected_dns_handshakes.push_back(*query_id));
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
                state.client.exec_mut(|client, _| {
                    client.on_icmp_packet_to_cidr(*src, *dst, *seq, *identifier)
                });
            }
            Transition::SendICMPPacketToDnsResource {
                src,
                dst,
                seq,
                identifier,
                ..
            } => state.client.exec_mut(|client, _| {
                client.on_icmp_packet_to_dns(*src, dst.clone(), *seq, *identifier)
            }),
            Transition::Tick { millis } => state.now += Duration::from_millis(*millis),
            Transition::UpdateSystemDnsServers { servers } => {
                state
                    .client
                    .exec_mut(|client, _| client.system_dns_resolvers.clone_from(servers));
            }
            Transition::UpdateUpstreamDnsServers { servers } => {
                state
                    .client
                    .exec_mut(|client, _| client.upstream_dns_resolvers.clone_from(servers));
            }
            Transition::RoamClient { ip4, ip6, .. } => {
                state.network.remove_host(&state.client);
                state.client.ip4.clone_from(ip4);
                state.client.ip6.clone_from(ip6);
                debug_assert!(state.network.add_host(*state.client.sim(), &state.client));

                // When roaming, we are not connected to any resource and wait for the next packet to re-establish a connection.
                state
                    .client
                    .exec_mut(|client, _| client.connected_cidr_resources.clear());
                state
                    .client
                    .exec_mut(|client, _| client.connected_dns_resources.clear());
            }
        };

        state
    }

    /// Any additional checks on whether a particular [`Transition`] can be applied to a certain state.
    fn preconditions(state: &Self::State, transition: &Self::Transition) -> bool {
        match transition {
            Transition::AddCidrResource(r) => {
                // TODO: PRODUCTION CODE DOES NOT HANDLE THIS!

                if r.address.is_ipv6() && state.gateway.ip6.is_none() {
                    return false;
                }

                if r.address.is_ipv4() && state.gateway.ip4.is_none() {
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
                                .client
                                .inner()
                                .cidr_resource_by_ip(*resolved_ip)
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
                ..
            } => {
                let is_valid_icmp_packet =
                    state.client.inner().is_valid_icmp_packet(seq, identifier);
                let is_cidr_resource = state
                    .client
                    .inner()
                    .cidr_resources
                    .longest_match(*dst)
                    .is_some();

                is_valid_icmp_packet && !is_cidr_resource
            }
            Transition::SendICMPPacketToCidrResource {
                seq, identifier, ..
            } => state.client.inner().is_valid_icmp_packet(seq, identifier),
            Transition::SendICMPPacketToDnsResource {
                seq,
                identifier,
                dst,
                src,
                ..
            } => {
                state.client.inner().is_valid_icmp_packet(seq, identifier)
                    && state
                        .client
                        .inner()
                        .dns_records
                        .get(dst)
                        .is_some_and(|r| match src {
                            IpAddr::V4(_) => r.contains(&RecordType::A),
                            IpAddr::V6(_) => r.contains(&RecordType::AAAA),
                        })
            }
            Transition::UpdateSystemDnsServers { servers } => {
                // TODO: PRODUCTION CODE DOES NOT HANDLE THIS!

                if state.client.ip4.is_none() && servers.iter().all(|s| s.is_ipv4()) {
                    return false;
                }
                if state.client.ip6.is_none() && servers.iter().all(|s| s.is_ipv6()) {
                    return false;
                }

                true
            }
            Transition::UpdateUpstreamDnsServers { servers } => {
                // TODO: PRODUCTION CODE DOES NOT HANDLE THIS!

                if state.client.ip4.is_none() && servers.iter().all(|s| s.ip().is_ipv4()) {
                    return false;
                }
                if state.client.ip6.is_none() && servers.iter().all(|s| s.ip().is_ipv6()) {
                    return false;
                }

                true
            }
            Transition::SendDnsQuery {
                domain, dns_server, ..
            } => {
                state.global_dns_records.contains_key(domain)
                    && state
                        .client
                        .inner()
                        .expected_dns_servers()
                        .contains(dns_server)
            }
            Transition::RemoveResource(id) => {
                state
                    .client
                    .inner()
                    .cidr_resources
                    .iter()
                    .any(|(_, r)| &r.id == id)
                    || state.client.inner().dns_resources.contains_key(id)
            }
            Transition::RoamClient { ip4, ip6, port } => {
                // In production, we always rebind to a new port so we never roam to our old existing IP / port combination.

                let is_assigned_ip4 = ip4.is_some_and(|ip| state.network.contains(ip));
                let is_assigned_ip6 = ip6.is_some_and(|ip| state.network.contains(ip));
                let is_previous_port = state.client.old_ports.contains(port);

                !is_assigned_ip4 && !is_assigned_ip6 && !is_previous_port
            }
        }
    }
}

/// Several helper functions to make the reference state more readable.
impl ReferenceState {
    fn ipv4_cidr_resource_dsts(&self) -> Vec<Ipv4Addr> {
        let mut ips = vec![];

        // This is an imperative loop on purpose because `ip-network` appears to have a bug with its `size_hint` and thus `.extend` does not work reliably?
        for (network, _) in self.client.inner().cidr_resources.iter_ipv4() {
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
        for (network, _) in self.client.inner().cidr_resources.iter_ipv6() {
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

    fn all_domains(&self) -> Vec<DomainName> {
        self.global_dns_records
            .keys()
            .cloned()
            .chain(
                self.client
                    .inner()
                    .known_hosts
                    .keys()
                    .map(|h| DomainName::vec_from_str(h).unwrap()),
            )
            .collect()
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

pub(crate) fn private_key() -> impl Strategy<Value = PrivateKey> {
    any::<[u8; 32]>().prop_map(PrivateKey)
}

#[derive(Clone, Copy, PartialEq)]
pub(crate) struct PrivateKey([u8; 32]);

impl From<PrivateKey> for StaticSecret {
    fn from(key: PrivateKey) -> Self {
        StaticSecret::from(key.0)
    }
}

impl fmt::Debug for PrivateKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("PrivateKey")
            .field(&hex::encode(self.0))
            .finish()
    }
}
