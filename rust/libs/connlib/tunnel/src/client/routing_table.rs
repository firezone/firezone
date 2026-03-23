use std::{cmp::Ordering, collections::BTreeSet, net::IpAddr};

use connlib_model::ResourceId;
use dns_types::DomainName;
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;

#[derive(Debug, Default)]
pub(crate) struct RoutingTable {
    cidr: IpNetworkTable<BTreeSet<ResourceId>>,
    dns: IpNetworkTable<BTreeSet<(ResourceId, DomainName)>>,
}

impl RoutingTable {
    /// Adds a new entry to the CIDR resource routing table.
    ///
    /// Returns `true` if the resource wasn't present before.
    pub fn upsert_cidr(&mut self, network: IpNetwork, resource: ResourceId) -> bool {
        upsert(&mut self.cidr, network, resource)
    }

    /// Adds a new entry to the DNS resource routing table.
    ///
    /// Returns `true` if the resource wasn't present before.
    pub fn upsert_dns(&mut self, ip: IpAddr, resource: ResourceId, domain: DomainName) -> bool {
        upsert(&mut self.dns, ip.into(), (resource, domain))
    }

    /// Finds the CIDR resource to which traffic to a certain IP should be routed.
    ///
    /// In case more than one resource is associated with this IP, the `tie_breaker` function is used to order them.
    /// The one with the _greatest_ ordering is returned.
    pub fn matches_cidr(
        &self,
        ip: IpAddr,
        tie_breaker: impl Fn(ResourceId, ResourceId) -> Ordering,
    ) -> Option<ResourceId> {
        let (_, resources) = self.cidr.longest_match(ip)?;

        let id = resources
            .iter()
            .copied()
            .max_by(|left, right| tie_breaker(*left, *right).then(left.cmp(right)))?;

        Some(id)
    }

    /// Finds the DNS resource to which traffic to a certain IP should be routed.
    ///
    /// In case more than one resource is associated with this IP, the `tie_breaker` function is used to order them.
    /// The one with the _greatest_ ordering is returned.
    pub fn matches_dns(
        &self,
        ip: IpAddr,
        tie_breaker: impl Fn(ResourceId, ResourceId) -> Ordering,
    ) -> Option<(ResourceId, &DomainName)> {
        let (_, resources) = self.dns.longest_match(ip)?;
        let (id, domain) = resources
            .iter()
            .max_by(|(left, _), (right, _)| tie_breaker(*left, *right).then(left.cmp(right)))?;

        Some((*id, domain))
    }

    pub fn any_cidr(&self, ip: IpAddr) -> bool {
        self.cidr
            .longest_match(ip)
            .is_some_and(|(_, r)| !r.is_empty())
    }

    pub fn remove_by_resource(&mut self, resource: ResourceId) {
        remove_by_resource(&mut self.cidr, |c| c == &resource);
        remove_by_resource(&mut self.dns, |(c, _)| c == &resource);
    }

    pub fn cidr_routes(&self) -> impl Iterator<Item = IpNetwork> {
        self.cidr.iter().map(|(n, _)| n)
    }
}

fn upsert<T>(table: &mut IpNetworkTable<BTreeSet<T>>, network: IpNetwork, element: T) -> bool
where
    T: Ord,
{
    match table.exact_match_mut(network) {
        Some(elements) => elements.insert(element),
        None => {
            table.insert(network, BTreeSet::from_iter([element]));

            true
        }
    }
}

