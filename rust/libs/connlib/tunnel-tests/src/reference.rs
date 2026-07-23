use super::dns_records::DnsRecords;
use super::icmp_error_hosts::IcmpErrorHosts;
use super::{ref_client::*, ref_gateway::*, sim_net::*, stub_portal::StubPortal, transition::*};
use connlib_model::{ClientId, GatewayId, RelayId, ResourceId, Site, StaticSecret};
use dns_types::{DomainName, RecordType};
use ip_network::{Ipv4Network, Ipv6Network};
use ip_packet::Protocol;
use itertools::Itertools;
use std::net::{Ipv4Addr, Ipv6Addr};
use std::time::Instant;
use std::{
    collections::{BTreeMap, BTreeSet},
    fmt,
    net::{IpAddr, SocketAddr},
};
use tunnel::dns;
use tunnel::dns::is_subdomain;
use tunnel::messages::Filter;

use crate::resource as client;

/// The reference state machine of the tunnel.
///
/// This is the "expected" part of our test.
#[derive(Debug, Clone)]
pub(crate) struct ReferenceState {
    pub(crate) clients: BTreeMap<ClientId, Host<RefClient>>,
    pub(crate) gateways: BTreeMap<GatewayId, Host<RefGateway>>,
    pub(crate) relays: BTreeMap<RelayId, Host<u64>>,

    pub(crate) portal: StubPortal,

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
/// The logic in here represents what we expect the [`ClientState`](tunnel::ClientState) & [`GatewayState`](tunnel::GatewayState) to do.
/// Care has to be taken that we don't implement things in a buggy way here.
/// After all, if your test has bugs, it won't catch any in the actual implementation.
impl ReferenceState {
    /// Assemble a [`ReferenceState`] from already-generated parts.
    ///
    /// Used by the structured (`arbitrary`-driven) generator, which builds each
    /// component directly instead of through a proptest `Strategy`.
    pub(crate) fn from_parts(
        clients: BTreeMap<ClientId, Host<RefClient>>,
        gateways: BTreeMap<GatewayId, Host<RefGateway>>,
        relays: BTreeMap<RelayId, Host<u64>>,
        portal: StubPortal,
        global_dns_records: DnsRecords,
        tcp_resources: BTreeMap<DomainName, BTreeSet<SocketAddr>>,
        icmp_error_hosts: IcmpErrorHosts,
        network: RoutingTable,
    ) -> Self {
        Self {
            clients,
            gateways,
            relays,
            portal,
            global_dns_records,
            tcp_resources,
            icmp_error_hosts,
            network,
        }
    }

