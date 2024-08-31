use super::{
    composite_strategy::CompositeStrategy, sim_client::*, sim_dns::*, sim_gateway::*, sim_net::*,
    strategies::*, stub_portal::StubPortal, transition::*,
};
use crate::dns::is_subdomain;
use connlib_shared::{
    messages::{
        client::{self, ResourceDescription},
        GatewayId, RelayId,
    },
    DomainName, StaticSecret,
};
use domain::base::Rtype;
use proptest::{prelude::*, sample};
use proptest_state_machine::ReferenceStateMachine;
use std::{
    collections::{btree_map::Entry, BTreeMap, BTreeSet, HashSet},
    fmt, iter,
    net::{IpAddr, SocketAddr},
};

/// The reference state machine of the tunnel.
///
/// This is the "expected" part of our test.
#[derive(Clone, derivative::Derivative)]
#[derivative(Debug)]
pub(crate) struct ReferenceState {
    pub(crate) client: Host<RefClient>,
    pub(crate) gateways: BTreeMap<GatewayId, Host<RefGateway>>,
    pub(crate) relays: BTreeMap<RelayId, Host<u64>>,
    pub(crate) dns_servers: BTreeMap<DnsServerId, Host<RefDns>>,

    pub(crate) portal: StubPortal,

    pub(crate) drop_direct_client_traffic: bool,

    /// All IP addresses a domain resolves to in our test.
    ///
    /// This is used to e.g. mock DNS resolution on the gateway.
    pub(crate) global_dns_records: BTreeMap<DomainName, BTreeSet<IpAddr>>,

    pub(crate) network: RoutingTable,
}

#[derive(Debug, Clone)]
pub(crate) enum ResourceDst {
    Internet(IpAddr),
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

    fn init_state() -> BoxedStrategy<Self::State> {
        (stub_portal(), dns_servers())
            .prop_flat_map(|(portal, dns_servers)| {
                let gateways = portal.gateways();
                let dns_resource_records = portal.dns_resource_records();
                let client = portal.client(
                    system_dns_servers(dns_servers.values().cloned().collect()),
                    upstream_dns_servers(dns_servers.values().cloned().collect()),
                );
                let relays = relays();
                let global_dns_records = global_dns_records(); // Start out with a set of global DNS records so we have something to resolve outside of DNS resources.
                let drop_direct_client_traffic = any::<bool>();

                (
                    client,
                    gateways,
                    Just(portal),
                    dns_resource_records,
                    relays,
                    global_dns_records,
                    drop_direct_client_traffic,
                    Just(dns_servers),
                )
            })
            .prop_filter_map(
                "network IPs must be unique",
                |(
                    c,
                    gateways,
                    portal,
                    records,
                    relays,
                    mut global_dns,
                    drop_direct_client_traffic,
                    dns_servers,
                )| {
                    let mut routing_table = RoutingTable::default();

                    if !routing_table.add_host(c.inner().id, &c) {
                        return None;
                    }
                    for (id, gateway) in &gateways {
                        if !routing_table.add_host(*id, gateway) {
                            return None;
                        };
                    }

                    for (id, relay) in &relays {
                        if !routing_table.add_host(*id, relay) {
                            return None;
                        };
                    }

                    for (id, dns_server) in &dns_servers {
                        if !routing_table.add_host(*id, dns_server) {
                            return None;
                        };
                    }

                    // Merge all DNS records into `global_dns`.
                    global_dns.extend(records);

                    Some((
                        c,
                        gateways,
                        relays,
                        dns_servers,
                        portal,
                        global_dns,
                        drop_direct_client_traffic,
                        routing_table,
                    ))
                },
            )
            .prop_filter(
                "private keys must be unique",
                |(c, gateways, _, _, _, _, _, _)| {
                    let different_keys = gateways
                        .iter()
                        .map(|(_, g)| g.inner().key)
                        .chain(iter::once(c.inner().key))
                        .collect::<HashSet<_>>();

                    different_keys.len() == gateways.len() + 1
                },
            )
            .prop_map(
                |(
                    client,
                    gateways,
                    relays,
                    dns_servers,
                    portal,
                    global_dns_records,
                    drop_direct_client_traffic,
                    network,
                )| {
                    Self {
                        client,
                        gateways,
                        relays,
                        dns_servers,
                        portal,
                        global_dns_records,
                        network,
                        drop_direct_client_traffic,
                    }
                },
            )
            .boxed()
    }

