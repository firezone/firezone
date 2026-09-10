use std::{cmp::Ordering, collections::BTreeSet, net::IpAddr};

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
    /// A device resolved by name that no pool has granted yet; the portal picks one on first use.
    Device,
    Gateway {
        filter: FilterEngine,
        resource_id: ResourceId,
        domain: Option<DomainName>,
    },
}

impl Route {
    #[cfg_attr(not(feature = "telemetry"), expect(dead_code))]
    pub(super) fn resource_id(&self) -> Option<ResourceId> {
        match self {
            Self::Client { resource_id, .. } | Self::Gateway { resource_id, .. } => {
                Some(*resource_id)
            }
            Self::Device => None,
        }
    }
}

/// The client's routing tables, one for each kind of destination.
#[derive(Default)]
pub(super) struct RoutingTables {
    cidr: RoutingTable<CidrEntry>,
    dns: RoutingTable<DnsEntry>,
    /// Members of static pools.
    peer: RoutingTable<PeerEntry>,
    /// Peers the portal granted through a pool on request.
    granted: RoutingTable<PeerEntry>,
    /// Addresses resolved from device names, reachable once the portal grants them.
    devices: BTreeSet<IpAddr>,
}

impl RoutingTables {
    /// Resolve an outbound packet, preferring direct Clients over Gateway resources.
    pub(super) fn resolve(
        &mut self,
        destination: IpAddr,
        protocol: Protocol,
        internet_resource: Option<ResourceId>,
    ) -> Option<Route> {
        // A static pool member is only ever reached through its pool.
        if let Some(entry) = self.peer.matches(destination, Ok(protocol)).cloned() {
            return Some(Route::Client {
                filter: entry.filter,
                resource_id: entry.resource_id,
            });
        }

        let granted = self.granted.matches(destination, Ok(protocol)).cloned();

        if let Some(entry) = granted
            .as_ref()
            .filter(|entry| entry.filter.apply(Ok(protocol)).is_ok())
        {
            return Some(Route::Client {
                filter: entry.filter.clone(),
                resource_id: entry.resource_id,
            });
        }

        // No grant permits the packet yet; the portal may grant a pool for this protocol.
        if self.devices.contains(&destination) {
            return Some(Route::Device);
        }

        if let Some(entry) = granted {
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

    pub(super) fn upsert_peer(
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
            },
        )
    }

    pub(super) fn upsert_device(&mut self, address: IpAddr) -> bool {
        self.devices.insert(address)
    }

    pub(super) fn upsert_granted(
        &mut self,
        network: IpNetwork,
        resource_id: ResourceId,
        filter: FilterEngine,
    ) -> bool {
        self.granted.upsert(
            network,
            PeerEntry {
                filter,
                resource_id,
            },
        )
    }

    /// Forgets every grant towards `network`, so the next flow asks the portal again.
    pub(super) fn remove_granted(&mut self, network: IpNetwork) {
        self.granted.remove(network, |_| true);
    }

    /// Forgets every grant made through `resource_id`.
    pub(super) fn remove_granted_by_id(&mut self, resource_id: ResourceId) {
        self.granted.remove_by_id(resource_id);
    }

    pub(super) fn remove_by_id(&mut self, resource_id: ResourceId) {
        self.cidr.remove_by_id(resource_id);
        self.dns.remove_by_id(resource_id);
        self.peer.remove_by_id(resource_id);
        self.granted.remove_by_id(resource_id);
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

        assert!(route.is_none());
    }

    #[test]
    fn unresolved_peer_is_unroutable() {
        let mut tables = RoutingTables::default();
        tables.upsert_device(other_client_tun_ip());

        let route = tables.resolve(
            IpAddr::V4(Ipv4Addr::new(100, 64, 0, 4)),
            Protocol::Tcp(80),
            Some(internet_resource_id()),
        );

        assert!(route.is_none());
    }

    #[test]
    fn resolved_device_asks_the_portal_until_granted() {
        let mut tables = RoutingTables::default();
        tables.upsert_device(other_client_tun_ip());

        assert!(matches!(resolve(&mut tables, tcp(80)), Some(Route::Device)));

        grant(&mut tables, dynamic_pool_id(), FilterEngine::PermitAll);

        assert_client_route(resolve(&mut tables, tcp(80)), dynamic_pool_id());
    }

