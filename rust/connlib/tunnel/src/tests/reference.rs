use super::dns_records::DnsRecords;
use super::unreachable_hosts::{unreachable_hosts, UnreachableHosts};
use super::{
    composite_strategy::CompositeStrategy, sim_client::*, sim_gateway::*, sim_net::*,
    strategies::*, stub_portal::StubPortal, transition::*,
};
use crate::{client, DomainName};
use crate::{dns::is_subdomain, proptest::relay_id};
use connlib_model::{GatewayId, RelayId, StaticSecret};
use domain::base::Rtype;
use ip_network::{Ipv4Network, Ipv6Network};
use prop::sample::select;
use proptest::{prelude::*, sample};
use std::net::{Ipv4Addr, Ipv6Addr};
use std::{
    collections::{BTreeMap, BTreeSet, HashSet},
    fmt, iter,
    net::{IpAddr, SocketAddr},
};

/// The reference state machine of the tunnel.
///
/// This is the "expected" part of our test.
#[derive(Clone, Debug)]
pub(crate) struct ReferenceState {
    pub(crate) client: Host<RefClient>,
    pub(crate) gateways: BTreeMap<GatewayId, Host<RefGateway>>,
    pub(crate) relays: BTreeMap<RelayId, Host<u64>>,

    pub(crate) portal: StubPortal,

    pub(crate) drop_direct_client_traffic: bool,

    /// All IP addresses a domain resolves to in our test.
    ///
    /// This is used to e.g. mock DNS resolution on the gateway.
    pub(crate) global_dns_records: DnsRecords,

    /// A subset of all DNS resource records that have been selected to produce an ICMP error.
    pub(crate) unreachable_hosts: UnreachableHosts,

    pub(crate) network: RoutingTable,
}

