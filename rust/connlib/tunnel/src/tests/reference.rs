use super::dns_records::DnsRecords;
use super::icmp_error_hosts::{IcmpErrorHosts, icmp_error_hosts};
use super::{
    composite_strategy::CompositeStrategy, sim_client::*, sim_gateway::*, sim_net::*,
    strategies::*, stub_portal::StubPortal, transition::*,
};
use crate::proptest::domain_label;
use crate::{client, dns};
use crate::{dns::is_subdomain, proptest::relay_id};
use connlib_model::{GatewayId, RelayId, Site, StaticSecret};
use dns_types::{DomainName, RecordType};
use ip_network::{Ipv4Network, Ipv6Network};
use itertools::Itertools;
use prop::sample::select;
use proptest::collection::btree_set;
use proptest::{prelude::*, sample};
use std::net::{Ipv4Addr, Ipv6Addr};
use std::time::Instant;
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

    /// DNS Resources that listen for TCP connections.
    pub(crate) tcp_resources: BTreeMap<DomainName, BTreeSet<SocketAddr>>,

    /// A subset of all DNS resource records that have been selected to produce an ICMP error.
    pub(crate) icmp_error_hosts: IcmpErrorHosts,

    pub(crate) network: RoutingTable,
}

/// Implementation of our reference state machine.
///
/// The logic in here represents what we expect the [`ClientState`] & [`GatewayState`] to do.
/// Care has to be taken that we don't implement things in a buggy way here.
/// After all, if your test has bugs, it won't catch any in the actual implementation.
impl ReferenceState {
    pub(crate) fn initial_state(start: Instant) -> BoxedStrategy<Self> {
        stub_portal()
            .prop_flat_map(move |portal| {
                let gateways = portal.gateways(start);
                let dns_resource_records = portal.dns_resource_records(start);
                let client = portal.client(
                    system_dns_servers(),
                    upstream_do53_servers(),
                    upstream_doh_servers(),
                );
                let relays = relays(relay_id());
                let global_dns_records = global_dns_records(start); // Start out with a set of global DNS records so we have something to resolve outside of DNS resources.
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
                move |(
                    client,
                    gateways,
                    portal,
                    dns_resource_records,
                    relays,
                    global_dns,
                    drop_direct_client_traffic,
                )| {
                    (
                        Just(client),
                        Just(gateways),
                        Just(portal),
                        Just(dns_resource_records.clone()),
                        icmp_error_hosts(dns_resource_records, start),
                        Just(relays),
                        Just(global_dns),
                        Just(drop_direct_client_traffic),
                    )
                },
            )
            .prop_flat_map(
                move |(
                    client,
                    gateways,
                    portal,
                    dns_resource_records,
                    icmp_error_hosts,
                    relays,
                    global_dns,
                    drop_direct_client_traffic,
                )| {
                    (
                        Just(client),
                        Just(gateways),
                        Just(portal),
                        Just(dns_resource_records.clone()),
                        Just(icmp_error_hosts.clone()),
                        tcp_resources(dns_resource_records, icmp_error_hosts, start),
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
                    icmp_error_hosts,
                    tcp_resources,
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
                        tcp_resources,
                        icmp_error_hosts,
                        drop_direct_client_traffic,
                        routing_table,
                    ))
                },
            )
            .prop_filter(
                "private keys must be unique",
                |(c, gateways, _, _, _, _, _, _, _)| {
                    let different_keys = gateways
                        .values()
                        .map(|g| g.inner().key)
                        .chain(iter::once(c.inner().key))
                        .collect::<HashSet<_>>();

                    different_keys.len() == gateways.len() + 1
                },
            )
            .prop_map(
                move |(
                    client,
                    gateways,
                    relays,
                    portal,
                    global_dns_records,
                    tcp_resources,
                    icmp_error_hosts,
                    drop_direct_client_traffic,
                    network,
                )| {
                    Self {
                        client,
                        gateways,
                        relays,
                        portal,
                        global_dns_records,
                        icmp_error_hosts,
                        network,
                        drop_direct_client_traffic,
                        tcp_resources,
                    }
                },
            )
            .boxed()
    }

