use std::{cmp::Ordering, net::IpAddr};

use connlib_model::ResourceId;
use dns_types::DomainName;
use ip_network::IpNetwork;
use ip_packet::{Protocol, UnsupportedProtocol};

use crate::{
    dns,
    filter_engine::FilterEngine,
    routing_table::{Matches, RouteEntry, RoutingTable},
};

/// The result of applying all Client routing tables to an outbound packet.
#[derive(Clone)]
pub(super) enum Route {
    Client {
        resource_id: ResourceId,
    },
    Gateway {
        resource_id: ResourceId,
        domain: Option<DomainName>,
    },
}

impl Route {
    pub(super) fn resource_id(&self) -> ResourceId {
        match self {
            Self::Client { resource_id } => *resource_id,
            Self::Gateway { resource_id, .. } => *resource_id,
        }
    }
}

#[derive(Debug)]
pub(super) struct Denied;

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
        is_authorized: impl Fn(ResourceId) -> bool,
    ) -> Result<Vec<Route>, Denied> {
        if let Some(peers) = self.peer.matches(destination, Ok(protocol)) {
            return allowed_routes(
                peers,
                |entry| is_authorized(entry.resource_id),
                |entry| Route::Client {
                    resource_id: entry.resource_id,
                },
            );
        }

        let routes = self.resolve_resource(destination, protocol, internet_resource)?;
        Ok(routes)
    }

    /// Resolves resources routed through a gateway.
    pub(super) fn resolve_resource(
        &mut self,
        destination: IpAddr,
        protocol: Protocol,
        internet_resource: Option<ResourceId>,
    ) -> Result<Vec<Route>, Denied> {
        if let Some(dns) = self.dns.matches(destination, Ok(protocol)) {
            return allowed_routes(
                dns,
                |_| true,
                |entry| Route::Gateway {
                    resource_id: entry.resource_id,
                    domain: Some(entry.domain.clone()),
                },
            );
        }

        if let Some(cidr) = self.cidr.matches(destination, Ok(protocol)) {
            return allowed_routes(
                cidr,
                |_| true,
                |entry| Route::Gateway {
                    resource_id: entry.resource_id,
                    domain: None,
                },
            );
        }

        // The Internet Resource must not send tunnel addresses to a gateway.
        if crate::is_peer(destination) {
            return Ok(Vec::new());
        }

        Ok(internet_resource
            .into_iter()
            .map(|resource_id| Route::Gateway {
                resource_id,
                domain: None,
            })
            .collect())
    }

    pub(super) fn cidr_networks(&self) -> impl Iterator<Item = IpNetwork> + '_ {
        self.cidr.networks()
    }

    pub(super) fn dns_resource(
        &mut self,
        destination: IpAddr,
        protocol: Result<Protocol, UnsupportedProtocol>,
    ) -> Option<(ResourceId, DomainName)> {
        let matches = self.dns.matches(destination, protocol)?;
        allowed_routes(
            matches,
            |_| true,
            |entry| (entry.resource_id, entry.domain.clone()),
        )
        .ok()?
        .into_iter()
        .next()
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

/// Only outbound routing may bypass filters to exercise remote enforcement in simulations.
fn allowed_routes<T, R>(
    matches: &Matches<T>,
    can_bypass: impl Fn(&T) -> bool,
    to_route: impl Fn(&T) -> R,
) -> Result<Vec<R>, Denied> {
    let routes = matches.allowed.iter();
    #[cfg(any(test, feature = "malicious-behaviour"))]
    let routes =
        routes.chain(matches.denied.iter().filter(|entry| {
            crate::malicious_behaviour::ignore_resource_filter() && can_bypass(entry)
        }));
    #[cfg(not(any(test, feature = "malicious-behaviour")))]
    let _ = can_bypass;

    let routes = routes.map(to_route).collect::<Vec<_>>();
    if routes.is_empty() {
        return Err(Denied);
    }

    Ok(routes)
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

        let route = tables
            .resolve(
                other_client_tun_ip(),
                Protocol::Tcp(80),
                Some(internet_resource_id()),
                |_| false,
            )
            .unwrap();

        assert!(route.is_empty());
    }

    #[test]
    fn pool_routes_cover_both_tunnel_ranges() {
        let mut tables = RoutingTables::default();
        tables.upsert_pool(pool_id(), FilterEngine::PermitAll);

        for ip in ["100.64.0.4", "100.95.255.254", "fd00:2021:1111::4"] {
            let routes = tables
                .resolve(ip.parse().unwrap(), Protocol::Tcp(80), None, |_| false)
                .unwrap();
            assert_eq!(
                routes.iter().map(Route::resource_id).collect::<Vec<_>>(),
                vec![pool_id()]
            );
        }
        assert!(
            tables
                .resolve(
                    "100.96.0.4".parse().unwrap(),
                    Protocol::Tcp(80),
                    None,
                    |_| false
                )
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn denied_routes_do_not_fall_through_to_other_resource_types() {
        let mut tables = RoutingTables::default();
        let destination = other_client_tun_ip();
        let cidr_id = ResourceId::from_u128(2);
        let dns_id = ResourceId::from_u128(3);
        tables.upsert_cidr(destination.into(), cidr_id, FilterEngine::DenyAll);
        assert!(
            tables
                .resolve(
                    destination,
                    Protocol::Tcp(80),
                    Some(internet_resource_id()),
                    |_| false
                )
                .is_err()
        );

        tables.remove_by_id(cidr_id);
        tables.upsert_cidr(destination.into(), cidr_id, FilterEngine::PermitAll);
        tables.upsert_dns(
            destination.into(),
            dns_id,
            "example.com".parse().unwrap(),
            dns::Pattern::new("example.com").unwrap(),
            FilterEngine::DenyAll,
        );
        assert!(
            tables
                .resolve(
                    destination,
                    Protocol::Tcp(80),
                    Some(internet_resource_id()),
                    |_| false
                )
                .is_err()
        );

        tables.remove_by_id(dns_id);
        tables.upsert_pool(pool_id(), FilterEngine::DenyAll);
        assert!(
            tables
                .resolve(
                    destination,
                    Protocol::Tcp(80),
                    Some(internet_resource_id()),
                    |_| false
                )
                .is_err()
        );
    }

    #[test]
    fn malicious_pool_filter_bypass_requires_an_existing_grant() {
        let mut tables = RoutingTables::default();
        tables.upsert_pool(pool_id(), FilterEngine::DenyAll);
        let _guard = crate::malicious_behaviour::MaliciousBehaviour {
            ignore_resource_filters: true,
            ..Default::default()
        }
        .guard();

        assert!(
            tables
                .resolve(other_client_tun_ip(), Protocol::Tcp(80), None, |_| false)
                .is_err()
        );
        let routes = tables
            .resolve(other_client_tun_ip(), Protocol::Tcp(80), None, |id| {
                id == pool_id()
            })
            .unwrap();
        assert_eq!(
            routes.iter().map(Route::resource_id).collect::<Vec<_>>(),
            vec![pool_id()]
        );
        assert!(
            tables
                .peer
                .matches(other_client_tun_ip(), Ok(Protocol::Tcp(80)))
                .unwrap()
                .allowed
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
