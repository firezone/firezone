use std::{cmp::Ordering, net::IpAddr};

use connlib_model::ResourceId;
use dns_types::DomainName;
use ip_network::IpNetwork;
use ip_packet::{Protocol, UnsupportedProtocol};

use crate::{
    dns,
    filter_engine::FilterEngine,
    routing_table::{FilterMode, RouteEntry, RoutingTable},
};

/// The matching outbound routes for one kind of destination.
pub(super) enum MatchedRoutes {
    DevicePools(Vec<ResourceId>),
    Gateways(Vec<GatewayRoute>),
}

impl MatchedRoutes {
    pub fn is_empty(&self) -> bool {
        match self {
            Self::DevicePools(resources) => resources.is_empty(),
            Self::Gateways(routes) => routes.is_empty(),
        }
    }
}

pub(super) struct GatewayRoute {
    pub(super) resource_id: ResourceId,
    pub(super) domain: Option<DomainName>,
}

#[derive(Debug)]
pub(super) struct Denied;

/// The client's routing tables, one for each kind of destination.
#[derive(Default)]
pub(super) struct RoutingTables {
    cidr: RoutingTable<CidrEntry>,
    dns: RoutingTable<DnsEntry>,
    device_pool: RoutingTable<DevicePoolEntry>,
}

impl RoutingTables {
    /// Resolves outbound traffic, preferring device pools over gateway resources.
    pub(super) fn resolve(
        &mut self,
        destination: IpAddr,
        protocol: Protocol,
        internet_resource: Option<ResourceId>,
    ) -> Result<MatchedRoutes, Denied> {
        let mode = outbound_filter_mode();
        if let Some(pools) = self.device_pool.matches(destination, Ok(protocol), mode) {
            let resources = routes(pools, |entry| entry.resource_id)?;
            return Ok(MatchedRoutes::DevicePools(resources));
        }

        let routes =
            self.resolve_filtered_resource(destination, protocol, internet_resource, mode)?;
        Ok(MatchedRoutes::Gateways(routes))
    }

    /// Resolves resources routed through a gateway.
    #[cfg(feature = "telemetry")]
    pub(super) fn resolve_resource(
        &mut self,
        destination: IpAddr,
        protocol: Protocol,
        internet_resource: Option<ResourceId>,
    ) -> Result<Vec<GatewayRoute>, Denied> {
        let routes = self.resolve_filtered_resource(
            destination,
            protocol,
            internet_resource,
            outbound_filter_mode(),
        );
        let routes = routes?;
        Ok(routes)
    }

    fn resolve_filtered_resource(
        &mut self,
        destination: IpAddr,
        protocol: Protocol,
        internet_resource: Option<ResourceId>,
        mode: FilterMode,
    ) -> Result<Vec<GatewayRoute>, Denied> {
        if let Some(dns) = self.dns.matches(destination, Ok(protocol), mode) {
            return routes(dns, |entry| GatewayRoute {
                resource_id: entry.resource_id,
                domain: Some(entry.domain.clone()),
            });
        }

        if let Some(cidr) = self.cidr.matches(destination, Ok(protocol), mode) {
            return routes(cidr, |entry| GatewayRoute {
                resource_id: entry.resource_id,
                domain: None,
            });
        }

        Ok(internet_route(destination, internet_resource))
    }

    pub(super) fn cidr_networks(&self) -> impl Iterator<Item = IpNetwork> + '_ {
        self.cidr.networks()
    }

    pub(super) fn dns_resources(
        &mut self,
        destination: IpAddr,
        protocol: Result<Protocol, UnsupportedProtocol>,
    ) -> Vec<(ResourceId, DomainName)> {
        self.dns
            .matches(destination, protocol, outbound_filter_mode())
            .into_iter()
            .flatten()
            .map(|entry| (entry.resource_id, entry.domain.clone()))
            .collect()
    }

    pub(super) fn has_cidr_route(&mut self, destination: IpAddr, protocol: Protocol) -> bool {
        self.cidr
            .matches(destination, Ok(protocol), FilterMode::Apply)
            .is_some()
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
        self.device_pool.remove_by_id(resource_id);
        for network in [crate::IPV4_TUNNEL.into(), crate::IPV6_TUNNEL.into()] {
            self.device_pool.upsert(
                network,
                DevicePoolEntry {
                    resource_id,
                    filter: filter.clone(),
                },
            );
        }
    }

    pub(super) fn remove_by_id(&mut self, resource_id: ResourceId) {
        self.cidr.remove_by_id(resource_id);
        self.dns.remove_by_id(resource_id);
        self.device_pool.remove_by_id(resource_id);
    }
}

fn routes<T, R>(matches: &[T], to_route: impl Fn(&T) -> R) -> Result<Vec<R>, Denied> {
    let routes = matches.iter().map(to_route).collect::<Vec<_>>();
    if routes.is_empty() {
        return Err(Denied);
    }

    Ok(routes)
}

fn outbound_filter_mode() -> FilterMode {
    #[cfg(any(test, feature = "malicious-behaviour"))]
    if crate::malicious_behaviour::ignore_resource_filter() {
        return FilterMode::Ignore;
    }

    FilterMode::Apply
}

