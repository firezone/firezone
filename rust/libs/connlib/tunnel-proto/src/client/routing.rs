use std::{cmp::Ordering, net::IpAddr};

use connlib_model::{ClientId, ResourceId};
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
        client_id: ClientId,
    },
    /// An address a dynamic pool resolved a name to; the portal decides access on first use.
    DevicePool {
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
            Self::Client { resource_id, .. }
            | Self::DevicePool { resource_id, .. }
            | Self::Gateway { resource_id, .. } => *resource_id,
        }
    }
}

/// The client's routing tables, one for each kind of destination.
#[derive(Default)]
pub(super) struct RoutingTables {
    cidr: RoutingTable<CidrEntry>,
    dns: RoutingTable<DnsEntry>,
    client: RoutingTable<ClientEntry>,
    /// Peers reached through a dynamic pool, entered once the portal authorised them.
    dynamic_client: RoutingTable<ClientEntry>,
    /// Addresses a dynamic pool resolved a name to, entered before any authorisation.
    dynamic_pool: RoutingTable<DevicePoolEntry>,
}

impl RoutingTables {
    /// Resolve an outbound packet, preferring direct Clients over Gateway resources.
    pub(super) fn resolve(
        &mut self,
        destination: IpAddr,
        protocol: Protocol,
        internet_resource: Option<ResourceId>,
    ) -> Option<Route> {
        if let Some(entry) = self.client.matches(destination, Ok(protocol)).cloned() {
            return Some(Route::Client {
                filter: entry.filter,
                resource_id: entry.resource_id,
                client_id: entry.client_id,
            });
        }

        if let Some(entry) = self
            .dynamic_client
            .matches(destination, Ok(protocol))
            .cloned()
        {
            let permitted = entry.filter.apply(Ok(protocol)).is_ok();
            let route = Route::Client {
                filter: entry.filter,
                resource_id: entry.resource_id,
                client_id: entry.client_id,
            };

            if permitted {
                return Some(route);
            }

            // Another pool that resolved this peer may permit what the granting one does not.
            return Some(
                self.permitting_device_pool_route(destination, protocol)
                    .unwrap_or(route),
            );
        }

        if let Some(route) = self.resolve_resource(destination, protocol, internet_resource) {
            return Some(route);
        }

        self.device_pool_route(destination, protocol)
    }

    /// The dynamic pool that resolved `destination`, if any.
    ///
    /// A pool whose filter permits the packet wins. When none does, one is returned anyway
    /// so the caller rejects the packet through that pool's filter.
    fn device_pool_route(&mut self, destination: IpAddr, protocol: Protocol) -> Option<Route> {
        let entry = self.dynamic_pool.matches(destination, Ok(protocol))?;

        Some(Route::DevicePool {
            filter: entry.filter.clone(),
            resource_id: entry.resource_id,
        })
    }