    #[test]
    fn grant_that_does_not_permit_falls_back_to_the_portal() {
        let mut tables = RoutingTables::default();
        tables.upsert_device(other_client_tun_ip());
        grant(&mut tables, dynamic_pool_id(), permit_tcp(22));

        assert_client_route(resolve(&mut tables, tcp(22)), dynamic_pool_id());
        assert!(matches!(resolve(&mut tables, tcp(80)), Some(Route::Device)));
    }

    #[test]
    fn static_pool_member_is_only_reached_through_its_pool() {
        let mut tables = RoutingTables::default();
        tables.upsert_device(other_client_tun_ip());
        member(&mut tables, static_pool_id(), permit_tcp(22));
        grant(&mut tables, dynamic_pool_id(), FilterEngine::PermitAll);

        assert_client_route(resolve(&mut tables, tcp(22)), static_pool_id());
        assert_client_route(resolve(&mut tables, tcp(80)), static_pool_id());
    }

    #[test]
    fn unresolved_static_pool_member_is_rejected_by_its_filter() {
        let mut tables = RoutingTables::default();
        member(&mut tables, static_pool_id(), permit_tcp(22));

        let Some(Route::Client {
            filter,
            resource_id,
        }) = resolve(&mut tables, tcp(80))
        else {
            panic!("expected a client route")
        };
        assert_eq!(resource_id, static_pool_id());
        assert!(filter.apply(Ok(tcp(80))).is_err());
    }

    #[test]
    fn removing_the_pool_drops_its_grants() {
        let mut tables = RoutingTables::default();
        tables.upsert_device(other_client_tun_ip());
        grant(&mut tables, dynamic_pool_id(), FilterEngine::PermitAll);

        tables.remove_by_id(dynamic_pool_id());

        assert!(matches!(resolve(&mut tables, tcp(80)), Some(Route::Device)));
    }

    #[test]
    fn forgetting_the_grant_drops_the_route() {
        let mut tables = RoutingTables::default();
        tables.upsert_device(other_client_tun_ip());
        grant(&mut tables, dynamic_pool_id(), FilterEngine::PermitAll);

        tables.remove_granted(IpNetwork::from(other_client_tun_ip()));

        assert!(matches!(resolve(&mut tables, tcp(80)), Some(Route::Device)));
    }

    fn resolve(tables: &mut RoutingTables, protocol: Protocol) -> Option<Route> {
        tables.resolve(
            other_client_tun_ip(),
            protocol,
            Some(internet_resource_id()),
        )
    }

    fn assert_client_route(route: Option<Route>, expected: ResourceId) {
        let Some(Route::Client { resource_id, .. }) = route else {
            panic!("expected a client route")
        };
        assert_eq!(resource_id, expected);
    }

    fn grant(tables: &mut RoutingTables, pool: ResourceId, filter: FilterEngine) {
        tables.upsert_granted(IpNetwork::from(other_client_tun_ip()), pool, filter);
    }

    fn member(tables: &mut RoutingTables, pool: ResourceId, filter: FilterEngine) {
        tables.upsert_peer(IpNetwork::from(other_client_tun_ip()), pool, filter);
    }

    fn permit_tcp(port: u16) -> FilterEngine {
        use crate::messages::{Filter, PortRange};
        FilterEngine::new(&[Filter::Tcp(PortRange::single(port))])
    }

    fn tcp(port: u16) -> Protocol {
        Protocol::Tcp(port)
    }

    fn other_client_tun_ip() -> IpAddr {
        IpAddr::V4(Ipv4Addr::new(100, 64, 0, 3))
    }

    fn internet_resource_id() -> ResourceId {
        ResourceId::from_u128(1)
    }

    fn static_pool_id() -> ResourceId {
        ResourceId::from_u128(5)
    }

    fn dynamic_pool_id() -> ResourceId {
        ResourceId::from_u128(10)
    }
}
