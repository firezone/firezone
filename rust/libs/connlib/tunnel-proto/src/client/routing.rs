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
    ResolvedDevice {
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
            Self::Client { resource_id, .. } => *resource_id,
            Self::ResolvedDevice { resource_id, .. } => *resource_id,
            Self::Gateway { resource_id, .. } => *resource_id,
        }
    }
}

/// The client's routing tables, one for each kind of destination.
#[derive(Default)]
pub(super) struct RoutingTables {
    cidr: RoutingTable<CidrEntry>,
    dns: RoutingTable<DnsEntry>,
    client: RoutingTable<ClientEntry>,
    resolved_device: RoutingTable<ResolvedDeviceEntry>,
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
            .resolved_device
            .matches(destination, Ok(protocol))
            .cloned()
        {
            return Some(Route::ResolvedDevice {
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

    /// Returns the Client routed at `destination`.
    ///
    /// Every entry for a device address identifies the same Client, so the protocol used to
    /// select between entries is irrelevant.
    pub(super) fn client_id_by_ip(&mut self, destination: IpAddr) -> Option<ClientId> {
        self.client
            .matches(destination, Ok(Protocol::Tcp(0)))
            .map(|entry| entry.client_id)
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

    pub(super) fn upsert_resolved_device(
        &mut self,
        network: IpNetwork,
        resource_id: ResourceId,
        filter: FilterEngine,
    ) -> bool {
        self.resolved_device.upsert(
            network,
            ResolvedDeviceEntry {
                filter,
                resource_id,
            },
        )
    }

    pub(super) fn remove_by_id(&mut self, resource_id: ResourceId) {
        self.cidr.remove_by_id(resource_id);
        self.dns.remove_by_id(resource_id);
        self.client.remove_by_id(resource_id);
        self.resolved_device.remove_by_id(resource_id);
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
struct ClientEntry {
    filter: FilterEngine,
    resource_id: ResourceId,
    client_id: ClientId,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct ResolvedDeviceEntry {
    filter: FilterEngine,
    resource_id: ResourceId,
}

impl RouteEntry for ResolvedDeviceEntry {
    fn filter(&self) -> &FilterEngine {
        &self.filter
    }

    fn resource_id(&self) -> ResourceId {
        self.resource_id
    }
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

        assert!(matches!(
            route,
            Some(Route::Client {
                client_id: c,
                ..
            }) if c == client_id
        ));
    }

    #[test]
    fn resolved_device_routes_to_an_unknown_client() {
        let mut tables = RoutingTables::default();
        let resource_id = ResourceId::from_u128(2);
        tables.upsert_resolved_device(
            IpNetwork::from(other_client_tun_ip()),
            resource_id,
            FilterEngine::PermitAll,
        );

        let route = tables.resolve(
            other_client_tun_ip(),
            Protocol::Tcp(80),
            Some(internet_resource_id()),
        );

        assert!(matches!(
            route,
            Some(Route::ResolvedDevice {
                resource_id: rid,
                ..
            }) if rid == resource_id
        ));
    }

    fn other_client_tun_ip() -> IpAddr {
        IpAddr::V4(Ipv4Addr::new(100, 64, 0, 3))
    }

    fn internet_resource_id() -> ResourceId {
        ResourceId::from_u128(1)
    }
}