    fn permitting_device_pool_route(
        &mut self,
        destination: IpAddr,
        protocol: Protocol,
    ) -> Option<Route> {
        let route = self.device_pool_route(destination, protocol)?;

        if let Route::DevicePool { filter, .. } = &route
            && filter.apply(Ok(protocol)).is_err()
        {
            return None;
        }

        Some(route)
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

    /// Returns the Client routed at `destination`.
    ///
    /// Every entry for a device address identifies the same Client, so the protocol used to
    /// select between entries is irrelevant.
    pub(super) fn client_id_by_ip(&mut self, destination: IpAddr) -> Option<ClientId> {
        let protocol = Ok(Protocol::Tcp(0));

        self.client
            .matches(destination, protocol.clone())
            .map(|entry| entry.client_id)
            .or_else(|| {
                self.dynamic_client
                    .matches(destination, protocol)
                    .map(|entry| entry.client_id)
            })
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

    pub(super) fn upsert_client(
        &mut self,
        network: IpNetwork,
        resource_id: ResourceId,
        client_id: ClientId,
        filter: FilterEngine,
    ) -> bool {
        self.client.upsert(
            network,
            ClientEntry {
                filter,
                resource_id,
                client_id,
            },
        )
    }

    pub(super) fn upsert_device_pool_address(
        &mut self,
        network: IpNetwork,
        resource_id: ResourceId,
        filter: FilterEngine,
    ) -> bool {
        self.dynamic_pool.upsert(
            network,
            DevicePoolEntry {
                filter,
                resource_id,
            },
        )
    }

    pub(super) fn upsert_dynamic_client(
        &mut self,
        network: IpNetwork,
        resource_id: ResourceId,
        client_id: ClientId,
        filter: FilterEngine,
    ) -> bool {
        self.dynamic_client.upsert(
            network,
            ClientEntry {
                filter,
                resource_id,
                client_id,
            },
        )
    }

    pub(super) fn remove_by_id(&mut self, resource_id: ResourceId) {
        self.cidr.remove_by_id(resource_id);
        self.dns.remove_by_id(resource_id);
        self.client.remove_by_id(resource_id);
        self.dynamic_client.remove_by_id(resource_id);
        self.dynamic_pool.remove_by_id(resource_id);
    }

    pub(super) fn remove_client(
        &mut self,
        network: IpNetwork,
        client_id: ClientId,
        resource_id: ResourceId,
    ) {
        self.client.remove(network, |entry| {
            entry.client_id == client_id && entry.resource_id == resource_id
        });
    }

    /// Forgets every dynamic pool route to `client_id`, for one pool or all of them.
    pub(super) fn remove_dynamic_client(
        &mut self,
        client_id: ClientId,
        resource_id: Option<ResourceId>,
    ) {
        self.dynamic_client.remove_if(|entry| {
            entry.client_id == client_id && resource_id.is_none_or(|rid| entry.resource_id == rid)
        });
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
struct DevicePoolEntry {
    filter: FilterEngine,
    resource_id: ResourceId,
}

impl RouteEntry for DevicePoolEntry {
    fn filter(&self) -> &FilterEngine {
        &self.filter
    }

    fn resource_id(&self) -> ResourceId {
        self.resource_id
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct ClientEntry {
    filter: FilterEngine,
    resource_id: ResourceId,
    client_id: ClientId,
}

impl RouteEntry for ClientEntry {
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
        let client_id = ClientId::from_u128(3);
        tables.upsert_client(
            IpNetwork::from(other_client_tun_ip()),
            ResourceId::from_u128(2),
            client_id,
            FilterEngine::PermitAll,
        );

        let route = tables.resolve(
            other_client_tun_ip(),
            Protocol::Tcp(80),
            Some(internet_resource_id()),
        );

        assert!(matches!(route, Some(Route::Client { client_id: c, .. }) if c == client_id));
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
            Some(Route::DevicePool { resource_id, .. }) if resource_id == dynamic_pool_id()
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
    fn static_pool_route_wins_over_dynamic_pool() {
        let mut tables = RoutingTables::default();
        let client_id = ClientId::from_u128(3);
        resolve_through_pool(&mut tables, dynamic_pool_id(), FilterEngine::PermitAll);
        tables.upsert_client(
            IpNetwork::from(other_client_tun_ip()),
            ResourceId::from_u128(2),
            client_id,
            FilterEngine::new(&[Filter::Icmp]),
        );

        let route = tables.resolve(
            other_client_tun_ip(),
            Protocol::Tcp(80),
            Some(internet_resource_id()),
        );

        assert!(matches!(
            route,
            Some(Route::Client { client_id: c, resource_id, .. })
                if c == client_id && resource_id == ResourceId::from_u128(2)
        ));
    }

    #[test]
    fn dynamic_pool_prefers_the_pool_whose_filter_permits() {
        let mut tables = RoutingTables::default();
        let icmp_pool = ResourceId::from_u128(20);
        let tcp_pool = ResourceId::from_u128(21);
        resolve_through_pool(&mut tables, icmp_pool, FilterEngine::new(&[Filter::Icmp]));
        resolve_through_pool(
            &mut tables,
            tcp_pool,
            FilterEngine::new(&[Filter::Tcp(PortRange::single(80))]),
        );

        let tcp = tables.resolve(other_client_tun_ip(), Protocol::Tcp(80), None);
        let udp = tables.resolve(other_client_tun_ip(), Protocol::Udp(53), None);

        assert!(matches!(
            tcp,
            Some(Route::DevicePool { resource_id, .. }) if resource_id == tcp_pool
        ));
        assert!(matches!(
            udp,
            Some(Route::DevicePool { filter, .. }) if filter.apply(Ok(Protocol::Udp(53))).is_err()
        ));
    }

    #[test]
    fn authorised_dynamic_peer_routes_directly() {
        let mut tables = RoutingTables::default();
        let client_id = ClientId::from_u128(3);
        resolve_through_pool(&mut tables, dynamic_pool_id(), FilterEngine::PermitAll);
        tables.upsert_dynamic_client(
            IpNetwork::from(other_client_tun_ip()),
            dynamic_pool_id(),
            client_id,
            FilterEngine::PermitAll,
        );

        let route = tables.resolve(other_client_tun_ip(), Protocol::Tcp(80), None);

        assert!(matches!(
            route,
            Some(Route::Client { client_id: c, resource_id, .. })
                if c == client_id && resource_id == dynamic_pool_id()
        ));
        assert_eq!(
            tables.client_id_by_ip(other_client_tun_ip()),
            Some(client_id)
        );
    }

    #[test]
    fn authorised_dynamic_peer_defers_to_another_pool_that_permits() {
        let mut tables = RoutingTables::default();
        let client_id = ClientId::from_u128(3);
        let icmp_pool = ResourceId::from_u128(20);
        let tcp_pool = ResourceId::from_u128(21);
        resolve_through_pool(&mut tables, icmp_pool, FilterEngine::new(&[Filter::Icmp]));
        resolve_through_pool(
            &mut tables,
            tcp_pool,
            FilterEngine::new(&[Filter::Tcp(PortRange::single(80))]),
        );
        tables.upsert_dynamic_client(
            IpNetwork::from(other_client_tun_ip()),
            icmp_pool,
            client_id,
            FilterEngine::new(&[Filter::Icmp]),
        );

        let tcp = tables.resolve(other_client_tun_ip(), Protocol::Tcp(80), None);
        let udp = tables.resolve(other_client_tun_ip(), Protocol::Udp(53), None);

        assert!(matches!(
            tcp,
            Some(Route::DevicePool { resource_id, .. }) if resource_id == tcp_pool
        ));
        assert!(matches!(
            udp,
            Some(Route::Client { client_id: c, resource_id, .. })
                if c == client_id && resource_id == icmp_pool
        ));
    }

    #[test]
    fn authorised_dynamic_peer_keeps_its_route_when_no_pool_permits() {
        let mut tables = RoutingTables::default();
        let client_id = ClientId::from_u128(3);
        resolve_through_pool(
            &mut tables,
            dynamic_pool_id(),
            FilterEngine::new(&[Filter::Icmp]),
        );
        tables.upsert_dynamic_client(
            IpNetwork::from(other_client_tun_ip()),
            dynamic_pool_id(),
            client_id,
            FilterEngine::new(&[Filter::Icmp]),
        );

        let route = tables.resolve(other_client_tun_ip(), Protocol::Tcp(80), None);

        assert!(matches!(
            route,
            Some(Route::Client { client_id: c, filter, .. })
                if c == client_id && filter.apply(Ok(Protocol::Tcp(80))).is_err()
        ));
    }

    #[test]
    fn forgetting_a_dynamic_peer_falls_back_to_the_pool() {
        let mut tables = RoutingTables::default();
        let client_id = ClientId::from_u128(3);
        resolve_through_pool(&mut tables, dynamic_pool_id(), FilterEngine::PermitAll);
        tables.upsert_dynamic_client(
            IpNetwork::from(other_client_tun_ip()),
            dynamic_pool_id(),
            client_id,
            FilterEngine::PermitAll,
        );

        tables.remove_dynamic_client(client_id, None);

        let route = tables.resolve(other_client_tun_ip(), Protocol::Tcp(80), None);

        assert!(matches!(route, Some(Route::DevicePool { .. })));
        assert_eq!(tables.client_id_by_ip(other_client_tun_ip()), None);
    }

    #[test]
    fn removing_the_pool_drops_its_peers_and_resolutions() {
        let mut tables = RoutingTables::default();
        resolve_through_pool(&mut tables, dynamic_pool_id(), FilterEngine::PermitAll);
        tables.upsert_dynamic_client(
            IpNetwork::from(other_client_tun_ip()),
            dynamic_pool_id(),
            ClientId::from_u128(3),
            FilterEngine::PermitAll,
        );

        tables.remove_by_id(dynamic_pool_id());

        let route = tables.resolve(other_client_tun_ip(), Protocol::Tcp(80), None);

        assert!(route.is_none());
    }

    fn resolve_through_pool(tables: &mut RoutingTables, pool: ResourceId, filter: FilterEngine) {
        tables.upsert_device_pool_address(IpNetwork::from(other_client_tun_ip()), pool, filter);
    }

    fn other_client_tun_ip() -> IpAddr {
        IpAddr::V4(Ipv4Addr::new(100, 64, 0, 3))
    }

    fn internet_resource_id() -> ResourceId {
        ResourceId::from_u128(1)
    }

    fn dynamic_pool_id() -> ResourceId {
        ResourceId::from_u128(10)
    }
}