    /// Defines the [`Strategy`] on how we can [transition](Transition) from the current [`ReferenceState`].
    ///
    /// This is invoked by proptest repeatedly to explore further state transitions.
    /// Here, we should only generate [`Transition`]s that make sense for the current state.
    fn transitions(state: &Self::State) -> BoxedStrategy<Self::Transition> {
        CompositeStrategy::default()
            .with(
                1,
                system_dns_servers(state.dns_servers.values().cloned().collect())
                    .prop_map(Transition::UpdateSystemDnsServers),
            )
            .with(
                1,
                upstream_dns_servers(state.dns_servers.values().cloned().collect())
                    .prop_map(Transition::UpdateUpstreamDnsServers),
            )
            .with_if_not_empty(
                5,
                state.all_resources_not_known_to_client(),
                |resource_ids| sample::select(resource_ids).prop_map(Transition::ActivateResource),
            )
            .with_if_not_empty(1, state.client.inner().all_resource_ids(), |resource_ids| {
                sample::select(resource_ids).prop_map(Transition::DeactivateResource)
            })
            .with(1, roam_client())
            .with(1, relays().prop_map(Transition::DeployNewRelays))
            .with(1, Just(Transition::PartitionRelaysFromPortal))
            .with(1, Just(Transition::ReconnectPortal))
            .with(1, Just(Transition::Idle))
            .with_if_not_empty(1, state.client.inner().all_resource_ids(), |resources_id| {
                sample::subsequence(resources_id.clone(), resources_id.len()).prop_map(
                    |resources_id| Transition::DisableResources(BTreeSet::from_iter(resources_id)),
                )
            })
            .with_if_not_empty(
                10,
                state.client.inner().ipv4_cidr_resource_dsts(),
                |ip4_resources| {
                    icmp_to_cidr_resource(
                        packet_source_v4(state.client.inner().tunnel_ip4),
                        sample::select(ip4_resources).prop_flat_map(crate::proptest::host_v4),
                    )
                },
            )
            .with_if_not_empty(
                10,
                state.client.inner().ipv6_cidr_resource_dsts(),
                |ip6_resources| {
                    icmp_to_cidr_resource(
                        packet_source_v6(state.client.inner().tunnel_ip6),
                        sample::select(ip6_resources).prop_flat_map(crate::proptest::host_v6),
                    )
                },
            )
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
                5,
                (state.all_domains(), state.reachable_dns_servers()),
                |(domains, dns_servers)| {
                    dns_queries(sample::select(domains), sample::select(dns_servers))
                        .prop_map(Transition::SendDnsQueries)
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
            .boxed()
    }

    /// Apply the transition to our reference state.
    ///
    /// Here is where we implement the "expected" logic.
    fn apply(mut state: Self::State, transition: &Self::Transition) -> Self::State {
        match transition {
            Transition::ActivateResource(resource) => {
                state.client.exec_mut(|client| match resource {
                    client::ResourceDescription::Dns(r) => {
                        client.add_dns_resource(r.clone());

                        // TODO: PRODUCTION CODE CANNOT DO THIS.
                        // Remove all prior DNS records.
                        client.dns_records.retain(|domain, _| {
                            if is_subdomain(domain, &r.address) {
                                return false;
                            }

                            true
                        });
                    }
                    client::ResourceDescription::Cidr(r) => client.add_cidr_resource(r.clone()),
                    client::ResourceDescription::Internet(r) => {
                        client.add_internet_resource(r.clone())
                    }
                });
            }
            Transition::DeactivateResource(id) => {
                state.client.exec_mut(|client| {
                    client.remove_resource(id);
                });
            }
            Transition::DisableResources(resources) => state.client.exec_mut(|client| {
                client.disabled_resources.clone_from(resources);

                for id in resources {
                    client.disconnect_resource(id)
                }
            }),
            Transition::SendDnsQueries(queries) => {
                let mut new_connections_via_gateways = BTreeMap::new();

                for query in queries {
                    // Some queries get answered locally.
                    if state
                        .client
                        .inner()
                        .is_locally_answered_query(&query.domain)
                    {
                        tracing::debug!("Expecting locally answered query");

                        state.client.exec_mut(|client| client.on_dns_query(query));
                        continue;
                    }

                    // Check if the DNS server is defined as a resource.
                    let Some(resource) = state.client.inner().dns_query_via_resource(query) else {
                        // Not a resource, process normally.
                        state.client.exec_mut(|client| client.on_dns_query(query));
                        continue;
                    };

                    let Some(gateway) = state.portal.gateway_for_resource(resource).copied() else {
                        tracing::error!("Unknown gateway for resource");
                        continue;
                    };

                    tracing::debug!(%resource, %gateway, "Expecting DNS query via resource");

                    if !state
                        .client
                        .inner()
                        .is_connected_to_internet_or_cidr(resource)
                    {
                        // As part of batch-processing DNS queries, only the first resource per gateway will be connected / authorized.
                        match new_connections_via_gateways.entry(gateway) {
                            Entry::Vacant(v) => {
                                v.insert(resource);
                            }
                            Entry::Occupied(_) => {}
                        };

                        continue;
                    }

                    state.client.exec_mut(|client| client.on_dns_query(query));
                }

                for (_, resource) in new_connections_via_gateways {
                    state
                        .client
                        .exec_mut(|client| client.connect_to_internet_or_cidr_resource(resource));
                }
            }
            Transition::SendICMPPacketToNonResourceIp {
                src,
                dst,
                seq,
                identifier,
                payload,
            } => {
                state.client.exec_mut(|client| {
                    // If the Internet Resource is active, all packets are expected to be routed.
                    if client.active_internet_resource().is_some() {
                        client.on_icmp_packet_to_internet(
                            *src,
                            *dst,
                            *seq,
                            *identifier,
                            *payload,
                            |r| state.portal.gateway_for_resource(r).copied(),
                        )
                    }
                });
            }
            Transition::SendICMPPacketToCidrResource {
                src,
                dst,
                seq,
                identifier,
                payload,
            } => {
                state.client.exec_mut(|client| {
                    client.on_icmp_packet_to_cidr(*src, *dst, *seq, *identifier, *payload, |r| {
                        state.portal.gateway_for_resource(r).copied()
                    })
                });
            }
            Transition::SendICMPPacketToDnsResource {
                src,
                dst,
                seq,
                identifier,
                payload,
                ..
            } => state.client.exec_mut(|client| {
                client.on_icmp_packet_to_dns(*src, dst.clone(), *seq, *identifier, *payload, |r| {
                    state.portal.gateway_for_resource(r).copied()
                })
            }),
            Transition::UpdateSystemDnsServers(servers) => {
                state
                    .client
                    .exec_mut(|client| client.set_system_dns_resolvers(servers));
            }
            Transition::UpdateUpstreamDnsServers(servers) => {
                state
                    .client
                    .exec_mut(|client| client.set_upstream_dns_resolvers(servers));
            }
            Transition::RoamClient { ip4, ip6, .. } => {
                state.network.remove_host(&state.client);
                state.client.ip4.clone_from(ip4);
                state.client.ip6.clone_from(ip6);
                debug_assert!(state
                    .network
                    .add_host(state.client.inner().id, &state.client));

                // When roaming, we are not connected to any resource and wait for the next packet to re-establish a connection.
                state.client.exec_mut(|client| client.reset_connections());
            }
            Transition::ReconnectPortal => {
                // Reconnecting to the portal should have no noticeable impact on the data plane.
                // We do re-add all resources though so depending on the order they are added in, overlapping CIDR resources may change.
                state.client.exec_mut(|c| c.readd_all_resources());
            }
            Transition::DeployNewRelays(new_relays) => {
                // Always take down all relays because we can't know which one was sampled for the connection.
                for relay in state.relays.values() {
                    state.network.remove_host(relay);
                }
                state.relays.clear();

                for (rid, new_relay) in new_relays {
                    state.relays.insert(*rid, new_relay.clone());
                    debug_assert!(state.network.add_host(*rid, new_relay));
                }

                // In case we were using the relays, all connections will be cut and require us to make a new one.
                if state.drop_direct_client_traffic {
                    state.client.exec_mut(|client| client.reset_connections());
                }
            }
            Transition::Idle => {
                state.client.exec_mut(|client| client.reset_connections());
            }
            Transition::PartitionRelaysFromPortal => {
                if state.drop_direct_client_traffic {
                    state.client.exec_mut(|client| client.reset_connections());
                }
            }
        };

        state
    }

    /// Any additional checks on whether a particular [`Transition`] can be applied to a certain state.
    fn preconditions(state: &Self::State, transition: &Self::Transition) -> bool {
        match transition {
            Transition::ActivateResource(resource) => {
                // Don't add resource we already have.
                if state.client.inner().has_resource(resource.id()) {
                    return false;
                }

                true
            }
            Transition::DisableResources(resources) => {
                // Don't disabled resources we don't have.
                // It doesn't hurt but makes the logs of reduced testcases weird.
                resources
                    .iter()
                    .all(|r| state.client.inner().has_resource(*r))
            }
            Transition::SendICMPPacketToNonResourceIp {
                dst,
                seq,
                identifier,
                payload,
                ..
            } => {
                let is_valid_icmp_packet = state
                    .client
                    .inner()
                    .is_valid_icmp_packet(seq, identifier, payload);
                let is_cidr_resource = state.client.inner().cidr_resource_by_ip(*dst).is_some();

                is_valid_icmp_packet && !is_cidr_resource
            }
            Transition::SendICMPPacketToCidrResource {
                seq,
                identifier,
                dst,
                payload,
                ..
            } => {
                let ref_client = state.client.inner();
                let Some(rid) = ref_client.cidr_resource_by_ip(*dst) else {
                    return false;
                };
                let Some(gateway) = state.portal.gateway_for_resource(rid) else {
                    return false;
                };

                ref_client.is_valid_icmp_packet(seq, identifier, payload)
                    && state.gateways.contains_key(gateway)
            }
            Transition::SendICMPPacketToDnsResource {
                seq,
                identifier,
                dst,
                src,
                payload,
                ..
            } => {
                let ref_client = state.client.inner();
                let Some(resource) = ref_client.dns_resource_by_domain(dst) else {
                    return false;
                };
                let Some(gateway) = state.portal.gateway_for_resource(resource) else {
                    return false;
                };

                ref_client.is_valid_icmp_packet(seq, identifier, payload)
                    && ref_client.dns_records.get(dst).is_some_and(|r| match src {
                        IpAddr::V4(_) => r.contains(&Rtype::A),
                        IpAddr::V6(_) => r.contains(&Rtype::AAAA),
                    })
                    && state.gateways.contains_key(gateway)
            }
            Transition::UpdateSystemDnsServers(servers) => {
                if servers.is_empty() {
                    return true; // Clearing is allowed.
                }

                servers
                    .iter()
                    .any(|dns_server| state.client.sending_socket_for(*dns_server).is_some())
            }
            Transition::UpdateUpstreamDnsServers(servers) => {
                if servers.is_empty() {
                    return true; // Clearing is allowed.
                }

                servers
                    .iter()
                    .any(|dns_server| state.client.sending_socket_for(dns_server.ip()).is_some())
            }
            Transition::SendDnsQueries(queries) => queries.iter().all(|query| {
                let has_socket_for_server = state
                    .client
                    .sending_socket_for(query.dns_server.ip())
                    .is_some();
                let is_known_domain = state.global_dns_records.contains_key(&query.domain);
                let has_dns_server = state
                    .client
                    .inner()
                    .expected_dns_servers()
                    .contains(&query.dns_server);
                let gateway_is_present_in_case_dns_server_is_cidr_resource =
                    match state.client.inner().dns_query_via_resource(query) {
                        Some(r) => {
                            let Some(gateway) = state.portal.gateway_for_resource(r) else {
                                return false;
                            };

                            state.gateways.contains_key(gateway)
                        }
                        None => true,
                    };

                has_socket_for_server
                    && is_known_domain
                    && has_dns_server
                    && gateway_is_present_in_case_dns_server_is_cidr_resource
            }),
            Transition::RoamClient { ip4, ip6, port } => {
                // In production, we always rebind to a new port so we never roam to our old existing IP / port combination.

                let is_assigned_ip4 = ip4.is_some_and(|ip| state.network.contains(ip));
                let is_assigned_ip6 = ip6.is_some_and(|ip| state.network.contains(ip));
                let is_previous_port = state.client.old_ports.contains(port);

                !is_assigned_ip4 && !is_assigned_ip6 && !is_previous_port
            }
            Transition::ReconnectPortal => true,
            Transition::DeactivateResource(r) => {
                state.client.inner().all_resource_ids().contains(r)
            }
            Transition::DeployNewRelays(new_relays) => {
                let mut additional_routes = RoutingTable::default();
                for (rid, relay) in new_relays {
                    if !additional_routes.add_host(*rid, relay) {
                        return false;
                    }
                }

                let route_overlap = state.network.overlaps_with(&additional_routes);

                !route_overlap
            }
            Transition::Idle => true,
            Transition::PartitionRelaysFromPortal => true,
        }
    }
}

/// Several helper functions to make the reference state more readable.
impl ReferenceState {
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

    fn reachable_dns_servers(&self) -> Vec<SocketAddr> {
        self.client
            .inner()
            .expected_dns_servers()
            .into_iter()
            .filter(|s| match s {
                SocketAddr::V4(_) => self.client.ip4.is_some(),
                SocketAddr::V6(_) => self.client.ip6.is_some(),
            })
            .collect()
    }

    fn all_resources_not_known_to_client(&self) -> Vec<ResourceDescription> {
        let mut all_resources = self.portal.all_resources();
        all_resources.retain(|r| !self.client.inner().has_resource(r.id()));

        all_resources
    }
}

pub(crate) fn private_key() -> impl Strategy<Value = PrivateKey> {
    any::<[u8; 32]>().prop_map(PrivateKey)
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct PrivateKey(pub [u8; 32]);

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