fn remove_by_resource<T>(
    table: &mut IpNetworkTable<BTreeSet<T>>,
    predicate: impl Fn(&T) -> bool + Copy,
) where
    T: Ord,
{
    for (_, resources) in table.iter_mut() {
        for el in resources.extract_if(.., predicate) {
            drop(el)
        }
    }

    table.retain(|_, resources| !resources.is_empty());
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cmp::Ordering;

    const R1: ResourceId = ResourceId::from_u128(1);
    const R2: ResourceId = ResourceId::from_u128(2);
    const R3: ResourceId = ResourceId::from_u128(3);

    #[test]
    fn cidr_upsert() {
        let mut t = RoutingTable::default();
        let net = "10.0.0.0/8".parse().unwrap();

        assert!(t.upsert_cidr(net, R1), "first upsert should return true");
        assert!(!t.upsert_cidr(net, R1), "second upsert should return false");
        assert!(
            t.upsert_cidr(net, R2),
            "same network upsert of different resource should return true"
        );
    }

    #[test]
    fn dns_upsert() {
        let mut t = RoutingTable::default();
        let ip = "192.168.1.1".parse().unwrap();
        let domain = "example.com".parse::<DomainName>().unwrap();

        assert!(
            t.upsert_dns(ip, R1, domain.clone()),
            "first upsert should return true"
        );
        assert!(
            !t.upsert_dns(ip, R1, domain.clone()),
            "second upsert should return false"
        );
        assert!(
            t.upsert_dns(ip, R2, domain),
            "same network upsert of different resource should return true"
        );
    }

    #[test]
    fn matches_cidr_resource_by_ip() {
        let mut t = RoutingTable::default();
        t.upsert_cidr("10.0.0.0/8".parse().unwrap(), R1);

        assert_eq!(
            t.matches_cidr("10.1.2.3".parse().unwrap(), no_tiebreak),
            Some(R1)
        );
    }

    #[test]
    fn matches_dns_resource_by_ip() {
        let mut t = RoutingTable::default();
        let ip = "1.2.3.4".parse().unwrap();
        let domain = "example.com".parse::<DomainName>().unwrap();
        t.upsert_dns(ip, R1, domain.clone());

        assert_eq!(t.matches_dns(ip, no_tiebreak), Some((R1, &domain)));
    }

    #[test]
    fn matches_returns_none_for_unrouted_ip() {
        let t = RoutingTable::default();

        assert_eq!(
            t.matches_cidr("10.0.0.1".parse().unwrap(), no_tiebreak),
            None
        );
        assert_eq!(
            t.matches_dns("10.0.0.1".parse().unwrap(), no_tiebreak),
            None
        );
    }

    #[test]
    fn matches_longest_prefix_wins() {
        let mut t = RoutingTable::default();
        t.upsert_cidr("10.0.0.0/8".parse().unwrap(), R1);
        t.upsert_cidr("10.20.0.0/16".parse().unwrap(), R2);

        // Falls inside the /16 – more specific match should win.
        assert_eq!(
            t.matches_cidr("10.20.0.1".parse().unwrap(), no_tiebreak),
            Some(R2)
        );
        // Only covered by the /8.
        assert_eq!(
            t.matches_cidr("10.99.0.1".parse().unwrap(), no_tiebreak),
            Some(R1)
        );
    }

    #[test]
    fn matches_cidr_tie_breaker_controls_winner() {
        let mut t = RoutingTable::default();
        let net = "10.0.0.0/8".parse().unwrap();
        t.upsert_cidr(net, R1);
        t.upsert_cidr(net, R2);

        let ip = "10.1.2.3".parse().unwrap();

        let prefer_r1 = |a: ResourceId, b: ResourceId| match (a == R1, b == R1) {
            (true, _) => Ordering::Greater,
            (_, true) => Ordering::Less,
            _ => Ordering::Equal,
        };
        assert_eq!(t.matches_cidr(ip, prefer_r1), Some(R1));

        let prefer_r2 = |a: ResourceId, b: ResourceId| match (a == R2, b == R2) {
            (true, _) => Ordering::Greater,
            (_, true) => Ordering::Less,
            _ => Ordering::Equal,
        };
        assert_eq!(t.matches_cidr(ip, prefer_r2), Some(R2));
    }

    #[test]
    fn any_returns_true_for_covered_ip() {
        let mut t = RoutingTable::default();
        t.upsert_cidr("172.16.0.0/12".parse().unwrap(), R1);

        assert!(t.any_cidr("172.16.0.1".parse().unwrap()));
    }

    #[test]
    fn any_returns_false_for_uncovered_ip() {
        let mut t = RoutingTable::default();
        t.upsert_cidr("172.16.0.0/12".parse().unwrap(), R1);

        assert!(!t.any_cidr("192.168.0.1".parse().unwrap()));
    }

    #[test]
    fn remove_by_resource_stops_matching() {
        let mut t = RoutingTable::default();
        let net = "10.0.0.0/8".parse().unwrap();
        t.upsert_cidr(net, R1);

        t.remove_by_resource(R1);

        assert_eq!(
            t.matches_cidr("10.1.2.3".parse().unwrap(), no_tiebreak),
            None
        );
    }

    #[test]
    fn remove_by_resource_leaves_other_resources_intact() {
        let mut t = RoutingTable::default();
        let net = "10.0.0.0/8".parse().unwrap();
        t.upsert_cidr(net, R1);
        t.upsert_cidr(net, R2);

        t.remove_by_resource(R1);

        assert_eq!(
            t.matches_cidr("10.1.2.3".parse().unwrap(), no_tiebreak),
            Some(R2)
        );
    }

    #[test]
    fn remove_by_resource_removes_from_dns_table() {
        let mut t = RoutingTable::default();
        let ip = "1.2.3.4".parse().unwrap();
        let domain = "example.com".parse::<DomainName>().unwrap();
        t.upsert_dns(ip, R1, domain);

        t.remove_by_resource(R1);

        assert_eq!(t.matches_dns(ip, no_tiebreak), None);
    }

    #[test]
    fn remove_nonexistent_resource_is_noop() {
        let mut t = RoutingTable::default();
        t.upsert_cidr("10.0.0.0/8".parse().unwrap(), R1);

        t.remove_by_resource(R3); // R3 was never inserted

        assert_eq!(
            t.matches_cidr("10.1.2.3".parse().unwrap(), no_tiebreak),
            Some(R1)
        );
    }

    #[test]
    fn cidr_routes_yields_all_inserted_networks() {
        let mut t = RoutingTable::default();
        let net1: IpNetwork = "10.0.0.0/8".parse().unwrap();
        let net2: IpNetwork = "172.16.0.0/12".parse().unwrap();
        t.upsert_cidr(net1, R1);
        t.upsert_cidr(net2, R2);

        let mut routes = t.cidr_routes().collect::<Vec<_>>();
        routes.sort_by_key(|n| n.to_string());

        assert!(routes.contains(&net1));
        assert!(routes.contains(&net2));
        assert_eq!(routes.len(), 2);
    }

    #[test]
    fn cidr_routes_does_not_include_dns_entries() {
        let mut t = RoutingTable::default();
        let ip = "1.2.3.4".parse().unwrap();
        let domain = "example.com".parse::<DomainName>().unwrap();
        t.upsert_dns(ip, R1, domain);

        assert_eq!(t.cidr_routes().count(), 0);
    }

    fn no_tiebreak(a: ResourceId, b: ResourceId) -> Ordering {
        a.cmp(&b)
    }
}
