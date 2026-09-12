use std::{cmp::Ordering, collections::BTreeMap, net::IpAddr};

use connlib_model::ResourceId;
use dns_types::DomainName;
use ip_network::IpNetwork;
use ip_packet::{Protocol, UnsupportedProtocol};

use crate::{
    dns,
    filter_engine::FilterEngine,
    messages::client::Flow,
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

/// What the portal's rule picks for an address among the client's own resources.
pub(super) enum LocalPick {
    Resource {
        filter: FilterEngine,
        resource_id: ResourceId,
    },
    /// Resources cover the address but none permits the flow.
    Refused,
    /// No resource covers the address.
    None,
}

/// The client's routing tables, one for each kind of destination.
#[derive(Default)]
pub(super) struct RoutingTables {
    cidr: RoutingTable<CidrEntry>,
    dns: RoutingTable<DnsEntry>,
    peer: RoutingTable<PeerEntry>,
    /// The Gateway resource the portal picked per address and flow.
    learned: BTreeMap<(IpAddr, Flow), PeerEntry>,
}

impl RoutingTables {
    /// Resolve an outbound packet, preferring direct Clients over Gateway resources.
    ///
    /// `is_authorized` says whether we hold a grant for a resource, `filter_allows` whether
    /// a filter permits the packet.
    pub(super) fn resolve(
        &mut self,
        destination: IpAddr,
        protocol: Protocol,
        internet_resource: Option<ResourceId>,
        is_authorized: impl Fn(ResourceId) -> bool,
        filter_allows: impl Fn(&FilterEngine) -> bool,
    ) -> Option<Route> {
        if let Some(entry) = self.peer.matches(destination, Ok(protocol)).cloned() {
            return Some(Route::Client {
                filter: entry.filter,
                resource_id: entry.resource_id,
            });
        }

        self.resolve_resource(
            destination,
            protocol,
            internet_resource,
            is_authorized,
            filter_allows,
        )
    }

    /// Resolve only resources routed through a Gateway.
    ///
    /// DNS resources route by the proxy address the client handed out. Any other flow
    /// routes through the resource the portal picked for it, see [`RoutingTables::learn`],
    /// else through the one the portal's rule picks among our own resources, see
    /// [`RoutingTables::local_pick`], each only while we hold a grant for it.
    pub(super) fn resolve_resource(
        &mut self,
        destination: IpAddr,
        protocol: Protocol,
        internet_resource: Option<ResourceId>,
        is_authorized: impl Fn(ResourceId) -> bool,
        filter_allows: impl Fn(&FilterEngine) -> bool,
    ) -> Option<Route> {
        if let Some(entry) = self.dns.matches(destination, Ok(protocol)).cloned() {
            return Some(Route::Gateway {
                filter: entry.filter,
                resource_id: entry.resource_id,
                domain: Some(entry.domain),
            });
        }

        if let Some(entry) = self.learned.get(&(destination, Flow::from(protocol)))
            && filter_allows(&entry.filter)
            && is_authorized(entry.resource_id)
        {
            return Some(Route::Gateway {
                filter: entry.filter.clone(),
                resource_id: entry.resource_id,
                domain: None,
            });
        }

        match self.local_pick(destination, protocol, internet_resource, &filter_allows) {
            LocalPick::Resource {
                resource_id,
                filter,
            } if is_authorized(resource_id) => Some(Route::Gateway {
                filter,
                resource_id,
                domain: None,
            }),
            LocalPick::Resource { .. } | LocalPick::Refused | LocalPick::None => None,
        }
    }

    /// The resource the portal's rule picks for `destination` among our own resources: the
    /// most specific CIDR resource permitting the flow, else the Internet Resource.
    ///
    /// Firezone's tunnel range holds Clients and Gateways, so the Internet Resource must
    /// not claim it: letting it would send Client-to-Client traffic to a Gateway, which
    /// hair-pins it back out of its TUN device.
    pub(super) fn local_pick(
        &mut self,
        destination: IpAddr,
        protocol: Protocol,
        internet_resource: Option<ResourceId>,
        filter_allows: impl Fn(&FilterEngine) -> bool,
    ) -> LocalPick {
        if crate::is_peer(destination) {
            return LocalPick::None;
        }

        let internet = |resource_id| LocalPick::Resource {
            resource_id,
            filter: FilterEngine::PermitAll,
        };

        match self.cidr.matches(destination, Ok(protocol)).cloned() {
            Some(entry) if filter_allows(&entry.filter) => LocalPick::Resource {
                resource_id: entry.resource_id,
                filter: entry.filter,
            },
            Some(_) => internet_resource.map_or(LocalPick::Refused, internet),
            None => internet_resource.map_or(LocalPick::None, internet),
        }
    }

    /// Records the portal's pick of `resource_id` for `flow` to `destination`.
    pub(super) fn learn(
        &mut self,
        destination: IpAddr,
        flow: Flow,
        resource_id: ResourceId,
        filter: FilterEngine,
    ) {
        self.learned.insert(
            (destination, flow),
            PeerEntry {
                filter,
                resource_id,
            },
        );
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

    pub(super) fn remove_by_id(&mut self, resource_id: ResourceId) {
        self.cidr.remove_by_id(resource_id);
        self.dns.remove_by_id(resource_id);
        self.peer.remove_by_id(resource_id);
        self.learned
            .retain(|_, entry| entry.resource_id != resource_id);
    }

    pub(super) fn remove_peer(&mut self, network: IpNetwork, resource_id: ResourceId) {
        self.peer
            .remove(network, |entry| entry.resource_id == resource_id);
    }

    /// Drops every pool route to the peer at `network`.
    pub(super) fn remove_peer_routes(&mut self, network: IpNetwork) {
        self.peer.remove(network, |_| true);
    }

    /// Applies a pool's new filters to every peer routed through it.
    pub(super) fn replace_peer_filter(&mut self, resource_id: ResourceId, filter: FilterEngine) {
        self.peer.update_by_id(resource_id, |entry| PeerEntry {
            filter: filter.clone(),
            resource_id: entry.resource_id,
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
            |_| true,
            |_| true,
        );

        assert!(route.is_none());
    }

    #[test]
    fn cidr_resources_route_while_granted() {
        let mut tables = RoutingTables::default();
        let rid = ResourceId::from_u128(3);
        let dst = IpAddr::from(Ipv4Addr::new(10, 1, 2, 3));
        tables.upsert_cidr("10.0.0.0/8".parse().unwrap(), rid, FilterEngine::PermitAll);

        assert!(
            tables
                .resolve(dst, Protocol::Udp(53), None, |_| false, |_| true)
                .is_none()
        );
        assert!(matches!(
            tables.local_pick(dst, Protocol::Udp(53), None, |_| true),
            LocalPick::Resource { resource_id, .. } if resource_id == rid
        ));
        assert!(matches!(
            tables.local_pick(
                IpAddr::from(Ipv4Addr::new(11, 0, 0, 1)),
                Protocol::Udp(53),
                None,
                |_| true
            ),
            LocalPick::None
        ));
        assert!(matches!(
            tables.resolve(dst, Protocol::Udp(53), None, |_| true, |_| true),
            Some(Route::Gateway { resource_id, domain: None, .. }) if resource_id == rid
        ));
    }

    #[test]
    fn learned_pick_routes_its_flow_while_granted() {
        let mut tables = RoutingTables::default();
        let cidr = ResourceId::from_u128(3);
        let picked = ResourceId::from_u128(4);
        let dst = IpAddr::from(Ipv4Addr::new(10, 1, 2, 3));
        tables.upsert_cidr("10.0.0.0/8".parse().unwrap(), cidr, FilterEngine::PermitAll);
        tables.learn(
            dst,
            Flow::from(Protocol::Udp(53)),
            picked,
            FilterEngine::PermitAll,
        );

        assert!(matches!(
            tables.resolve(dst, Protocol::Udp(53), None, |rid| rid == picked, |_| true),
            Some(Route::Gateway { resource_id, domain: None, .. }) if resource_id == picked
        ));
        assert!(
            tables
                .resolve(dst, Protocol::Udp(54), None, |rid| rid == picked, |_| true)
                .is_none()
        );

        tables.remove_by_id(picked);
        assert!(
            tables
                .resolve(dst, Protocol::Udp(53), None, |rid| rid == picked, |_| true)
                .is_none()
        );
    }

    #[test]
    fn dynamic_pool_does_not_claim_unresolved_peer() {
        let mut tables = RoutingTables::default();
        resolve_through_pool(&mut tables, dynamic_pool_id(), FilterEngine::PermitAll);

        let route = tables.resolve(
            IpAddr::V4(Ipv4Addr::new(100, 64, 0, 4)),
            Protocol::Tcp(80),
            Some(internet_resource_id()),
            |_| true,
            |_| true,
        );

        assert!(route.is_none());
    }

    fn resolve_through_pool(tables: &mut RoutingTables, pool: ResourceId, filter: FilterEngine) {
        tables.upsert_peer(IpNetwork::from(other_client_tun_ip()), pool, filter);
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
