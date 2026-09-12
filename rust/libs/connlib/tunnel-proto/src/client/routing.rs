use std::{cmp::Ordering, collections::BTreeMap, net::IpAddr, num::NonZeroUsize};

use connlib_model::ResourceId;
use dns_types::DomainName;
use ip_network::IpNetwork;
use ip_packet::{Protocol, UnsupportedProtocol};
use lru::LruCache;

use crate::{
    dns,
    filter_engine::FilterEngine,
    messages::client::DevicePoolMembers,
    routing_table::{RouteEntry, RoutingTable, by_filter},
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
    pools: PoolTable,
}

impl RoutingTables {
    /// Resolve an outbound packet, preferring direct Clients over Gateway resources.
    pub(super) fn resolve(
        &mut self,
        destination: IpAddr,
        protocol: Protocol,
        internet_resource: Option<ResourceId>,
    ) -> Option<Route> {
        if let Some((resource_id, filter)) = self.pools.matches(destination, protocol) {
            return Some(Route::Client {
                filter,
                resource_id,
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

    /// Stores a pool's members and filters; the members route to the pool from now on.
    pub(super) fn upsert_pool(
        &mut self,
        resource_id: ResourceId,
        members: DevicePoolMembers,
        filter: FilterEngine,
    ) {
        self.pools.upsert(resource_id, members, filter);
    }

    /// The pools whose members include `ip`.
    pub(super) fn pools_admitting(&self, ip: IpAddr) -> impl Iterator<Item = ResourceId> + '_ {
        self.pools.admitting(ip)
    }

    pub(super) fn remove_by_id(&mut self, resource_id: ResourceId) {
        self.cidr.remove_by_id(resource_id);
        self.dns.remove_by_id(resource_id);
        self.pools.remove(resource_id);
    }
}

/// The device pools, matched by bitmap membership instead of per-address entries.
///
/// A lookup picks, among the pools whose members include the address, the one whose
/// filter permits the protocol, then the greatest id, the same order the address tables
/// use. Results are cached per address and protocol like the address tables do.
struct PoolTable {
    pools: BTreeMap<ResourceId, PoolEntry>,
    match_cache: LruCache<(IpAddr, Option<Protocol>), Option<(ResourceId, FilterEngine)>>,
}

struct PoolEntry {
    members: DevicePoolMembers,
    filter: FilterEngine,
}

impl Default for PoolTable {
    fn default() -> Self {
        Self {
            pools: BTreeMap::new(),
            match_cache: LruCache::new(NonZeroUsize::new(1024).expect("1024 > 0")),
        }
    }
}

impl PoolTable {
    fn matches(&mut self, ip: IpAddr, protocol: Protocol) -> Option<(ResourceId, FilterEngine)> {
        self.match_cache
            .get_or_insert((ip, Some(protocol)), || {
                self.pools
                    .iter()
                    .filter(|(_, entry)| entry.members.contains(ip))
                    .max_by(|(l_id, l), (r_id, r)| {
                        by_filter(Ok(protocol), &l.filter, &r.filter).then(l_id.cmp(r_id))
                    })
                    .map(|(id, entry)| (*id, entry.filter.clone()))
            })
            .clone()
    }

    fn admitting(&self, ip: IpAddr) -> impl Iterator<Item = ResourceId> + '_ {
        self.pools
            .iter()
            .filter(move |(_, entry)| entry.members.contains(ip))
            .map(|(id, _)| *id)
    }

    fn upsert(&mut self, id: ResourceId, members: DevicePoolMembers, filter: FilterEngine) {
        self.match_cache.clear();
        self.pools.insert(id, PoolEntry { members, filter });
    }

    fn remove(&mut self, id: ResourceId) {
        self.match_cache.clear();
        self.pools.remove(&id);
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
    use roaring::RoaringBitmap;
    use std::net::Ipv4Addr;

    #[test]
    fn internet_resource_does_not_route_to_another_client() {
        let mut tables = RoutingTables::default();

        assert!(
            tables
                .resolve(
                    other_client_tun_ip(),
                    Protocol::Udp(53),
                    Some(internet_resource_id())
                )
                .is_none()
        );
    }

    #[test]
    fn pool_routes_its_members_by_filter_then_id() {
        let mut tables = RoutingTables::default();
        let ssh = ResourceId::from_u128(1);
        let all = ResourceId::from_u128(2);
        tables.upsert_pool(
            ssh,
            members([other_client_tun_ip()]),
            FilterEngine::new(&[crate::messages::Filter::Tcp(
                crate::messages::PortRange::single(22),
            )]),
        );
        tables.upsert_pool(
            all,
            members([other_client_tun_ip()]),
            FilterEngine::PermitAll,
        );

        assert!(matches!(
            tables.resolve(other_client_tun_ip(), Protocol::Udp(53), None),
            Some(Route::Client { resource_id, .. }) if resource_id == all
        ));
        assert!(matches!(
            tables.resolve(other_client_tun_ip(), Protocol::Tcp(22), None),
            Some(Route::Client { resource_id, .. }) if resource_id == all
        ));
        assert!(
            tables
                .resolve(
                    Ipv4Addr::new(100, 64, 0, 99).into(),
                    Protocol::Tcp(22),
                    None
                )
                .is_none()
        );
    }

    #[test]
    fn removing_a_pool_forgets_its_members() {
        let mut tables = RoutingTables::default();
        let pool = ResourceId::from_u128(1);
        tables.upsert_pool(
            pool,
            members([other_client_tun_ip()]),
            FilterEngine::PermitAll,
        );
        tables.remove_by_id(pool);

        assert!(
            tables
                .resolve(other_client_tun_ip(), Protocol::Udp(53), None)
                .is_none()
        );
    }

    fn members(ips: impl IntoIterator<Item = IpAddr>) -> DevicePoolMembers {
        let mut members = DevicePoolMembers::default();

        for ip in ips {
            match ip {
                IpAddr::V4(ip) => {
                    members
                        .ipv4
                        .insert(crate::messages::client::tunnel_offset_v4(ip).unwrap());
                }
                IpAddr::V6(ip) => {
                    members
                        .ipv6
                        .insert(crate::messages::client::tunnel_offset_v6(ip).unwrap());
                }
            }
        }

        let _ = RoaringBitmap::new();
        members
    }

    fn other_client_tun_ip() -> IpAddr {
        Ipv4Addr::new(100, 64, 0, 2).into()
    }

    fn internet_resource_id() -> ResourceId {
        ResourceId::from_u128(9)
    }
}
