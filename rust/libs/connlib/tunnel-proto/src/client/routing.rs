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
    #[cfg_attr(not(feature = "telemetry"), expect(dead_code))]
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
    /// Resolve an outbound packet, preferring direct Clients over Gateway resources.
    pub(super) fn resolve(
        &mut self,
        destination: IpAddr,
        protocol: Protocol,
        internet_resource: Option<ResourceId>,
    ) -> Option<Route> {
        if let Some(entry) = self.peer.matches(destination, Ok(protocol)).cloned() {
            return Some(Route::Client {
                filter: entry.filter,
                resource_id: entry.resource_id,
            });
        }

        self.resolve_resource(destination, protocol, internet_resource)
    }

    /// Resolve only resources routed through a Gateway.
    pub(super) fn resolve_resource(
        &mut self,
        destination: IpAddr,
        protocol: Protocol,
        internet_resource: Option<ResourceId>,
    ) -> Option<Route> {
        if let Some(entry) = self.dns.matches(destination, Ok(protocol)).cloned() {
            return Some(Route::Gateway {
                filter: entry.filter,
                resource_id: entry.resource_id,
                domain: Some(entry.domain),
            });
        }

        if let Some(entry) = self.cidr.matches(destination, Ok(protocol)).cloned() {
            return Some(Route::Gateway {
                filter: entry.filter,
                resource_id: entry.resource_id,
                domain: None,
            });
        }

        // Firezone's tunnel range holds Clients and Gateways, so the Internet Resource must
        // not claim it: only the Client table consulted by `resolve` routes there. Letting
        // the catch-all below match would send Client-to-Client traffic to a Gateway, which
        // hair-pins it back out of its TUN device.
        if crate::is_peer(destination) {
            return None;
        }

        let resource_id = internet_resource?;

        Some(Route::Gateway {
            filter: FilterEngine::PermitAll,
            resource_id,
            domain: None,
        })
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
            .map(|entry| (entry.resource_id, entry.domain.clone()))
    }

    pub(super) fn has_cidr_route(&mut self, destination: IpAddr, protocol: Protocol) -> bool {
        self.cidr.matches(destination, Ok(protocol)).is_some()
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

    pub(super) fn upsert_static_peer(
        &mut self,
        network: IpNetwork,
        resource_id: ResourceId,
        filter: FilterEngine,
    ) -> bool {
        self.peer.upsert(
            network,
            PeerEntry {
                filter,
                resource_id,
                kind: PoolKind::Static,
            },
        )
    }

    pub(super) fn upsert_dynamic_peer(
        &mut self,
        network: IpNetwork,
        resource_id: ResourceId,
        filter: FilterEngine,
    ) -> bool {
        self.peer.upsert(
            network,
            PeerEntry {
                filter,
                resource_id,
                kind: PoolKind::Dynamic,
            },
        )
    }

    pub(super) fn remove_by_id(&mut self, resource_id: ResourceId) {
        self.cidr.remove_by_id(resource_id);
        self.dns.remove_by_id(resource_id);
        self.peer.remove_by_id(resource_id);
    }

    pub(super) fn remove_peer(&mut self, network: IpNetwork, resource_id: ResourceId) {
        self.peer
            .remove(network, |entry| entry.resource_id == resource_id);
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
    kind: PoolKind,
}

impl RouteEntry for PeerEntry {
    fn filter(&self) -> &FilterEngine {
        &self.filter
    }

    fn resource_id(&self) -> ResourceId {
        self.resource_id
    }

    fn specificity(&self, other: &Self) -> Ordering {
        self.kind.cmp(&other.kind)
    }
}

/// How a device pool learns which peers it routes to.
///
/// The declaration order is load-bearing: `Static` is *greater*, so a pool that names its
/// members wins the [`RouteEntry::specificity`] tie-break against one that resolves them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum PoolKind {
    Dynamic,
    Static,
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
    use crate::messages::{Filter, PortRange};
    use std::net::Ipv4Addr;

    #[test]
    fn internet_resource_does_not_route_to_another_client() {
        let mut tables = RoutingTables::default();

        let route = tables.resolve(
            other_client_tun_ip(),
            Protocol::Tcp(80),
            Some(internet_resource_id()),
        );

        assert!(route.is_none());
    }

    #[test]
    fn device_pool_routes_to_another_client() {
        let mut tables = RoutingTables::default();
        add_static_member(&mut tables, static_pool_id(), FilterEngine::PermitAll);

        let route = tables.resolve(
            other_client_tun_ip(),
            Protocol::Tcp(80),
            Some(internet_resource_id()),
        );

        assert!(matches!(
            route,
            Some(Route::Client { resource_id, .. }) if resource_id == static_pool_id()
        ));
    }

    #[test]
    fn dynamic_pool_claims_resolved_peer() {
        let mut tables = RoutingTables::default();
        resolve_through_pool(&mut tables, dynamic_pool_id(), FilterEngine::PermitAll);

        let route = tables.resolve(
            other_client_tun_ip(),
            Protocol::Tcp(80),
            Some(internet_resource_id()),
        );

        assert!(matches!(
            route,
            Some(Route::Client { resource_id, .. }) if resource_id == dynamic_pool_id()
        ));
    }

    #[test]
    fn dynamic_pool_does_not_claim_unresolved_peer() {
        let mut tables = RoutingTables::default();
        resolve_through_pool(&mut tables, dynamic_pool_id(), FilterEngine::PermitAll);

        let route = tables.resolve(
            IpAddr::V4(Ipv4Addr::new(100, 64, 0, 4)),
            Protocol::Tcp(80),
            Some(internet_resource_id()),
        );

        assert!(route.is_none());
    }

    #[test]
    fn static_pool_wins_over_a_dynamic_pool_that_also_permits() {
        let mut tables = RoutingTables::default();
        resolve_through_pool(&mut tables, dynamic_pool_id(), FilterEngine::PermitAll);
        add_static_member(&mut tables, static_pool_id(), FilterEngine::PermitAll);

        let route = tables.resolve(other_client_tun_ip(), Protocol::Tcp(80), None);

        assert!(matches!(
            route,
            Some(Route::Client { resource_id, .. }) if resource_id == static_pool_id()
        ));
    }

    #[test]
    fn dynamic_pool_wins_over_a_static_pool_that_rejects() {
        let mut tables = RoutingTables::default();
        resolve_through_pool(&mut tables, dynamic_pool_id(), permit_tcp(80));
        add_static_member(
            &mut tables,
            static_pool_id(),
            FilterEngine::new(&[Filter::Icmp]),
        );

        let route = tables.resolve(other_client_tun_ip(), Protocol::Tcp(80), None);

        assert!(matches!(
            route,
            Some(Route::Client { resource_id, .. }) if resource_id == dynamic_pool_id()
        ));
    }

    fn add_static_member(tables: &mut RoutingTables, pool: ResourceId, filter: FilterEngine) {
        tables.upsert_static_peer(IpNetwork::from(other_client_tun_ip()), pool, filter);
    }

    fn resolve_through_pool(tables: &mut RoutingTables, pool: ResourceId, filter: FilterEngine) {
        tables.upsert_dynamic_peer(IpNetwork::from(other_client_tun_ip()), pool, filter);
    }

    fn permit_tcp(port: u16) -> FilterEngine {
        FilterEngine::new(&[Filter::Tcp(PortRange::single(port))])
    }

    fn other_client_tun_ip() -> IpAddr {
        IpAddr::V4(Ipv4Addr::new(100, 64, 0, 3))
    }

    fn internet_resource_id() -> ResourceId {
        ResourceId::from_u128(1)
    }

    fn static_pool_id() -> ResourceId {
        ResourceId::from_u128(2)
    }

    fn dynamic_pool_id() -> ResourceId {
        ResourceId::from_u128(10)
    }
}
