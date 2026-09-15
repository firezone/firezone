use std::{cmp::Ordering, net::IpAddr};

use connlib_model::ResourceId;
use dns_types::DomainName;
use ip_network::IpNetwork;
use ip_packet::{Protocol, UnsupportedProtocol};

use crate::{
    dns,
    filter_engine::FilterEngine,
    routing_table::{RouteEntry, RoutingTable},
};

/// The result of applying all Client routing tables to an outbound packet.
#[derive(Clone)]
pub(super) enum Route {
    Client {
        filter: FilterEngine,
        resource_id: ResourceId,
    },
    Gateway {
        filter: FilterEngine,
        resource_id: ResourceId,
        domain: Option<DomainName>,
    },
}

impl Route {
    pub(super) fn filter(&self) -> &FilterEngine {
        match self {
            Self::Client { filter, .. } => filter,
            Self::Gateway { filter, .. } => filter,
        }
    }

    pub(super) fn resource_id(&self) -> ResourceId {
        match self {
            Self::Client { resource_id, .. } | Self::Gateway { resource_id, .. } => *resource_id,
        }
    }
}

/// The client's routing tables, one for each kind of destination.
#[derive(Default)]
pub(super) struct RoutingTables {
    cidr: RoutingTable<CidrEntry>,
    dns: RoutingTable<DnsEntry>,
    peer: RoutingTable<PeerEntry>,
}

impl RoutingTables {
    /// Resolves outbound traffic, preferring device pools over gateway resources.
    pub(super) fn resolve(
        &mut self,
        destination: IpAddr,
        protocol: Protocol,
        internet_resource: Option<ResourceId>,
    ) -> Vec<Route> {
        let peers = self.peer.matches(destination, Ok(protocol));
        if !peers.is_empty() {
            return peers
                .iter()
                .map(|entry| Route::Client {
                    filter: entry.filter.clone(),
                    resource_id: entry.resource_id,
                })
                .collect();
        }

        self.resolve_resource(destination, protocol, internet_resource)
    }

    /// Resolves resources routed through a gateway.
    pub(super) fn resolve_resource(
        &mut self,
        destination: IpAddr,
        protocol: Protocol,
        internet_resource: Option<ResourceId>,
    ) -> Vec<Route> {
        let dns = self.dns.matches(destination, Ok(protocol));
        if !dns.is_empty() {
            return dns
                .iter()
                .map(|entry| Route::Gateway {
                    filter: entry.filter.clone(),
                    resource_id: entry.resource_id,
                    domain: Some(entry.domain.clone()),
                })
                .collect();
        }

        let cidr = self.cidr.matches(destination, Ok(protocol));
        if !cidr.is_empty() {
            return cidr
                .iter()
                .map(|entry| Route::Gateway {
                    filter: entry.filter.clone(),
                    resource_id: entry.resource_id,
                    domain: None,
                })
                .collect();
        }

        // The Internet Resource must not send tunnel addresses to a gateway.
        if crate::is_peer(destination) {
            return Vec::new();
        }

        internet_resource
            .into_iter()
            .map(|resource_id| Route::Gateway {
                filter: FilterEngine::PermitAll,
                resource_id,
                domain: None,
            })
            .collect()
    }

    pub(super) fn cidr_networks(&self) -> impl Iterator<Item = IpNetwork> + '_ {
        self.cidr.networks()
    }

    pub(super) fn dns_resource(
        &mut self,
        destination: IpAddr,
        protocol: Result<Protocol, UnsupportedProtocol>,
    ) -> Option<(ResourceId, DomainName)> {
        self.dns
            .matches(destination, protocol)
            .first()
            .map(|entry| (entry.resource_id, entry.domain.clone()))
    }

    pub(super) fn has_cidr_route(&mut self, destination: IpAddr, protocol: Protocol) -> bool {
        !self.cidr.matches(destination, Ok(protocol)).is_empty()
    }

    pub(super) fn upsert_cidr(
        &mut self,
        network: IpNetwork,
        resource_id: ResourceId,
        filter: FilterEngine,
    ) -> bool {
        self.cidr.upsert(
            network,
            CidrEntry {
                filter,
                resource_id,
            },
        )
    }

    pub(super) fn upsert_dns(
        &mut self,
        network: IpNetwork,
        resource_id: ResourceId,
        domain: DomainName,
        pattern: dns::Pattern,
        filter: FilterEngine,
    ) -> bool {
        self.dns.upsert(
            network,
            DnsEntry {
                filter,
                resource_id,
                domain,
                pattern,
            },
        )
    }

    pub(super) fn upsert_pool(&mut self, resource_id: ResourceId, filter: FilterEngine) {
        self.peer.remove_by_id(resource_id);
        for network in [crate::IPV4_TUNNEL.into(), crate::IPV6_TUNNEL.into()] {
            self.peer.upsert(
                network,
                PeerEntry {
                    resource_id,
                    filter: filter.clone(),
                },
            );
        }
    }

    pub(super) fn remove_by_id(&mut self, resource_id: ResourceId) {
        self.cidr.remove_by_id(resource_id);
        self.dns.remove_by_id(resource_id);
        self.peer.remove_by_id(resource_id);
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct CidrEntry {
    filter: FilterEngine,
    resource_id: ResourceId,
}

impl RouteEntry for CidrEntry {
    fn filter(&self) -> &FilterEngine {
        &self.filter
    }

    fn resource_id(&self) -> ResourceId {
        self.resource_id
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct PeerEntry {
    filter: FilterEngine,
    resource_id: ResourceId,
}

impl RouteEntry for PeerEntry {
    fn filter(&self) -> &FilterEngine {
        &self.filter
    }

    fn resource_id(&self) -> ResourceId {
        self.resource_id
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct DnsEntry {
    filter: FilterEngine,
    resource_id: ResourceId,
    domain: DomainName,
    pattern: dns::Pattern,
}

impl RouteEntry for DnsEntry {
    fn filter(&self) -> &FilterEngine {
        &self.filter
    }

    fn resource_id(&self) -> ResourceId {
        self.resource_id
    }

    /// A more specific (i.e. *greater*) pattern wins over a less specific one.
    fn specificity(&self, other: &Self) -> Ordering {
        self.pattern.cmp(&other.pattern).reverse()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    #[test]
    fn internet_resource_does_not_route_to_another_client() {
        let mut tables = RoutingTables::default();

        let route = tables.resolve(
            other_client_tun_ip(),
            Protocol::Tcp(80),
            Some(internet_resource_id()),
        );

        assert!(route.is_empty());
    }

    #[test]
    fn pool_routes_cover_both_tunnel_ranges() {
        let mut tables = RoutingTables::default();
        tables.upsert_pool(pool_id(), FilterEngine::PermitAll);

        for ip in ["100.64.0.4", "100.95.255.254", "fd00:2021:1111::4"] {
            let routes = tables.resolve(ip.parse().unwrap(), Protocol::Tcp(80), None);
            assert_eq!(
                routes.iter().map(Route::resource_id).collect::<Vec<_>>(),
                vec![pool_id()]
            );
        }
        assert!(
            tables
                .resolve("100.96.0.4".parse().unwrap(), Protocol::Tcp(80), None)
                .is_empty()
        );
    }

    fn other_client_tun_ip() -> IpAddr {
        IpAddr::V4(Ipv4Addr::new(100, 64, 0, 3))
    }

    fn internet_resource_id() -> ResourceId {
        ResourceId::from_u128(1)
    }

    fn pool_id() -> ResourceId {
        ResourceId::from_u128(10)
    }
}