    /// Defines the [`Strategy`] on how we can [transition](Transition) from the current [`ReferenceState`].
    ///
    /// This is invoked by proptest repeatedly to explore further state transitions.
    /// Here, we should only generate [`Transition`]s that make sense for the current state.
    pub(crate) fn transitions(state: &Self, now: Instant) -> BoxedStrategy<Transition> {
        CompositeStrategy::default()
            .with(
                1,
                system_dns_servers().prop_map(Transition::UpdateSystemDnsServers),
            )
            .with(
                1,
                upstream_do53_servers().prop_map(Transition::UpdateUpstreamDo53Servers),
            )
            .with(
                1,
                upstream_doh_servers().prop_map(Transition::UpdateUpstreamDoHServers),
            )
            .with(
                1,
                state
                    .portal
                    .search_domain()
                    .prop_map(Transition::UpdateUpstreamSearchDomain),
            )
            .with_if_not_empty(
                5,
                state.all_resources_not_known_to_client(),
                |resource_ids| sample::select(resource_ids).prop_map(Transition::AddResource),
            )
            .with_if_not_empty(1, state.cidr_resources_on_client(), |resources| {
                (sample::select(resources), cidr_resource_address()).prop_map(
                    |(resource, new_address)| Transition::ChangeCidrResourceAddress {
                        resource,
                        new_address,
                    },
                )
            })
            .with_if_not_empty(
                1,
                (
                    state.cidr_and_dns_resources_on_client(),
                    state.regular_sites(),
                ),
                |(resources, sites)| {
                    (sample::select(resources), sample::select(sites)).prop_map(
                        |(resource, new_site)| Transition::MoveResourceToNewSite {
                            resource,
                            new_site,
                        },
                    )
                },
            )
            .with_if_not_empty(1, state.client.inner().all_resource_ids(), |resource_ids| {
                sample::select(resource_ids).prop_map(Transition::RemoveResource)
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
            .with(1, private_key().prop_map(Transition::RestartClient))
            .with(
                1,
                any::<bool>().prop_map(Transition::SetInternetResourceState),
            )
            .with_if_not_empty(1, state.client.inner().all_resource_ids(), |resources_id| {
                sample::select(resources_id)
                    .prop_map(Transition::DeauthorizeWhileGatewayIsPartitioned)
            })
            .with_if_not_empty(
                10,
                state.client.inner().ipv4_cidr_resource_dsts(),
                |ip4_resources| {
                    let tunnel_ip4 = state.client.inner().tunnel_ip4;

                    prop_oneof![
                        icmp_packet(Just(tunnel_ip4), select_host_v4(&ip4_resources)),
                        udp_packet(Just(tunnel_ip4), select_host_v4(&ip4_resources)),
                    ]
                },
            )
            .with_if_not_empty(
                10,
                state.client.inner().ipv6_cidr_resource_dsts(),
                |ip6_resources| {
                    let tunnel_ip6 = state.client.inner().tunnel_ip6;

                    prop_oneof![
                        icmp_packet(Just(tunnel_ip6), select_host_v6(&ip6_resources)),
                        udp_packet(Just(tunnel_ip6), select_host_v6(&ip6_resources)),
                    ]
                },
            )
            .with_if_not_empty(
                10,
                state.client.inner().resolved_v4_domains(),
                |dns_v4_domains| {
                    let tunnel_ip4 = state.client.inner().tunnel_ip4;

                    prop_oneof![
                        icmp_packet(Just(tunnel_ip4), select(dns_v4_domains.clone())),
                        udp_packet(Just(tunnel_ip4), select(dns_v4_domains)),
                    ]
                },
            )
            .with_if_not_empty(
                10,
                state.client.inner().resolved_v6_domains(),
                |dns_v6_domains| {
                    let tunnel_ip6 = state.client.inner().tunnel_ip6;

                    prop_oneof![
                        icmp_packet(Just(tunnel_ip6), select(dns_v6_domains.clone()),),
                        udp_packet(Just(tunnel_ip6), select(dns_v6_domains),),
                    ]
                },
            )
            .with_if_not_empty(
                10,
                state.resolved_v4_domains_with_tcp_resources(),
                |dns_v4_domains| {
                    let tunnel_ip4 = state.client.inner().tunnel_ip4;

                    connect_tcp(Just(tunnel_ip4), select(dns_v4_domains))
                },
            )
            .with_if_not_empty(
                10,
                state.resolved_v6_domains_with_tcp_resources(),
                |dns_v6_domains| {
                    let tunnel_ip6 = state.client.inner().tunnel_ip6;

                    connect_tcp(Just(tunnel_ip6), select(dns_v6_domains))
                },
            )
            .with_if_not_empty(
                10,
                state.resolved_v4_domains_with_icmp_errors(now),
                |dns_v4_domains| {
                    let tunnel_ip4 = state.client.inner().tunnel_ip4;

                    prop_oneof![
                        icmp_packet(Just(tunnel_ip4), select(dns_v4_domains.clone())),
                        udp_packet(Just(tunnel_ip4), select(dns_v4_domains)),
                    ]
                },
            )
            .with_if_not_empty(
                10,
                state.resolved_v6_domains_with_icmp_errors(now),
                |dns_v6_domains| {
                    let tunnel_ip6 = state.client.inner().tunnel_ip6;

                    prop_oneof![
                        icmp_packet(Just(tunnel_ip6), select(dns_v6_domains.clone()),),
                        udp_packet(Just(tunnel_ip6), select(dns_v6_domains),),
                    ]
                },
            )
            .with_if_not_empty(
                5,
                (state.all_domains(now), state.reachable_dns_servers()),
                |(domains, dns_servers)| {
                    dns_queries(sample::select(domains), sample::select(dns_servers))
                        .prop_map(Transition::SendDnsQueries)
                },
            )
            .with_if_not_empty(
                2,
                (
                    state.wildcard_dns_resources_on_client(),
                    state.reachable_dns_servers(),
                ),
                |(wildcard_dns_resources, dns_servers)| {
                    dns_queries(
                        (
                            sample::select(wildcard_dns_resources).prop_flat_map(|r| {
                                let base = r.address.trim_start_matches("*.").to_owned();

                                domain_label().prop_map(move |label| {
                                    format!("{label}.{base}").parse().unwrap()
                                })
                            }),
                            prop_oneof![
                                Just(vec![RecordType::A]),
                                Just(vec![RecordType::AAAA]),
                                Just(vec![RecordType::A, RecordType::AAAA])
                            ],
                        ),
                        sample::select(dns_servers),
                    )
                    .prop_map(Transition::SendDnsQueries)
                },
            )
            .with_if_not_empty(
                1,
                state
                    .client
                    .inner()
                    .resolved_ip4_for_non_resources(&state.global_dns_records, now),
                |resolved_non_resource_ip4s| {
                    let tunnel_ip4 = state.client.inner().tunnel_ip4;

                    prop_oneof![
                        icmp_packet(Just(tunnel_ip4), select(resolved_non_resource_ip4s.clone()),),
                        udp_packet(Just(tunnel_ip4), select(resolved_non_resource_ip4s),),
                    ]
                },
            )
            .with_if_not_empty(
                1,
                state
                    .client
                    .inner()
                    .resolved_ip6_for_non_resources(&state.global_dns_records, now),
                |resolved_non_resource_ip6s| {
                    let tunnel_ip6 = state.client.inner().tunnel_ip6;

                    prop_oneof![
                        icmp_packet(Just(tunnel_ip6), select(resolved_non_resource_ip6s.clone()),),
                        udp_packet(Just(tunnel_ip6), select(resolved_non_resource_ip6s),),
                    ]
                },
            )
            .with_if_not_empty(1, state.connected_gateway_ipv4_ips(), |gateway_ips| {
                let tunnel_ip4 = state.client.inner().tunnel_ip4;

                prop_oneof![
                    icmp_packet(Just(tunnel_ip4), select_host_v4(&gateway_ips)),
                    udp_packet(Just(tunnel_ip4), select_host_v4(&gateway_ips)),
                ]
            })
            .with_if_not_empty(1, state.connected_gateway_ipv6_ips(), |gateway_ips| {
                let tunnel_ip6 = state.client.inner().tunnel_ip6;

                prop_oneof![
                    icmp_packet(Just(tunnel_ip6), select_host_v6(&gateway_ips)),
                    udp_packet(Just(tunnel_ip6), select_host_v6(&gateway_ips)),
                ]
            })
            .with_if_not_empty(5, state.dns_resource_domains(), |domains| {
                (sample::select(domains), btree_set(dns_record(), 1..6))
                    .prop_map(|(domain, records)| Transition::UpdateDnsRecords { domain, records })
            })
            .boxed()
    }

    /// Apply the transition to our reference state.
    ///
    /// Here is where we implement the "expected" logic.
    pub(crate) fn apply(mut state: Self, transition: &Transition, now: Instant) -> Self {
        match transition {
            Transition::AddResource(resource) => {
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
            Transition::RemoveResource(id) => {
                state.client.exec_mut(|client| {
                    client.remove_resource(id);
                });
            }
            Transition::ChangeCidrResourceAddress {
                resource,
                new_address,
            } => {
                state
                    .portal
                    .change_address_of_cidr_resource(resource.id, *new_address);

                let new_resource = client::CidrResource {
                    address: *new_address,
                    ..resource.clone()
                };

                state.client.exec_mut(|c| c.add_cidr_resource(new_resource));
            }
            Transition::MoveResourceToNewSite { resource, new_site } => {
                state
                    .portal
                    .move_resource_to_new_site(resource.id(), new_site.clone());

                state
                    .client
                    .exec_mut(|c| match resource.clone().with_new_site(new_site.clone()) {
                        client::Resource::Dns(r) => c.add_dns_resource(r),
                        client::Resource::Cidr(r) => c.add_cidr_resource(r),
                        client::Resource::Internet(_) => {
                            tracing::error!("Internet Resource cannot move site");
                        }
                    })
            }
            Transition::SetInternetResourceState(active) => state.client.exec_mut(|client| {
                client.set_internet_resource_state(*active);
            }),
            Transition::SendDnsQueries(queries) => {
                for query in queries {
                    state.client.exec_mut(|client| {
                        client.on_dns_query(query);
                    });
                }
            }
            Transition::SendIcmpPacket {
                dst,
                seq,
                identifier,
                payload,
                ..
            } => state.client.exec_mut(|client| {
                client.on_icmp_packet(
                    dst.clone(),
                    *seq,
                    *identifier,
                    *payload,
                    |r| state.portal.gateway_for_resource(r).copied(),
                    |ip| state.portal.gateway_by_ip(ip),
                )
            }),
            Transition::SendUdpPacket {
                dst,
                sport,
                dport,
                payload,
                ..
            } => {
                state.client.exec_mut(|client| {
                    client.on_udp_packet(
                        dst.clone(),
                        *sport,
                        *dport,
                        *payload,
                        |r| state.portal.gateway_for_resource(r).copied(),
                        |ip| state.portal.gateway_by_ip(ip),
                    )
                });
            }
            Transition::ConnectTcp {
                src,
                dst,
                sport,
                dport,
            } => state.client.exec_mut(|client| {
                client.on_connect_tcp(*src, dst.clone(), *sport, *dport);
            }),
            Transition::UpdateSystemDnsServers(servers) => {
                state
                    .client
                    .exec_mut(|client| client.set_system_dns_resolvers(servers));
            }
            Transition::UpdateUpstreamDo53Servers(servers) => {
                state
                    .client
                    .exec_mut(|client| client.set_upstream_do53_resolvers(servers));
            }
            Transition::UpdateUpstreamDoHServers(servers) => {
                state
                    .client
                    .exec_mut(|client| client.set_upstream_doh_resolvers(servers));
            }
            Transition::UpdateUpstreamSearchDomain(domain) => {
                state
                    .client
                    .exec_mut(|client| client.set_upstream_search_domain(domain.as_ref()));
            }
            Transition::RoamClient { ip4, ip6, .. } => {
                state.network.remove_host(&state.client);
                state.client.ip4.clone_from(ip4);
                state.client.ip6.clone_from(ip6);
                debug_assert!(
                    state
                        .network
                        .add_host(state.client.inner().id, &state.client)
                );

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
            Transition::DeauthorizeWhileGatewayIsPartitioned(resource) => state
                .client
                .exec_mut(|client| client.remove_resource(resource)),
            Transition::RestartClient(key) => state.client.exec_mut(|c| {
                c.restart(*key);
            }),
            Transition::UpdateDnsRecords { domain, records } => {
                state.global_dns_records.merge(DnsRecords::from([(
                    domain.clone(),
                    BTreeMap::from([(now, records.clone())]),
                )]));
            }
        };

        state
    }

    /// Any additional checks on whether a particular [`Transition`] can be applied to a certain state.
    pub(crate) fn is_valid_transition(state: &Self, transition: &Transition) -> bool {
        match transition {
            Transition::AddResource(resource) => {
                // Don't add resource we already have.
                if state.client.inner().has_resource(resource.id()) {
                    return false;
                }

                true
            }
            Transition::ChangeCidrResourceAddress {
                resource,
                new_address,
            } => resource.address != *new_address && state.client.inner().has_resource(resource.id),
            Transition::MoveResourceToNewSite { resource, new_site } => {
                resource.sites() != BTreeSet::from([new_site])
                    && state.client.inner().has_resource(resource.id())
            }
            Transition::SetInternetResourceState(_) => true,
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
            Transition::ConnectTcp {
                src,
                dst: dst @ Destination::DomainName { name, .. },
                sport,
                dport,
            } => {
                let ref_client = state.client.inner();

                state.is_valid_dst_domain(name, src)
                    && !ref_client.has_tcp_connection(*src, dst.clone(), *sport, *dport)
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
            Transition::ConnectTcp {
                src,
                dst: dst @ Destination::IpAddr(dst_ip),
                sport,
                dport,
                ..
            } => {
                let ref_client = state.client.inner();

                state.is_valid_dst_ip(*dst_ip)
                    && !ref_client.has_tcp_connection(*src, dst.clone(), *sport, *dport)
            }
            Transition::UpdateSystemDnsServers(servers) => {
                if servers.is_empty() {
                    return true; // Clearing is allowed.
                }

                servers
                    .iter()
                    .any(|dns_server| state.client.sending_socket_for(*dns_server).is_some())
            }
            Transition::UpdateUpstreamDo53Servers(servers) => {
                if servers.is_empty() {
                    return true; // Clearing is allowed.
                }

                servers
                    .iter()
                    .any(|dns_server| state.client.sending_socket_for(dns_server.ip).is_some())
            }
            Transition::UpdateUpstreamDoHServers(_) => true,
            Transition::UpdateUpstreamSearchDomain(_) => true,
            Transition::SendDnsQueries(queries) => queries.iter().all(|query| {
                let has_socket_for_server = match query.dns_server {
                    crate::dns::Upstream::Do53 { server } => {
                        state.client.sending_socket_for(server.ip()).is_some()
                    }
                    crate::dns::Upstream::DoH { .. } => true,
                };

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
                    && has_dns_server
                    && gateway_is_present_in_case_dns_server_is_cidr_resource
            }),
            Transition::RoamClient { ip4, ip6 } => {
                // In production, we always rebind to a new port so we never roam to our old existing IP / port combination.

                let is_assigned_ip4 = ip4.is_some_and(|ip| state.network.contains(ip));
                let is_assigned_ip6 = ip6.is_some_and(|ip| state.network.contains(ip));

                !is_assigned_ip4 && !is_assigned_ip6
            }
            Transition::ReconnectPortal => true,
            Transition::RemoveResource(r) => {
                let has_resource = state.client.inner().has_resource(*r);
                let has_tcp_connection = state
                    .client
                    .inner()
                    .tcp_connection_tuple_to_resource(*r)
                    .is_some();

                // Don't deactivate resources we don't have. It doesn't hurt but makes the logs of reduced testcases weird.
                // Also don't deactivate resources where we have TCP connections as those would get interrupted.
                has_resource && !has_tcp_connection
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
            Transition::RestartClient(_) => true,
            Transition::PartitionRelaysFromPortal => true,
            Transition::DeauthorizeWhileGatewayIsPartitioned(r) => {
                let has_resource = state.client.inner().has_resource(*r);
                let has_gateway_for_resource = state
                    .portal
                    .gateway_for_resource(*r)
                    .is_some_and(|g| state.gateways.contains_key(g));
                let has_tcp_connection = state
                    .client
                    .inner()
                    .tcp_connection_tuple_to_resource(*r)
                    .is_some();

                // Don't deactivate resources we don't have. It doesn't hurt but makes the logs of reduced testcases weird.
                // Also don't deactivate resources where we have TCP connections as those would get interrupted.
                has_resource && has_gateway_for_resource && !has_tcp_connection
            }
            Transition::UpdateDnsRecords { .. } => true,
        }
    }

    fn is_valid_dst_ip(&self, dst: IpAddr) -> bool {
        let Some(rid) = self.client.inner().cidr_resource_by_ip(dst) else {
            // As long as the packet is valid it's always valid to send to a non-resource
            return true;
        };

        // If the dst is a peer, the packet will only be routed if we are connected.
        if crate::is_peer(dst) {
            return match dst {
                IpAddr::V4(dst) => self.connected_gateway_ipv4_ips().contains(&(dst.into())),
                IpAddr::V6(dst) => self.connected_gateway_ipv6_ips().contains(&(dst.into())),
            };
        }

        let Some(gateway) = self.portal.gateway_for_resource(rid) else {
            return false;
        };

        self.gateways.contains_key(gateway)
    }

    fn is_valid_dst_domain(&self, name: &DomainName, src: &IpAddr) -> bool {
        let Some(resource) = self.client.inner().dns_resource_by_domain(name) else {
            return false;
        };
        let Some(gateway) = self.portal.gateway_for_resource(resource.id) else {
            return false;
        };

        self.client
            .inner()
            .dns_records
            .get(name)
            .is_some_and(|r| match src {
                IpAddr::V4(_) => r.contains(&RecordType::A),
                IpAddr::V6(_) => r.contains(&RecordType::AAAA),
            })
            && self.gateways.contains_key(gateway)
    }
}

/// Several helper functions to make the reference state more readable.
impl ReferenceState {
    // We surface what are the existing rtypes for a domain so that it's easier
    // for the proptests to hit an existing record.
    fn all_domains(&self, now: Instant) -> Vec<(DomainName, Vec<RecordType>)> {
        fn domains_and_rtypes(
            records: &DnsRecords,
            at: Instant,
        ) -> impl Iterator<Item = (DomainName, Vec<RecordType>)> {
            records
                .domains_iter()
                .map(move |d| (d.clone(), records.domain_rtypes(&d, at)))
        }

        // We may have multiple gateways in a site, so we need to dedup.
        let unique_domains = self
            .gateways
            .values()
            .flat_map(|g| domains_and_rtypes(g.inner().dns_records(), now))
            .chain(domains_and_rtypes(&self.global_dns_records, now))
            .filter(|(_, rtypes)| !rtypes.is_empty())
            .collect::<BTreeSet<_>>();

        Vec::from_iter(unique_domains)
    }

    fn dns_resource_domains(&self) -> Vec<DomainName> {
        // We may have multiple gateways in a site, so we need to dedup.
        let unique_domains = self
            .gateways
            .values()
            .flat_map(|g| g.inner().dns_records().domains_iter())
            .chain(self.global_dns_records.domains_iter())
            .filter(|d| self.client.inner().dns_resource_by_domain(d).is_some())
            .collect::<BTreeSet<_>>();

        Vec::from_iter(unique_domains)
    }

    fn reachable_dns_servers(&self) -> Vec<dns::Upstream> {
        self.client
            .inner()
            .expected_dns_servers()
            .into_iter()
            .filter(|s| match s {
                crate::dns::Upstream::Do53 {
                    server: SocketAddr::V4(_),
                } => self.client.ip4.is_some(),
                crate::dns::Upstream::Do53 {
                    server: SocketAddr::V6(_),
                } => self.client.ip6.is_some(),
                crate::dns::Upstream::DoH { .. } => true,
            })
            .collect()
    }

    fn all_resources_not_known_to_client(&self) -> Vec<client::Resource> {
        let mut all_resources = self.portal.all_resources();
        all_resources.retain(|r| !self.client.inner().has_resource(r.id()));

        all_resources
    }

    fn cidr_and_dns_resources_on_client(&self) -> Vec<client::Resource> {
        let mut all_resources = self.portal.all_resources();
        all_resources.retain(|r| {
            matches!(r, client::Resource::Cidr(_) | client::Resource::Dns(_))
                && self.client.inner().has_resource(r.id())
        });

        all_resources
    }

    fn cidr_resources_on_client(&self) -> Vec<client::CidrResource> {
        self.portal
            .all_resources()
            .into_iter()
            .flat_map(|r| match r {
                client::Resource::Cidr(r) => Some(r),
                client::Resource::Dns(_) | client::Resource::Internet(_) => None,
            })
            .filter(|r| self.client.inner().has_resource(r.id))
            .collect()
    }

    fn wildcard_dns_resources_on_client(&self) -> Vec<client::DnsResource> {
        self.portal
            .all_resources()
            .into_iter()
            .flat_map(|r| match r {
                client::Resource::Dns(r) => Some(r),
                client::Resource::Cidr(_) | client::Resource::Internet(_) => None,
            })
            .filter(|r| self.client.inner().has_resource(r.id))
            .filter(|r| r.address.starts_with("*."))
            .collect()
    }

    fn regular_sites(&self) -> Vec<Site> {
        let all_sites = self
            .portal
            .all_resources()
            .into_iter()
            .filter(|r| !matches!(r, client::Resource::Internet(_)))
            .flat_map(|r| r.sites().into_iter().cloned().collect::<Vec<_>>())
            .collect::<BTreeSet<_>>();

        Vec::from_iter(all_sites)
    }

    fn connected_gateway_ipv4_ips(&self) -> Vec<Ipv4Network> {
        self.client
            .inner()
            .connected_resources()
            .filter_map(|r| {
                let gateway = self.portal.gateway_for_resource(r)?;
                let gateway_host = self.gateways.get(gateway)?;

                Some(gateway_host.inner().tunnel_ip4.into())
            })
            .unique()
            .collect()
    }

    fn connected_gateway_ipv6_ips(&self) -> Vec<Ipv6Network> {
        self.client
            .inner()
            .connected_resources()
            .filter_map(|r| {
                let gateway = self.portal.gateway_for_resource(r)?;
                let gateway_host = self.gateways.get(gateway)?;

                Some(gateway_host.inner().tunnel_ip6.into())
            })
            .unique()
            .collect()
    }

    fn resolved_v4_domains_with_tcp_resources(&self) -> Vec<DomainName> {
        self.client
            .inner()
            .resolved_v4_domains()
            .into_iter()
            .filter(|domain| self.tcp_resources.contains_key(domain))
            .collect()
    }

    fn resolved_v6_domains_with_tcp_resources(&self) -> Vec<DomainName> {
        self.client
            .inner()
            .resolved_v6_domains()
            .into_iter()
            .filter(|domain| self.tcp_resources.contains_key(domain))
            .collect()
    }

    fn resolved_v4_domains_with_icmp_errors(&self, at: Instant) -> Vec<DomainName> {
        self.client
            .inner()
            .resolved_v4_domains()
            .into_iter()
            .filter(|d| {
                self.global_dns_records
                    .domain_ips_iter(d, at)
                    .any(|ip| self.icmp_error_hosts.icmp_error_for_ip(ip).is_some())
            })
            .collect()
    }

    fn resolved_v6_domains_with_icmp_errors(&self, at: Instant) -> Vec<DomainName> {
        self.client
            .inner()
            .resolved_v6_domains()
            .into_iter()
            .filter(|d| {
                self.global_dns_records
                    .domain_ips_iter(d, at)
                    .any(|ip| self.icmp_error_hosts.icmp_error_for_ip(ip).is_some())
            })
            .collect()
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
    }
}

fn select_host_v4(hosts: &[Ipv4Network]) -> impl Strategy<Value = Ipv4Addr> + use<> {
    sample::select(hosts.to_vec()).prop_flat_map(crate::proptest::host_v4)
}

fn select_host_v6(hosts: &[Ipv6Network]) -> impl Strategy<Value = Ipv6Addr> + use<> {
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