    /// Apply the transition to our reference state.
    ///
    /// Here is where we implement the "expected" logic.
    pub(crate) fn apply(mut state: Self, transition: &Transition, now: Instant) -> Self {
        match transition {
            Transition::AddResource(resource) => {
                for client in state.clients.values_mut() {
                    client.exec_mut(|client| match resource {
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
                        client::Resource::StaticDevicePool(r) => {
                            client.add_static_device_pool_resource(r.clone());
                        }
                        client::Resource::DynamicDevicePool(r) => {
                            client.add_dynamic_device_pool_resource(r.clone());
                        }
                    });
                }
            }
            Transition::RemoveResource(id) => {
                for client in state.clients.values_mut() {
                    client.exec_mut(|client| {
                        client.remove_resource(id);
                    });
                }
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

                for client in state.clients.values_mut() {
                    client.exec_mut(|c| c.add_cidr_resource(new_resource.clone()));
                }
            }
            Transition::MoveResourceToNewSite { resource, new_site } => {
                state
                    .portal
                    .move_resource_to_new_site(resource.id(), new_site.clone());

                for client in state.clients.values_mut() {
                    client.exec_mut(|c| match resource.clone().with_new_site(new_site.clone()) {
                        client::Resource::Dns(r) => c.add_dns_resource(r),
                        client::Resource::Cidr(r) => c.add_cidr_resource(r),
                        client::Resource::Internet(_) => {
                            tracing::error!("Internet Resource cannot move site");
                        }
                        client::Resource::StaticDevicePool(_)
                        | client::Resource::DynamicDevicePool(_) => {}
                    })
                }
            }
            Transition::ChangeFiltersOfResource {
                resource,
                new_filters,
            } => {
                state
                    .portal
                    .change_filters_of_resource(resource.id(), new_filters.clone());

                let new_resource = resource.clone().with_new_filters(new_filters.clone());

                for client in state.clients.values_mut() {
                    client.exec_mut(|c| match &new_resource {
                        client::Resource::Dns(r) => c.add_dns_resource(r.clone()),
                        client::Resource::Cidr(r) => c.add_cidr_resource(r.clone()),
                        client::Resource::StaticDevicePool(r) => {
                            c.add_static_device_pool_resource(r.clone());
                        }
                        client::Resource::Internet(_) | client::Resource::DynamicDevicePool(_) => {
                            unreachable!()
                        }
                    })
                }
            }
            Transition::UpdateStaticDevicePool {
                pool_id,
                new_devices,
            } => {
                let Some(new_pool) = state
                    .portal
                    .update_static_device_pool_members(*pool_id, new_devices.clone())
                else {
                    tracing::error!(%pool_id, "Unknown static device pool");
                    return state;
                };

                for client in state.clients.values_mut() {
                    client.exec_mut(|c| c.add_static_device_pool_resource(new_pool.clone()));
                }
            }
            Transition::SetInternetResourceState {
                client_id: client,
                active,
            } => state.clients.get_mut(client).unwrap().exec_mut(|client| {
                client.set_internet_resource_state(*active);
            }),
            Transition::SendDnsQueries(queries) => {
                let upstream_do53 = state.portal.upstream_do53();

                for (client_id, query) in queries {
                    state.clients.get_mut(client_id).unwrap().exec_mut(|c| {
                        c.on_dns_query(query, upstream_do53);
                    });
                }
            }
            Transition::SendIcmpPacket {
                client_id,
                dst,
                seq,
                identifier,
                payload,
                ..
            } => {
                let client_ip_to_id = state.client_ip_to_id();
                state
                    .clients
                    .get_mut(client_id)
                    .unwrap()
                    .exec_mut(|client| {
                        client.on_icmp_packet(
                            dst.clone(),
                            *seq,
                            *identifier,
                            *payload,
                            |r| state.portal.gateway_for_resource(r).copied(),
                            |ip| state.portal.gateway_by_ip(ip),
                            |ip| client_ip_to_id.get(&ip).copied(),
                            now,
                        )
                    });
            }
            Transition::SendUdpPacket {
                client_id,
                dst,
                sport,
                dport,
                payload,
                ..
            } => {
                let client_ip_to_id = state.client_ip_to_id();
                state
                    .clients
                    .get_mut(client_id)
                    .unwrap()
                    .exec_mut(|client| {
                        client.on_udp_packet(
                            dst.clone(),
                            *sport,
                            *dport,
                            *payload,
                            |r| state.portal.gateway_for_resource(r).copied(),
                            |ip| state.portal.gateway_by_ip(ip),
                            |ip| client_ip_to_id.get(&ip).copied(),
                            now,
                        )
                    });
            }
            Transition::ConnectTcp {
                client_id,
                src,
                dst,
                sport,
                dport,
            } => {
                let client_ip_to_id = state.client_ip_to_id();
                state
                    .clients
                    .get_mut(client_id)
                    .unwrap()
                    .exec_mut(|client| {
                        client.on_connect_tcp(*src, dst.clone(), *sport, *dport, |ip| {
                            client_ip_to_id.get(&ip).copied()
                        });
                    });
            }
            Transition::UpdateSystemDnsServers { servers } => {
                for client in state.clients.values_mut() {
                    client.exec_mut(|client| client.set_system_dns_resolvers(servers));
                }
            }
            Transition::UpdateUpstreamDo53Servers(servers) => {
                state.portal.set_upstream_do53(servers.clone());
            }
            Transition::UpdateUpstreamDoHServers(servers) => {
                state.portal.set_upstream_doh(servers.clone());
            }
            Transition::UpdateUpstreamSearchDomain(domain) => {
                state.portal.set_search_domain(domain.clone());
            }
            Transition::RoamClient {
                client_id,
                ip4,
                ip6,
                nat_ip4,
                dead_window: _,
                portal_window: _,
            } => {
                // With ICE-less connections, a roam re-keys in place and keeps
                // the connection alive, so we only reset when the portal hands
                // out classic ICE flows.
                let all_iceless = state.portal.iceless();

                let client = state.clients.get_mut(client_id).unwrap();
                state.network.remove_host(client);
                client.ip4.clone_from(ip4);
                client.ip6.clone_from(ip6);
                client.migrate_nat(*nat_ip4);
                let added = state.network.add_host(*client_id, client);
                debug_assert!(added);

                // When roaming, we are not connected to any resource and wait for the next packet to re-establish a connection.
                client.exec_mut(|client| {
                    if !all_iceless {
                        client.reset_connections(now);
                    }
                    client.readd_all_resources();
                });
            }
            Transition::ReconnectPortal { client_id } => {
                // Reconnecting to the portal should have no noticeable impact on the data plane.
                // We do re-add all resources though so depending on the order they are added in, overlapping CIDR resources may change.
                state
                    .clients
                    .get_mut(client_id)
                    .unwrap()
                    .exec_mut(|c| c.readd_all_resources());
            }
            Transition::DeployNewRelays(new_relays) => state.deploy_new_relays(new_relays),
            Transition::RebootRelaysWhilePartitioned(new_relays) => {
                state.deploy_new_relays(new_relays)
            }
            Transition::Idle => {}
            Transition::PartitionRelaysFromPortal => {
                // With ICE-less connections, losing all relays does not fail
                // the connection: the WG session idles until the relays return
                // and probes revive the path. Classic ICE flows disconnect for
                // every pairing that cannot fall back to a direct path.
                if !state.portal.iceless() {
                    let gateway_edges = state
                        .gateways
                        .iter()
                        .map(|(id, g)| (*id, (g.edge_config(), g.ip6.is_some())))
                        .collect::<BTreeMap<_, _>>();
                    let portal = &state.portal;

                    for client in state.clients.values_mut() {
                        let client_edge = client.edge_config();
                        let client_has_ip6 = client.ip6.is_some();
                        let unreachable_gateways = gateway_edges
                            .iter()
                            .filter(|(_, (gateway_edge, gateway_has_ip6))| {
                                !direct_path_possible(
                                    client_edge,
                                    *gateway_edge,
                                    client_has_ip6 && *gateway_has_ip6,
                                )
                            })
                            .map(|(id, _)| *id)
                            .collect::<BTreeSet<_>>();

                        if unreachable_gateways.is_empty() {
                            continue;
                        }

                        client.exec_mut(|c| {
                            c.reset_connections_to_gateways(
                                &unreachable_gateways,
                                |rid| portal.gateway_for_resource(rid).copied(),
                                now,
                            )
                        });
                    }
                }
            }
            Transition::DeauthorizeWhileGatewayIsPartitioned(resource) => {
                for client in state.clients.values_mut() {
                    client.exec_mut(|client| client.remove_resource(resource))
                }
            }
            Transition::RestartClient { client_id, key } => {
                state.clients.get_mut(client_id).unwrap().exec_mut(|c| {
                    c.restart(*key, now);
                })
            }
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
                if state
                    .clients
                    .values()
                    .any(|c| c.inner().has_resource(resource.id()))
                {
                    return false;
                }

                true
            }
            Transition::ChangeCidrResourceAddress {
                resource,
                new_address,
            } => {
                resource.address != *new_address
                    && state
                        .clients
                        .values()
                        .any(|c| c.inner().has_resource(resource.id))
            }
            Transition::MoveResourceToNewSite { resource, new_site } => {
                resource.sites() != BTreeSet::from([new_site])
                    && state
                        .clients
                        .values()
                        .any(|c| c.inner().has_resource(resource.id()))
            }
            Transition::ChangeFiltersOfResource {
                resource,
                new_filters,
            } => {
                resource.filters() != new_filters.as_slice()
                    && state
                        .clients
                        .values()
                        .any(|c| c.inner().has_resource(resource.id()))
            }
            Transition::UpdateStaticDevicePool { pool_id, .. } => {
                // Pool must already exist on at least one client.
                state.portal.all_resources().iter().any(|r| {
                    let client::Resource::StaticDevicePool(existing) = r else {
                        return false;
                    };

                    existing.id == *pool_id
                        && state
                            .clients
                            .values()
                            .any(|c| c.inner().has_resource(*pool_id))
                })
            }
            Transition::SetInternetResourceState { client_id, .. } => {
                state.clients.contains_key(client_id)
            }
            Transition::SendIcmpPacket {
                client_id,
                src,
                dst: Destination::DomainName { name, .. },
                seq,
                identifier,
                payload,
            } => {
                let Some(ref_client) = state.clients.get(client_id).map(|h| h.inner()) else {
                    return false;
                };

                ref_client.is_valid_icmp_packet(seq, identifier, payload)
                    && state.is_valid_dst_domain(
                        client_id,
                        name,
                        src,
                        Protocol::IcmpEcho(identifier.0),
                    )
            }
            Transition::SendUdpPacket {
                client_id,
                src,
                dst: Destination::DomainName { name, .. },
                sport,
                dport,
                payload,
            } => {
                let Some(ref_client) = state.clients.get(client_id).map(|h| h.inner()) else {
                    return false;
                };

                ref_client.is_valid_udp_packet(sport, dport, payload)
                    && state.is_valid_dst_domain(client_id, name, src, Protocol::Udp(dport.0))
            }
            Transition::ConnectTcp {
                client_id,
                src,
                dst: dst @ Destination::DomainName { name, .. },
                sport,
                dport,
            } => {
                let Some(ref_client) = state.clients.get(client_id).map(|h| h.inner()) else {
                    return false;
                };

                state.is_valid_dst_domain(client_id, name, src, Protocol::Tcp(dport.0))
                    && !ref_client.has_tcp_connection(*src, dst.clone(), *sport, *dport)
            }
            Transition::SendIcmpPacket {
                client_id,
                dst: Destination::IpAddr(dst),
                seq,
                identifier,
                payload,
                ..
            } => {
                let Some(ref_client) = state.clients.get(client_id).map(|h| h.inner()) else {
                    return false;
                };

                ref_client.is_valid_icmp_packet(seq, identifier, payload)
                    && state.is_valid_dst_ip(*dst, Protocol::IcmpEcho(identifier.0))
            }
            Transition::SendUdpPacket {
                client_id,
                dst: Destination::IpAddr(dst),
                sport,
                dport,
                payload,
                ..
            } => {
                let Some(ref_client) = state.clients.get(client_id).map(|h| h.inner()) else {
                    return false;
                };

                ref_client.is_valid_udp_packet(sport, dport, payload)
                    && state.is_valid_dst_ip(*dst, Protocol::Udp(dport.0))
            }
            Transition::ConnectTcp {
                client_id,
                src,
                dst: dst @ Destination::IpAddr(dst_ip),
                sport,
                dport,
                ..
            } => {
                let Some(ref_client) = state.clients.get(client_id).map(|h| h.inner()) else {
                    return false;
                };

                state.is_valid_dst_ip(*dst_ip, Protocol::Tcp(dport.0))
                    && !ref_client.has_tcp_connection(*src, dst.clone(), *sport, *dport)
            }
            Transition::UpdateSystemDnsServers { servers } => {
                if servers.is_empty() {
                    return true; // Clearing is allowed.
                }

                servers.iter().any(|dns_server| {
                    state
                        .clients
                        .values()
                        .any(|c| c.sending_socket_for(*dns_server).is_some())
                })
            }
            Transition::UpdateUpstreamDo53Servers(servers) => {
                if servers.is_empty() {
                    return true; // Clearing is allowed.
                }

                servers.iter().any(|dns_server| {
                    state
                        .clients
                        .values()
                        .all(|client| client.sending_socket_for(dns_server.ip).is_some())
                })
            }
            Transition::UpdateUpstreamDoHServers(_) => true,
            Transition::UpdateUpstreamSearchDomain(_) => true,
            Transition::SendDnsQueries(queries) => queries.iter().all(|(client_id, query)| {
                let Some(client) = state.clients.get(client_id) else {
                    return false;
                };

                let has_socket_for_server = match query.dns_server {
                    tunnel::dns::Upstream::Do53 { server } => {
                        client.sending_socket_for(server.ip()).is_some()
                    }
                    tunnel::dns::Upstream::DoH { .. } => true,
                };
                let upstream_do53 = state.portal.upstream_do53();
                let upstream_doh = state.portal.upstream_doh();

                let has_dns_server = client
                    .inner()
                    .expected_dns_servers(upstream_do53, upstream_doh)
                    .contains(&query.dns_server);

                let gateway_is_present_in_case_dns_server_is_cidr_resource =
                    match client.inner().dns_query_via_resource(query, upstream_do53) {
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
            Transition::RoamClient {
                client_id: _,
                ip4,
                ip6,
                nat_ip4,
                dead_window: _,
                portal_window: _,
            } => {
                // In production, we always rebind to a new port so we never roam to our old existing IP / port combination.

                let is_assigned_ip4 = ip4.is_some_and(|ip| state.network.contains(ip));
                let is_assigned_ip6 = ip6.is_some_and(|ip| state.network.contains(ip));
                let is_assigned_nat_ip4 = state.network.contains(*nat_ip4);

                !is_assigned_ip4 && !is_assigned_ip6 && !is_assigned_nat_ip4
            }
            Transition::ReconnectPortal { client_id } => state.clients.contains_key(client_id),
            Transition::RemoveResource(r) => {
                let has_resource = state.clients.values().any(|c| c.inner().has_resource(*r));
                let has_tcp_connection = state
                    .clients
                    .values()
                    .any(|c| c.inner().tcp_connection_tuple_to_resource(*r).is_some());

                // Don't deactivate resources we don't have. It doesn't hurt but makes the logs of reduced testcases weird.
                // Also don't deactivate resources where we have TCP connections as those would get interrupted.
                has_resource && !has_tcp_connection
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
            Transition::RebootRelaysWhilePartitioned(new_relays) => {
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
            Transition::RestartClient { client_id, .. } => state.clients.contains_key(client_id),
            Transition::PartitionRelaysFromPortal => true,
            Transition::DeauthorizeWhileGatewayIsPartitioned(r) => {
                let has_resource = state.clients.values().any(|c| c.inner().has_resource(*r));
                let has_gateway_for_resource = state
                    .portal
                    .gateway_for_resource(*r)
                    .is_some_and(|g| state.gateways.contains_key(g));
                let has_tcp_connection = state
                    .clients
                    .values()
                    .any(|c| c.inner().tcp_connection_tuple_to_resource(*r).is_some());

                // Don't deactivate resources we don't have. It doesn't hurt but makes the logs of reduced testcases weird.
                // Also don't deactivate resources where we have TCP connections as those would get interrupted.
                has_resource && has_gateway_for_resource && !has_tcp_connection
            }
            Transition::UpdateDnsRecords { .. } => true,
        }
    }

    pub(crate) fn clear_packets(state: &mut ReferenceState) {
        for client in state.clients.values_mut() {
            client.exec_mut(|c| c.clear_packets())
        }
    }

    fn is_valid_dst_ip(&self, dst: IpAddr, proto: Protocol) -> bool {
        let rid = self
            .clients
            .values()
            .find_map(|c| c.inner().cidr_resource_by_ip_and_proto(dst, proto));

        let Some(rid) = rid else {
            // As long as the packet is valid it's always valid to send to a non-resource
            return true;
        };

        // If the dst is a peer, the packet will only be routed if we are connected.
        if tunnel::is_peer(dst) {
            return match dst {
                IpAddr::V4(dst) => self
                    .connected_gateway_ipv4_ips()
                    .iter()
                    .any(|(_, network)| network.contains(dst)),
                IpAddr::V6(dst) => self
                    .connected_gateway_ipv6_ips()
                    .iter()
                    .any(|(_, network)| network.contains(dst)),
            };
        }

        let Some(gateway) = self.portal.gateway_for_resource(rid) else {
            return false;
        };

        self.gateways.contains_key(gateway)
    }

    fn is_valid_dst_domain(
        &self,
        client_id: &ClientId,
        name: &DomainName,
        src: &IpAddr,
        proto: Protocol,
    ) -> bool {
        let resource = self
            .clients
            .values()
            .find_map(|c| c.inner().dns_resource_by_domain_and_proto(name, proto));

        let Some(resource) = resource else {
            return false;
        };
        let Some(gateway) = self.portal.gateway_for_resource(resource.id) else {
            return false;
        };
        let Some(client) = self.clients.get(client_id) else {
            return false;
        };

        client
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
    pub(crate) fn all_resource_ids(&self) -> Vec<ResourceId> {
        self.clients
            .values()
            .flat_map(|c| c.inner().all_resource_ids())
            .collect()
    }

    /// Map of every client's tunnel IPs (v4 and v6) to its `ClientId`.
    fn client_ip_to_id(&self) -> BTreeMap<IpAddr, ClientId> {
        self.clients
            .iter()
            .flat_map(|(id, c)| {
                let ip4 = IpAddr::V4(c.inner().tunnel_ip4);
                let ip6 = IpAddr::V6(c.inner().tunnel_ip6);
                [(ip4, *id), (ip6, *id)]
            })
            .collect()
    }

    pub(crate) fn ipv4_cidr_resource_dsts(&self) -> Vec<(ClientId, Ipv4Network, Vec<Filter>)> {
        self.clients
            .iter()
            .flat_map(|(id, c)| {
                c.inner()
                    .ipv4_cidr_resource_dsts()
                    .into_iter()
                    .map(|(ip, filters)| (*id, ip, filters))
            })
            .collect()
    }

    pub(crate) fn resolved_v4_domains(&self) -> Vec<(ClientId, DomainName, Vec<Filter>)> {
        self.clients
            .iter()
            .flat_map(|(id, c)| {
                c.inner()
                    .resolved_v4_domains()
                    .into_iter()
                    .map(|(domain, filters)| (*id, domain, filters))
            })
            .collect()
    }

    pub(crate) fn resolved_ip4_for_non_resources(
        &self,
        global_dns_records: &DnsRecords,
        at: Instant,
    ) -> Vec<(ClientId, Ipv4Addr)> {
        self.clients
            .iter()
            .flat_map(|(id, c)| {
                c.inner()
                    .resolved_ip4_for_non_resources(global_dns_records, at)
                    .into_iter()
                    .map(|ip| (*id, ip))
            })
            .collect()
    }

    pub(crate) fn ipv6_cidr_resource_dsts(&self) -> Vec<(ClientId, Ipv6Network, Vec<Filter>)> {
        self.clients
            .iter()
            .flat_map(|(id, c)| {
                c.inner()
                    .ipv6_cidr_resource_dsts()
                    .into_iter()
                    .map(|(ip, filters)| (*id, ip, filters))
            })
            .collect()
    }

    pub(crate) fn resolved_v6_domains(&self) -> Vec<(ClientId, DomainName, Vec<Filter>)> {
        self.clients
            .iter()
            .flat_map(|(id, c)| {
                c.inner()
                    .resolved_v6_domains()
                    .into_iter()
                    .map(|(domain, filters)| (*id, domain, filters))
            })
            .collect()
    }

    pub(crate) fn resolved_ip6_for_non_resources(
        &self,
        global_dns_records: &DnsRecords,
        at: Instant,
    ) -> Vec<(ClientId, Ipv6Addr)> {
        self.clients
            .iter()
            .flat_map(|(id, c)| {
                c.inner()
                    .resolved_ip6_for_non_resources(global_dns_records, at)
                    .into_iter()
                    .map(|ip| (*id, ip))
            })
            .collect()
    }

    pub(crate) fn dns_resource_domains(&self) -> Vec<DomainName> {
        // We may have multiple gateways in a site, so we need to dedup.
        let unique_domains = self
            .gateways
            .values()
            .flat_map(|g| g.inner().dns_records().domains_iter())
            .chain(self.global_dns_records.domains_iter())
            .filter(|d| {
                self.clients
                    .values()
                    .any(|c| c.inner().dns_resource_by_domain(d, |_| true).is_some())
            })
            .collect::<BTreeSet<_>>();

        Vec::from_iter(unique_domains)
    }

    pub(crate) fn reachable_dns_servers(&self) -> Vec<(ClientId, dns::Upstream)> {
        self.clients
            .iter()
            .flat_map(|(client_id, client)| {
                client
                    .inner()
                    .expected_dns_servers(self.portal.upstream_do53(), self.portal.upstream_doh())
                    .into_iter()
                    .filter(|s| match s {
                        tunnel::dns::Upstream::Do53 {
                            server: SocketAddr::V4(_),
                        } => client.ip4.is_some(),
                        tunnel::dns::Upstream::Do53 {
                            server: SocketAddr::V6(_),
                        } => client.ip6.is_some(),
                        tunnel::dns::Upstream::DoH { .. } => true,
                    })
                    .map(move |server| (*client_id, server))
            })
            .collect()
    }

    pub(crate) fn all_domains(&self, now: Instant) -> Vec<(ClientId, DomainName, Vec<RecordType>)> {
        fn domains_and_rtypes(
            records: &DnsRecords,
            at: Instant,
        ) -> impl Iterator<Item = (DomainName, Vec<RecordType>)> {
            records
                .domains_iter()
                .map(move |d| (d.clone(), records.domain_rtypes(&d, at)))
        }

        self.clients
            .iter()
            .flat_map(move |(client_id, client)| {
                // Get domains from all gateways that this client can reach
                let mut unique_domains = self
                    .gateways
                    .values()
                    .flat_map(|g| domains_and_rtypes(g.inner().dns_records(), now))
                    .chain(domains_and_rtypes(&self.global_dns_records, now))
                    .collect::<BTreeMap<_, _>>();

                // Add domains from client's own dns_records
                for (domain, rtypes) in &client.inner().dns_records {
                    unique_domains
                        .entry(domain.clone())
                        .or_default()
                        .extend(rtypes.iter().copied());
                }

                unique_domains
                    .into_iter()
                    .filter(|(_, rtypes)| !rtypes.is_empty())
                    .map(move |(domain, rtypes)| (*client_id, domain, rtypes))
            })
            .collect()
    }

    pub(crate) fn all_resources_not_known_to_client(&self) -> Vec<(ClientId, client::Resource)> {
        let all_resources = self.portal.all_resources();

        self.clients
            .iter()
            .flat_map(move |(id, client)| {
                let mut all_resources = all_resources.clone();
                all_resources.retain(|r| !client.inner().has_resource(r.id()));

                all_resources.into_iter().map(|r| (*id, r))
            })
            .collect()
    }

    /// DNS resources not yet known to a client but whose address pattern matches a domain that
    /// client has already queried.
    ///
    /// connlib's `StubResolver` allows associating different resources with the same IPs and that
    /// state needs to be correct, even if we add a new resource that we have already assigned IPs for.
    pub(crate) fn unknown_dns_resources_for_already_queried_domains(
        &self,
    ) -> Vec<(ClientId, client::Resource)> {
        let all_resources = self.portal.all_resources();

        self.clients
            .iter()
            .flat_map(|(client_id, client)| {
                let ref_client = client.inner();
                let queried_domains: Vec<_> = ref_client.dns_records.keys().cloned().collect();

                all_resources
                    .iter()
                    .filter(|r| {
                        let client::Resource::Dns(dns) = r else {
                            return false;
                        };

                        !ref_client.has_resource(dns.id)
                            && queried_domains
                                .iter()
                                .any(|domain| is_subdomain(domain, &dns.address))
                    })
                    .cloned()
                    .map(move |r| (*client_id, r))
                    .collect::<Vec<_>>()
            })
            .collect()
    }

    /// Resources that have configurable traffic filters and exist on at least one client.
    ///
    /// Used by `Transition::ChangeFiltersOfResource`.
    pub(crate) fn resources_with_filters_on_client(&self) -> Vec<(ClientId, client::Resource)> {
        let all_resources = self.portal.all_resources();

        self.clients
            .iter()
            .flat_map(|(client_id, client)| {
                let mut all_resources = all_resources.clone();
                all_resources.retain(|r| {
                    matches!(
                        r,
                        client::Resource::Cidr(_)
                            | client::Resource::Dns(_)
                            | client::Resource::StaticDevicePool(_)
                    ) && client.inner().has_resource(r.id())
                });

                all_resources.into_iter().map(move |r| (*client_id, r))
            })
            .collect()
    }

    pub(crate) fn cidr_and_dns_resources_on_client(&self) -> Vec<(ClientId, client::Resource)> {
        let all_resources = self.portal.all_resources();

        self.clients
            .iter()
            .flat_map(|(client_id, client)| {
                let mut all_resources = all_resources.clone();
                all_resources.retain(|r| {
                    matches!(r, client::Resource::Cidr(_) | client::Resource::Dns(_))
                        && client.inner().has_resource(r.id())
                });

                all_resources.into_iter().map(move |r| (*client_id, r))
            })
            .collect()
    }

    pub(crate) fn cidr_resources_on_client(&self) -> Vec<(ClientId, client::CidrResource)> {
        let cidr_resources: Vec<_> = self
            .portal
            .all_resources()
            .into_iter()
            .filter_map(|r| match r {
                client::Resource::Cidr(r) => Some(r),
                client::Resource::Dns(_)
                | client::Resource::Internet(_)
                | client::Resource::StaticDevicePool(_)
                | client::Resource::DynamicDevicePool(_) => None,
            })
            .collect();

        self.clients
            .iter()
            .flat_map(|(client_id, client)| {
                cidr_resources
                    .iter()
                    .filter(|r| client.inner().has_resource(r.id))
                    .map(move |r| (*client_id, r.clone()))
            })
            .collect()
    }

    pub(crate) fn wildcard_dns_resources(&self) -> Vec<(ClientId, client::DnsResource)> {
        let wildcard_resources: Vec<_> = self
            .portal
            .all_resources()
            .into_iter()
            .filter_map(|r| match r {
                client::Resource::Dns(r) if r.address.starts_with("*.") => Some(r),
                client::Resource::Dns(_)
                | client::Resource::Cidr(_)
                | client::Resource::Internet(_)
                | client::Resource::StaticDevicePool(_)
                | client::Resource::DynamicDevicePool(_) => None,
            })
            .collect();

        self.clients
            .iter()
            .flat_map(|(client_id, client)| {
                wildcard_resources
                    .iter()
                    .filter(|r| client.inner().has_resource(r.id))
                    .map(move |r| (*client_id, r.clone()))
            })
            .collect()
    }

    pub(crate) fn regular_sites(&self) -> Vec<Site> {
        let all_sites = self
            .portal
            .all_resources()
            .into_iter()
            .filter(|r| !matches!(r, client::Resource::Internet(_)))
            .flat_map(|r| r.sites().into_iter().cloned().collect::<Vec<_>>())
            .collect::<BTreeSet<_>>();

        Vec::from_iter(all_sites)
    }

    pub(crate) fn connected_gateway_ipv4_ips(&self) -> Vec<(ClientId, Ipv4Network)> {
        self.clients
            .iter()
            .flat_map(|(id, client)| {
                client
                    .inner()
                    .connected_resources()
                    .filter_map(|r| {
                        let gateway = self.portal.gateway_for_resource(r)?;
                        let gateway_host = self.gateways.get(gateway)?;

                        Some((*id, gateway_host.inner().tunnel_ip4.into()))
                    })
                    .unique()
            })
            .collect()
    }

    pub(crate) fn connected_gateway_ipv6_ips(&self) -> Vec<(ClientId, Ipv6Network)> {
        self.clients
            .iter()
            .flat_map(|(id, client)| {
                client
                    .inner()
                    .connected_resources()
                    .filter_map(|r| {
                        let gateway = self.portal.gateway_for_resource(r)?;
                        let gateway_host = self.gateways.get(gateway)?;

                        Some((*id, gateway_host.inner().tunnel_ip6.into()))
                    })
                    .unique()
            })
            .collect()
    }

    pub(crate) fn resolved_v4_domains_with_tcp_resources(
        &self,
    ) -> Vec<(ClientId, DomainName, Vec<Filter>)> {
        self.clients
            .iter()
            .flat_map(|(id, client)| {
                client
                    .inner()
                    .resolved_v4_domains()
                    .into_iter()
                    .filter_map(|(domain, filters)| {
                        self.tcp_resources
                            .contains_key(&domain)
                            .then_some((*id, domain, filters))
                    })
            })
            .collect()
    }

    pub(crate) fn resolved_v6_domains_with_tcp_resources(
        &self,
    ) -> Vec<(ClientId, DomainName, Vec<Filter>)> {
        self.clients
            .iter()
            .flat_map(|(id, client)| {
                client
                    .inner()
                    .resolved_v6_domains()
                    .into_iter()
                    .filter_map(|(domain, filters)| {
                        self.tcp_resources
                            .contains_key(&domain)
                            .then_some((*id, domain, filters))
                    })
            })
            .collect()
    }

    pub(crate) fn resolved_v4_domains_with_icmp_errors(
        &self,
        at: Instant,
    ) -> Vec<(ClientId, DomainName, Vec<Filter>)> {
        self.clients
            .iter()
            .flat_map(|(id, client)| {
                client
                    .inner()
                    .resolved_v4_domains()
                    .into_iter()
                    .filter_map(|(d, filters)| {
                        self.global_dns_records
                            .domain_ips_iter(&d, at)
                            .any(|ip| self.icmp_error_hosts.icmp_error_for_ip(ip).is_some())
                            .then_some((*id, d, filters))
                    })
            })
            .collect()
    }

    pub(crate) fn resolved_v6_domains_with_icmp_errors(
        &self,
        at: Instant,
    ) -> Vec<(ClientId, DomainName, Vec<Filter>)> {
        self.clients
            .iter()
            .flat_map(|(id, client)| {
                client
                    .inner()
                    .resolved_v6_domains()
                    .into_iter()
                    .filter_map(|(d, filters)| {
                        self.global_dns_records
                            .domain_ips_iter(&d, at)
                            .any(|ip| self.icmp_error_hosts.icmp_error_for_ip(ip).is_some())
                            .then_some((*id, d, filters))
                    })
            })
            .collect()
    }

    pub(crate) fn all_client_ids(&self) -> Vec<ClientId> {
        self.clients.keys().copied().collect()
    }

    pub(crate) fn static_device_pools_on_any_client(
        &self,
    ) -> Vec<client::StaticDevicePoolResource> {
        let pools = self
            .portal
            .all_resources()
            .into_iter()
            .filter_map(|r| match r {
                client::Resource::StaticDevicePool(p) => Some(p),
                client::Resource::Dns(_)
                | client::Resource::Cidr(_)
                | client::Resource::Internet(_)
                | client::Resource::DynamicDevicePool(_) => None,
            });

        pools
            .filter(|p| self.clients.values().any(|c| c.inner().has_resource(p.id)))
            .collect()
    }

    fn device_pool_resources_on_client(
        &self,
    ) -> Vec<(ClientId, client::DynamicDevicePoolResource)> {
        let device_pool_resources = self
            .portal
            .all_resources()
            .into_iter()
            .filter_map(|r| match r {
                client::Resource::DynamicDevicePool(r) => Some(r),
                client::Resource::Dns(_)
                | client::Resource::Cidr(_)
                | client::Resource::Internet(_)
                | client::Resource::StaticDevicePool(_) => None,
            })
            .collect::<Vec<_>>();

        self.clients
            .iter()
            .flat_map(|(client_id, client)| {
                device_pool_resources
                    .iter()
                    .filter(|r| client.inner().has_resource(r.id))
                    .map(move |r| (*client_id, r.clone()))
            })
            .collect()
    }

    /// Eligible `(client, device-pool resource, reachable DNS server)` triples
    /// for generating a device-pool DNS query transition.
    ///
    /// Pre-filters to the client × pool × reachable-dns cross-product so we
    /// never emit a no-op transition because the sampled client can't reach
    /// the sampled DNS server.
    pub(crate) fn device_pool_query_targets(
        &self,
    ) -> Vec<(ClientId, client::DynamicDevicePoolResource, dns::Upstream)> {
        let resources_on_client = self.device_pool_resources_on_client();
        let dns_servers = self.reachable_dns_servers();

        resources_on_client
            .into_iter()
            .flat_map(|(client_id, resource)| {
                dns_servers
                    .iter()
                    .filter(move |(dns_client_id, _)| *dns_client_id == client_id)
                    .map(move |(_, server)| (client_id, resource.clone(), server.clone()))
            })
            .collect()
    }

    /// Generates a list of `(src_client_id, dst_ipv4)` tuples where `dst_ipv4` is the tunnel
    /// IPv4 of an online client reachable from `src_client_id` via a static device pool whose
    /// filters allow ICMP, paired with the pool filters that authorize the route.
    pub(crate) fn pool_routed_other_client_tun_ips(&self) -> Vec<(ClientId, IpAddr, Vec<Filter>)> {
        let online_ips_by_id: BTreeMap<ClientId, (IpAddr, IpAddr)> = self
            .clients
            .iter()
            .map(|(id, c)| {
                let inner = c.inner();
                (
                    *id,
                    (IpAddr::V4(inner.tunnel_ip4), IpAddr::V6(inner.tunnel_ip6)),
                )
            })
            .collect();

        self.clients
            .iter()
            .flat_map(|(src_id, src_client)| {
                let online_ips_by_id = online_ips_by_id.clone();
                let src_id = *src_id;

                src_client
                    .inner()
                    .all_resources()
                    .into_iter()
                    .filter_map(|r| match r {
                        client::Resource::StaticDevicePool(p) => Some(p),
                        client::Resource::Dns(_)
                        | client::Resource::Cidr(_)
                        | client::Resource::Internet(_)
                        | client::Resource::DynamicDevicePool(_) => None,
                    })
                    .filter(|pool| pool_filters_allow_icmp_or_udp(&pool.filters))
                    .flat_map(|pool| {
                        let filters = pool.filters.clone();
                        pool.devices
                            .into_iter()
                            .map(move |device| (device, filters.clone()))
                    })
                    .filter(move |(device, _)| device.id != src_id)
                    .flat_map(move |(device, filters)| {
                        let entry = online_ips_by_id.get(&device.id).copied();
                        entry.into_iter().flat_map(move |(v4, v6)| {
                            [(src_id, v4, filters.clone()), (src_id, v6, filters.clone())]
                        })
                    })
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
            let added = self.network.add_host(*rid, new_relay);
            debug_assert!(added);
        }
    }
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

fn pool_filters_allow_icmp_or_udp(filters: &[Filter]) -> bool {
    filters.is_empty()
        || filters
            .iter()
            .any(|f| matches!(f, Filter::Icmp | Filter::Udp(_)))
}