/// Implementation of our reference state machine.
///
/// The logic in here represents what we expect the [`ClientState`] & [`GatewayState`] to do.
/// Care has to be taken that we don't implement things in a buggy way here.
/// After all, if your test has bugs, it won't catch any in the actual implementation.
impl ReferenceState {
    pub(crate) fn initial_state() -> BoxedStrategy<Self> {
        stub_portal()
            .prop_flat_map(|portal| {
                let gateways = portal.gateways();
                let dns_resource_records = portal.dns_resource_records();
                let client = portal.client(system_dns_servers(), upstream_dns_servers());
                let relays = relays(relay_id());
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
                )
            })
            .prop_flat_map(
                |(
                    client,
                    gateways,
                    portal,
                    records,
                    relays,
                    global_dns,
                    drop_direct_client_traffic,
                )| {
                    (
                        Just(client),
                        Just(gateways),
                        Just(portal),
                        Just(records.clone()),
                        unreachable_hosts(records),
                        Just(relays),
                        Just(global_dns),
                        Just(drop_direct_client_traffic),
                    )
                },
            )
            .prop_filter_map(
                "network IPs must be unique",
                |(
                    c,
                    gateways,
                    portal,
                    records,
                    unreachable_hosts,
                    relays,
                    mut global_dns,
                    drop_direct_client_traffic,
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

                    // Merge all DNS records into `global_dns`.
                    global_dns.merge(records);

                    Some((
                        c,
                        gateways,
                        relays,
                        portal,
                        global_dns,
                        unreachable_hosts,
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
                    portal,
                    global_dns_records,
                    unreachable_hosts,
                    drop_direct_client_traffic,
                    network,
                )| {
                    Self {
                        client,
                        gateways,
                        relays,
                        portal,
                        global_dns_records,
                        unreachable_hosts,
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
    pub(crate) fn transitions(state: &Self) -> BoxedStrategy<Transition> {
        CompositeStrategy::default()
            .with(
                1,
                system_dns_servers().prop_map(Transition::UpdateSystemDnsServers),
            )
            .with(
                1,
                upstream_dns_servers().prop_map(Transition::UpdateUpstreamDnsServers),
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
            .with(1, relays(relay_id()).prop_map(Transition::DeployNewRelays))
            .with(1, Just(Transition::PartitionRelaysFromPortal))
            .with(
                1,
                relays(sample::select(
                    state.relays.keys().copied().collect::<Vec<_>>(),
                ))
                .prop_map(Transition::RebootRelaysWhilePartitioned),
            )
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
                    let tunnel_ip4 = state.client.inner().tunnel_ip4;

                    prop_oneof![
                        icmp_packet(packet_source_v4(tunnel_ip4), select_host_v4(&ip4_resources)),
                        udp_packet(packet_source_v4(tunnel_ip4), select_host_v4(&ip4_resources)),
                        tcp_packet(packet_source_v4(tunnel_ip4), select_host_v4(&ip4_resources)),
                    ]
                },
            )
            .with_if_not_empty(
                10,
                state.client.inner().ipv6_cidr_resource_dsts(),
                |ip6_resources| {
                    let tunnel_ip6 = state.client.inner().tunnel_ip6;

                    prop_oneof![
                        icmp_packet(packet_source_v6(tunnel_ip6), select_host_v6(&ip6_resources)),
                        udp_packet(packet_source_v6(tunnel_ip6), select_host_v6(&ip6_resources)),
                        tcp_packet(packet_source_v6(tunnel_ip6), select_host_v6(&ip6_resources)),
                    ]
                },
            )
            .with_if_not_empty(
                10,
                state.client.inner().resolved_v4_domains(),
                |dns_v4_domains| {
                    let tunnel_ip4 = state.client.inner().tunnel_ip4;

                    prop_oneof![
                        icmp_packet(packet_source_v4(tunnel_ip4), select(dns_v4_domains.clone())),
                        udp_packet(packet_source_v4(tunnel_ip4), select(dns_v4_domains.clone())),
                        tcp_packet(packet_source_v4(tunnel_ip4), select(dns_v4_domains)),
                    ]
                },
            )
            .with_if_not_empty(
                10,
                state.client.inner().resolved_v6_domains(),
                |dns_v6_domains| {
                    let tunnel_ip6 = state.client.inner().tunnel_ip6;

                    prop_oneof![
                        icmp_packet(packet_source_v6(tunnel_ip6), select(dns_v6_domains.clone()),),
                        udp_packet(packet_source_v6(tunnel_ip6), select(dns_v6_domains.clone()),),
                        tcp_packet(packet_source_v6(tunnel_ip6), select(dns_v6_domains),),
                    ]
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
                    let tunnel_ip4 = state.client.inner().tunnel_ip4;

                    prop_oneof![
                        icmp_packet(
                            packet_source_v4(tunnel_ip4),
                            select(resolved_non_resource_ip4s.clone()),
                        ),
                        udp_packet(
                            packet_source_v4(tunnel_ip4),
                            select(resolved_non_resource_ip4s.clone()),
                        ),
                        tcp_packet(
                            packet_source_v4(tunnel_ip4),
                            select(resolved_non_resource_ip4s),
                        ),
                    ]
                },
            )
            .with_if_not_empty(
                1,
                state
                    .client
                    .inner()
                    .resolved_ip6_for_non_resources(&state.global_dns_records),
                |resolved_non_resource_ip6s| {
                    let tunnel_ip6 = state.client.inner().tunnel_ip6;

                    prop_oneof![
                        icmp_packet(
                            packet_source_v6(tunnel_ip6),
                            select(resolved_non_resource_ip6s.clone()),
                        ),
                        udp_packet(
                            packet_source_v6(tunnel_ip6),
                            select(resolved_non_resource_ip6s.clone()),
                        ),
                        tcp_packet(
                            packet_source_v6(tunnel_ip6),
                            select(resolved_non_resource_ip6s),
                        ),
                    ]
                },
            )
            .boxed()
    }

    /// Apply the transition to our reference state.
    ///
    /// Here is where we implement the "expected" logic.
    pub(crate) fn apply(mut state: Self, transition: &Transition) -> Self {
        match transition {
            Transition::ActivateResource(resource) => {
                state.client.exec_mut(|client| match resource {
                    client::Resource::Dns(r) => {
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
                    client::Resource::Cidr(r) => client.add_cidr_resource(r.clone()),
                    client::Resource::Internet(r) => client.add_internet_resource(r.clone()),
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
                for query in queries {
                    state.client.exec_mut(|client| client.on_dns_query(query));
                }
            }
            Transition::SendIcmpPacket {
                src,
                dst,
                seq,
                identifier,
                payload,
            } => {
                state.client.exec_mut(|client| {
                    client.on_icmp_packet(*src, dst.clone(), *seq, *identifier, *payload, |r| {
                        state.portal.gateway_for_resource(r).copied()
                    })
                });
            }
            Transition::SendUdpPacket {
                src,
                dst,
                sport,
                dport,
                payload,
            } => {
                state.client.exec_mut(|client| {
                    client.on_udp_packet(*src, dst.clone(), *sport, *dport, *payload, |r| {
                        state.portal.gateway_for_resource(r).copied()
                    })
                });
            }
            Transition::SendTcpPayload {
                src,
                dst,
                sport,
                dport,
                payload,
            } => {
                state.client.exec_mut(|client| {
                    client.on_tcp_packet(*src, dst.clone(), *sport, *dport, *payload, |r| {
                        state.portal.gateway_for_resource(r).copied()
                    })
                });
            }
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
                state.client.exec_mut(|client| {
                    client.reset_connections();
                    client.readd_all_resources()
                });
            }
            Transition::ReconnectPortal => {
                // Reconnecting to the portal should have no noticeable impact on the data plane.
                // We do re-add all resources though so depending on the order they are added in, overlapping CIDR resources may change.
                state.client.exec_mut(|c| c.readd_all_resources());
            }
            Transition::DeployNewRelays(new_relays) => state.deploy_new_relays(new_relays),
            Transition::RebootRelaysWhilePartitioned(new_relays) => {
                state.deploy_new_relays(new_relays)
            }
            Transition::Idle => {}
            Transition::PartitionRelaysFromPortal => {
                if state.drop_direct_client_traffic {
                    state.client.exec_mut(|client| client.reset_connections());
                }
            }
        };

        state
    }

    /// Any additional checks on whether a particular [`Transition`] can be applied to a certain state.
    pub(crate) fn is_valid_transition(state: &Self, transition: &Transition) -> bool {
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
            Transition::SendIcmpPacket {
                src,
                dst: Destination::DomainName { name, .. },
                seq,
                identifier,
                payload,
            } => {
                let ref_client = state.client.inner();

                ref_client.is_valid_icmp_packet(seq, identifier, payload)
                    && state.is_valid_dst_domain(name, src)
            }
            Transition::SendUdpPacket {
                src,
                dst: Destination::DomainName { name, .. },
                sport,
                dport,
                payload,
            } => {
                let ref_client = state.client.inner();

                ref_client.is_valid_udp_packet(sport, dport, payload)
                    && state.is_valid_dst_domain(name, src)
            }
            Transition::SendTcpPayload {
                src,
                dst: Destination::DomainName { name, .. },
                sport,
                dport,
                payload,
            } => {
                let ref_client = state.client.inner();

                ref_client.is_valid_tcp_packet(sport, dport, payload)
                    && state.is_valid_dst_domain(name, src)
            }
            Transition::SendIcmpPacket {
                dst: Destination::IpAddr(dst),
                seq,
                identifier,
                payload,
                ..
            } => {
                let ref_client = state.client.inner();

                ref_client.is_valid_icmp_packet(seq, identifier, payload)
                    && state.is_valid_dst_ip(*dst)
            }
            Transition::SendUdpPacket {
                dst: Destination::IpAddr(dst),
                sport,
                dport,
                payload,
                ..
            } => {
                let ref_client = state.client.inner();

                ref_client.is_valid_udp_packet(sport, dport, payload) && state.is_valid_dst_ip(*dst)
            }
            Transition::SendTcpPayload {
                dst: Destination::IpAddr(dst),
                sport,
                dport,
                payload,
                ..
            } => {
                let ref_client = state.client.inner();

                ref_client.is_valid_tcp_packet(sport, dport, payload) && state.is_valid_dst_ip(*dst)
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

                let is_ptr_query = matches!(query.r_type, Rtype::PTR);
                let is_known_domain = state.global_dns_records.contains_domain(&query.domain);
                // In case we sampled a PTR query, the domain doesn't have to exist.
                let ptr_or_known_domain = is_ptr_query || is_known_domain;

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
                    && ptr_or_known_domain
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
            Transition::RebootRelaysWhilePartitioned(new_relays)
            | Transition::DeployNewRelays(new_relays) => {
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

    fn is_valid_dst_ip(&self, dst: IpAddr) -> bool {
        let Some(rid) = self.client.inner().cidr_resource_by_ip(dst) else {
            // As long as the packet is valid it's always valid to send to a non-resource
            return true;
        };
        let Some(gateway) = self.portal.gateway_for_resource(rid) else {
            return false;
        };

        self.gateways.contains_key(gateway)
    }

    fn is_valid_dst_domain(&self, name: &DomainName, src: &IpAddr) -> bool {
        let Some(resource) = self.client.inner().dns_resource_by_domain(name) else {
            return false;
        };
        let Some(gateway) = self.portal.gateway_for_resource(resource) else {
            return false;
        };

        self.client
            .inner()
            .dns_records
            .get(name)
            .is_some_and(|r| match src {
                IpAddr::V4(_) => r.contains(&Rtype::A),
                IpAddr::V6(_) => r.contains(&Rtype::AAAA),
            })
            && self.gateways.contains_key(gateway)
    }
}

/// Several helper functions to make the reference state more readable.
impl ReferenceState {
    // We surface what are the existing rtypes for a domain so that it's easier
    // for the proptests to hit an existing record.
    fn all_domains(&self) -> Vec<(DomainName, Vec<Rtype>)> {
        self.global_dns_records
            .domains_iter()
            .map(|d| (d.clone(), self.global_dns_records.domain_rtypes(&d)))
            .chain(self.client.inner().known_hosts.keys().map(|h| {
                (
                    DomainName::vec_from_str(h).unwrap(),
                    vec![Rtype::A, Rtype::AAAA],
                )
            }))
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

    fn all_resources_not_known_to_client(&self) -> Vec<client::Resource> {
        let mut all_resources = self.portal.all_resources();
        all_resources.retain(|r| !self.client.inner().has_resource(r.id()));

        all_resources
    }

    fn deploy_new_relays(&mut self, new_relays: &BTreeMap<RelayId, Host<u64>>) {
        // Always take down all relays because we can't know which one was sampled for the connection.
        for relay in self.relays.values() {
            self.network.remove_host(relay);
        }
        self.relays.clear();

        for (rid, new_relay) in new_relays {
            self.relays.insert(*rid, new_relay.clone());
            debug_assert!(self.network.add_host(*rid, new_relay));
        }

        // In case we were using the relays, all connections will be cut and require us to make a new one.
        if self.drop_direct_client_traffic {
            self.client.exec_mut(|client| client.reset_connections());
        }
    }
}

fn select_host_v4(hosts: &[Ipv4Network]) -> impl Strategy<Value = Ipv4Addr> {
    sample::select(hosts.to_vec()).prop_flat_map(crate::proptest::host_v4)
}

fn select_host_v6(hosts: &[Ipv6Network]) -> impl Strategy<Value = Ipv6Addr> {
    sample::select(hosts.to_vec()).prop_flat_map(crate::proptest::host_v6)
}

pub(crate) fn private_key() -> impl Strategy<Value = PrivateKey> {
    any::<[u8; 32]>().prop_map(PrivateKey).no_shrink()
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
