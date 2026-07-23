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
    /// Used by the structured generator after it has built each component.
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
        if !matches!(transition, Transition::UpdateSystemDnsServers { .. }) {
            for client in state.clients.values_mut() {
                client.exec_mut(RefClient::finish_system_dns_tcp_connections);
            }
        }

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
            Transition::SendDnsQuery { client_id, query } => {
                let upstream_do53 = state.portal.upstream_do53();

                state.clients.get_mut(client_id).unwrap().exec_mut(|c| {
                    c.on_dns_query(query, upstream_do53);
                });
            }
            Transition::SendIcmpPacket {
                client_id,
                dst,
                expected_route,
                seq,
                identifier,
                payload,
                ..
            } => {
                state
                    .clients
                    .get_mut(client_id)
                    .unwrap()
                    .exec_mut(|client| {
                        client.on_icmp_packet(
                            dst.clone(),
                            *expected_route,
                            *seq,
                            *identifier,
                            *payload,
                            now,
                        )
                    });
            }
            Transition::SendUdpPacket {
                client_id,
                dst,
                expected_route,
                sport,
                dport,
                payload,
                ..
            } => {
                state
                    .clients
                    .get_mut(client_id)
                    .unwrap()
                    .exec_mut(|client| {
                        client.on_udp_packet(
                            dst.clone(),
                            *expected_route,
                            *sport,
                            *dport,
                            *payload,
                            now,
                        )
                    });
            }
            Transition::ConnectTcp {
                client_id,
                src,
                dst,
                expected_route,
                sport,
                dport,
            } => {
                state
                    .clients
                    .get_mut(client_id)
                    .unwrap()
                    .exec_mut(|client| {
                        client.on_connect_tcp(*src, dst.clone(), *expected_route, *sport, *dport);
                    });
            }
            Transition::UpdateSystemDnsServers { servers } => {
                for client in state.clients.values_mut() {
                    let can_connect_to_internet = client
                        .inner()
                        .active_internet_resource()
                        .is_some_and(|resource| {
                            state
                                .portal
                                .gateway_for_resource(resource)
                                .is_some_and(|gateway| state.gateways.contains_key(gateway))
                        });

                    client.exec_mut(|client| {
                        client.update_system_dns_resolvers(servers, can_connect_to_internet)
                    });
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

    pub(crate) fn clear_packets(state: &mut ReferenceState) {
        for client in state.clients.values_mut() {
            client.exec_mut(|c| c.clear_packets())
        }
    }
}

/// Several helper functions to make the reference state more readable.
impl ReferenceState {
    pub(crate) fn all_resource_ids(&self) -> Vec<ResourceId> {
        self.clients
            .values()
            .flat_map(|c| c.inner().all_resource_ids())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect()
    }

    pub(crate) fn removable_resource_ids(&self) -> Vec<ResourceId> {
        self.all_resource_ids()
            .into_iter()
            .filter(|resource| {
                self.clients.values().all(|client| {
                    client
                        .inner()
                        .tcp_connection_tuple_to_resource(*resource)
                        .is_none()
                })
            })
            .collect()
    }

    pub(crate) fn deauthorizable_resource_ids(&self) -> Vec<ResourceId> {
        self.removable_resource_ids()
            .into_iter()
            .filter(|resource| {
                self.portal
                    .gateway_for_resource(*resource)
                    .is_some_and(|gateway| self.gateways.contains_key(gateway))
            })
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

    pub(crate) fn route_for_packet(
        &self,
        client_id: ClientId,
        dst: &Destination,
        protocol: Protocol,
    ) -> PacketRoute {
        let Some(client) = self.clients.get(&client_id) else {
            return PacketRoute::Drop;
        };
        let clients_by_ip = self.client_ip_to_id();

        client.inner().route_for_packet(
            dst,
            protocol,
            |resource| {
                self.portal
                    .gateway_for_resource(resource)
                    .copied()
                    .filter(|gateway| self.gateways.contains_key(gateway))
            },
            |ip| {
                self.portal
                    .gateway_by_ip(ip)
                    .filter(|gateway| self.gateways.contains_key(gateway))
            },
            |ip| clients_by_ip.get(&ip).copied(),
        )
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
        let upstream_do53 = self.portal.upstream_do53();

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
                    .filter(|server| {
                        if upstream_do53.is_empty() {
                            return true;
                        }

                        client
                            .inner()
                            .upstream_dns_server_via_resource(server)
                            .is_none_or(|resource| {
                                self.portal
                                    .gateway_for_resource(resource)
                                    .is_some_and(|gateway| self.gateways.contains_key(gateway))
                            })
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

    pub(crate) fn resources_unknown_to_all_clients(&self) -> Vec<client::Resource> {
        self.portal
            .all_resources()
            .into_iter()
            .filter(|resource| {
                self.clients
                    .values()
                    .all(|client| !client.inner().has_resource(resource.id()))
            })
            .collect()
    }

    /// Resources that have configurable traffic filters and exist on at least one client.
    ///
    /// Used by `Transition::ChangeFiltersOfResource`.
    pub(crate) fn resources_with_filters_on_any_client(&self) -> Vec<client::Resource> {
        self.portal
            .all_resources()
            .into_iter()
            .filter(|resource| {
                matches!(
                    resource,
                    client::Resource::Cidr(_)
                        | client::Resource::Dns(_)
                        | client::Resource::StaticDevicePool(_)
                ) && self
                    .clients
                    .values()
                    .any(|client| client.inner().has_resource(resource.id()))
            })
            .collect()
    }

    pub(crate) fn cidr_and_dns_resources_on_any_client(&self) -> Vec<client::Resource> {
        self.portal
            .all_resources()
            .into_iter()
            .filter(|resource| {
                matches!(
                    resource,
                    client::Resource::Cidr(_) | client::Resource::Dns(_)
                ) && self
                    .clients
                    .values()
                    .any(|client| client.inner().has_resource(resource.id()))
            })
            .collect()
    }

    pub(crate) fn cidr_resources_on_any_client(&self) -> Vec<client::CidrResource> {
        self.portal
            .all_resources()
            .into_iter()
            .filter_map(|r| match r {
                client::Resource::Cidr(r) => Some(r),
                client::Resource::Dns(_)
                | client::Resource::Internet(_)
                | client::Resource::StaticDevicePool(_)
                | client::Resource::DynamicDevicePool(_) => None,
            })
            .filter(|resource| {
                self.clients
                    .values()
                    .any(|client| client.inner().has_resource(resource.id))
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