fn internet_route(destination: IpAddr, internet_resource: Option<ResourceId>) -> Vec<GatewayRoute> {
    // The Internet Resource must not send tunnel addresses to a gateway.
    if crate::is_peer(destination) {
        return Vec::new();
    }

    internet_resource
        .into_iter()
        .map(|resource_id| GatewayRoute {
            resource_id,
            domain: None,
        })
        .collect()
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
                .resolve(ip.parse().unwrap(), Protocol::Tcp(80), None)
                .unwrap();
            assert_eq!(routes.resource_ids(), vec![pool_id()]);
        }
        assert!(
            tables
                .resolve("100.96.0.4".parse().unwrap(), Protocol::Tcp(80), None)
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
                .resolve(destination, Protocol::Tcp(80), Some(internet_resource_id()))
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
                .resolve(destination, Protocol::Tcp(80), Some(internet_resource_id()))
                .is_err()
        );

        tables.remove_by_id(dns_id);
        tables.upsert_pool(pool_id(), FilterEngine::DenyAll);
        assert!(
            tables
                .resolve(destination, Protocol::Tcp(80), Some(internet_resource_id()))
                .is_err()
        );
    }

    #[test_case::test_case("pool"; "device_pool")]
    #[test_case::test_case("cidr"; "cidr_resource")]
    #[test_case::test_case("dns"; "dns_resource")]
    fn filter_mode_selects_candidates_before_sorting(resource_kind: &str) {
        let mut tables = RoutingTables::default();
        let allowed = ResourceId::from_u128(1);
        let denied = ResourceId::from_u128(2);
        let destination = match resource_kind {
            "pool" => other_client_tun_ip(),
            "cidr" => "10.0.0.1".parse::<IpAddr>().unwrap(),
            "dns" => "100.96.0.1".parse::<IpAddr>().unwrap(),
            _ => unreachable!(),
        };
        for (resource_id, filter) in [
            (allowed, FilterEngine::PermitAll),
            (denied, FilterEngine::DenyAll),
        ] {
            match resource_kind {
                "pool" => tables.upsert_pool(resource_id, filter),
                "cidr" => {
                    tables.upsert_cidr(destination.into(), resource_id, filter);
                }
                "dns" => {
                    tables.upsert_dns(
                        destination.into(),
                        resource_id,
                        "example.com".parse().unwrap(),
                        dns::Pattern::new("example.com").unwrap(),
                        filter,
                    );
                }
                _ => unreachable!(),
            }
        }

        let routes = tables
            .resolve(destination, Protocol::Tcp(80), Some(internet_resource_id()))
            .unwrap();
        assert_eq!(routes.resource_ids(), vec![allowed]);

        let _guard = crate::malicious_behaviour::MaliciousBehaviour {
            ignore_resource_filters: true,
            ..Default::default()
        }
        .guard();
        let routes = tables
            .resolve(destination, Protocol::Tcp(80), Some(internet_resource_id()))
            .unwrap();
        assert_eq!(routes.resource_ids(), vec![denied, allowed]);

        tables.remove_by_id(allowed);
        let routes = tables
            .resolve(destination, Protocol::Tcp(80), Some(internet_resource_id()))
            .unwrap();
        assert_eq!(routes.resource_ids(), vec![denied]);
    }

    #[test]
    fn malicious_filter_mode_preserves_internet_fallback() {
        let mut tables = RoutingTables::default();
        let _guard = crate::malicious_behaviour::MaliciousBehaviour {
            ignore_resource_filters: true,
            ..Default::default()
        }
        .guard();
        let routes = tables
            .resolve(
                "1.1.1.1".parse().unwrap(),
                Protocol::Tcp(443),
                Some(internet_resource_id()),
            )
            .unwrap();
        assert_eq!(routes.resource_ids(), vec![internet_resource_id()]);
        assert!(
            tables
                .resolve("1.1.1.1".parse().unwrap(), Protocol::Tcp(443), None)
                .unwrap()
                .is_empty()
        );
        assert!(
            tables
                .resolve(
                    other_client_tun_ip(),
                    Protocol::Tcp(443),
                    Some(internet_resource_id())
                )
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn dns_resources_return_ordered_filter_candidates() {
        let mut tables = RoutingTables::default();
        let destination = "100.96.0.4".parse::<IpAddr>().unwrap();
        let domain = "example.com".parse::<DomainName>().unwrap();
        let a = ResourceId::from_u128(2);
        let b = ResourceId::from_u128(1);
        for resource in [a, b] {
            tables.upsert_dns(
                destination.into(),
                resource,
                domain.clone(),
                dns::Pattern::new("example.com").unwrap(),
                FilterEngine::PermitAll,
            );
        }

        assert_eq!(
            tables.dns_resources(destination, Ok(Protocol::Tcp(80))),
            vec![(a, domain.clone()), (b, domain.clone())]
        );

        tables.remove_by_id(b);
        tables.upsert_dns(
            destination.into(),
            b,
            domain.clone(),
            dns::Pattern::new("example.com").unwrap(),
            FilterEngine::DenyAll,
        );
        assert_eq!(
            tables.dns_resources(destination, Ok(Protocol::Tcp(80))),
            vec![(a, domain.clone())]
        );

        let _guard = crate::malicious_behaviour::MaliciousBehaviour {
            ignore_resource_filters: true,
            ..Default::default()
        }
        .guard();
        assert_eq!(
            tables.dns_resources(destination, Ok(Protocol::Tcp(80))),
            vec![(b, domain.clone()), (a, domain)]
        );
    }

    impl MatchedRoutes {
        fn resource_ids(&self) -> Vec<ResourceId> {
            match self {
                Self::DevicePools(resources) => resources.clone(),
                Self::Gateways(routes) => routes.iter().map(|route| route.resource_id).collect(),
            }
        }
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
