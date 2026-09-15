use std::{
    cmp::Ordering,
    collections::BTreeSet,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    num::NonZeroUsize,
};

use connlib_model::ResourceId;
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_network_table::IpNetworkTable;
use ip_packet::{Protocol, UnsupportedProtocol};
use itertools::Itertools as _;
use lru::LruCache;

use crate::filter_engine::FilterEngine;

/// How many IP + port combinations we will at most cache for fast routing table lookups.
///
/// 1024 has been chosen as an estimate for making most connections under typical workloads fast.
/// Both TCP and QUIC - which are likely the predominant workloads - retain a stable 4-tuple
/// for an existing connections. Thus, 1024 allows us to have a fast lookup for up to 1024 connections
/// in parallel which ought to be enough for most people. Very likely, other packet processing will
/// be the culprit for low throughput if we have more than 1024 connections, plus the cache uses an LRU
/// eviction pattern, thus prioritizing the most recently used connections.
const MAX_CACHE_ENTRIES: NonZeroUsize = NonZeroUsize::new(1024).expect("1024 > 0");

pub(crate) trait RouteEntry: Ord + Clone {
    fn filter(&self) -> &FilterEngine;
    fn resource_id(&self) -> ResourceId;

    /// An entry-level tie-breaker applied after [`filter`](RouteEntry::filter)
    /// but before the network prefix-length comparison.
    fn specificity(&self, other: &Self) -> Ordering {
        let _ = other;
        Ordering::Equal
    }
}

pub(crate) struct RoutingTable<T> {
    inner: IpNetworkTable<BTreeSet<T>>,
    match_cache: LruCache<(IpAddr, FilterProtocol), Option<Matches<T>>>,
}

/// Address matches partitioned by filter allowance, each in routing preference order.
/// An empty `allowed` list means that the address is covered but traffic is denied.
pub(crate) struct Matches<T> {
    pub(crate) allowed: Vec<T>,
    #[cfg(any(test, feature = "malicious-behaviour"))]
    pub(crate) denied: Vec<T>,
}

/// Protocol classes distinguished by the filter engine.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum FilterProtocol {
    Supported(Protocol),
    OtherIcmp,
    OtherIp,
}

impl From<&Result<Protocol, UnsupportedProtocol>> for FilterProtocol {
    fn from(protocol: &Result<Protocol, UnsupportedProtocol>) -> Self {
        match protocol {
            Ok(protocol) => Self::Supported(*protocol),
            Err(UnsupportedProtocol::UnsupportedIcmpv4Type(_)) => Self::OtherIcmp,
            Err(UnsupportedProtocol::UnsupportedIcmpv6Type(_)) => Self::OtherIcmp,
            Err(UnsupportedProtocol::UnsupportedIpPayload(_)) => Self::OtherIp,
        }
    }
}

impl<T> Default for RoutingTable<T> {
    fn default() -> Self {
        Self {
            inner: IpNetworkTable::new(),
            match_cache: LruCache::new(MAX_CACHE_ENTRIES),
        }
    }
}

impl<T> RoutingTable<T>
where
    T: RouteEntry,
{
    pub(crate) fn new() -> Self {
        Self::default()
    }

    /// Inserts `entry` so it matches every address, v4 and v6.
    ///
    /// Use this when only the entry's filter and id should decide the match,
    /// not the address.
    pub(crate) fn upsert_for_all_addresses(&mut self, entry: T) {
        self.upsert(
            Ipv4Network::new(Ipv4Addr::UNSPECIFIED, 0)
                .expect("/0 is a valid prefix")
                .into(),
            entry.clone(),
        );
        self.upsert(
            Ipv6Network::new(Ipv6Addr::UNSPECIFIED, 0)
                .expect("/0 is a valid prefix")
                .into(),
            entry,
        );
    }

    /// Inserts `entry` into the set associated with `network`.
    ///
    /// Returns `true` if the entry was not already present (i.e. it was newly inserted).
    pub(crate) fn upsert(&mut self, network: IpNetwork, entry: T) -> bool {
        self.match_cache.clear();

        match self.inner.exact_match_mut(network) {
            Some(set) => set.insert(entry),
            None => {
                self.inner.insert(network, BTreeSet::from_iter([entry]));
                true
            }
        }
    }

    /// Removes all entries for a given resource ID.
    pub(crate) fn remove_by_id(&mut self, id: ResourceId) {
        self.match_cache.clear();

        for (_, entries) in self.inner.iter_mut() {
            for ele in entries.extract_if(.., |e| e.resource_id() == id) {
                drop(ele)
            }
        }

        self.inner.retain(|_, entries| !entries.is_empty());
    }

    /// Returns address matches with filters evaluated, or `None` if no network covers `ip`.
    ///
    /// Permitting entries are ordered by specificity, prefix length and resource ID.
    pub(crate) fn matches(
        &mut self,
        ip: IpAddr,
        protocol: Result<Protocol, UnsupportedProtocol>,
    ) -> Option<&Matches<T>> {
        self.match_cache
            .get_or_insert((ip, FilterProtocol::from(&protocol)), || {
                let mut entries = self
                    .inner
                    .matches(ip)
                    .flat_map(|(network, entries)| {
                        entries.iter().map(move |entry| (network, entry))
                    })
                    .sorted_by(|(l_net, l_entry), (r_net, r_entry)| {
                        l_entry
                            .specificity(r_entry)
                            .then(by_netmask(l_net, r_net))
                            .then_with(|| l_entry.resource_id().cmp(&r_entry.resource_id()))
                            .reverse()
                    })
                    .peekable();
                entries.peek()?;

                let mut matches = Matches {
                    allowed: Vec::new(),
                    #[cfg(any(test, feature = "malicious-behaviour"))]
                    denied: Vec::new(),
                };
                for (_, entry) in entries {
                    if entry.filter().apply(protocol.clone()).is_ok() {
                        matches.allowed.push(entry.clone());
                    } else {
                        #[cfg(any(test, feature = "malicious-behaviour"))]
                        matches.denied.push(entry.clone());
                    }
                }

                Some(matches)
            })
            .as_ref()
    }

    pub(crate) fn networks(&self) -> impl Iterator<Item = IpNetwork> + '_ {
        self.inner.iter().map(|(n, _)| n)
    }
}

/// Compares two networks by their prefix length (netmask).
///
/// A longer prefix (e.g. `/32`) is considered greater than a shorter one (e.g. `/24`).
///
/// [`IpNetwork::netmask`] returns the prefix length as a plain `u8`, so a
/// higher value already means a more-specific network, so no reversal is needed.
fn by_netmask(l: &IpNetwork, r: &IpNetwork) -> Ordering {
    l.netmask().cmp(&r.netmask())
}

#[cfg(test)]
mod tests {
    use super::*;

    use connlib_model::ResourceId;

    const R1: ResourceId = ResourceId::from_u128(1);
    const R2: ResourceId = ResourceId::from_u128(2);
    const R3: ResourceId = ResourceId::from_u128(3);

    #[test]
    fn upsert() {
        let mut t = RoutingTable::new();
        let net = net("10.0.0.0/8");

        assert!(t.upsert(net, entry(1, R1, permit_all())), "first insert");
        assert!(!t.upsert(net, entry(1, R1, permit_all())), "duplicate");
        assert!(
            t.upsert(net, entry(1, R2, permit_all())),
            "different resource, same network"
        );
    }

    #[test]
    fn matches_hit_and_miss() {
        let mut t = RoutingTable::new();
        t.upsert(net("10.0.0.0/8"), entry(1, R1, permit_all()));

        assert_eq!(
            t.matches(ip("10.1.2.3"), tcp(80))
                .unwrap()
                .allowed
                .first()
                .map(|e| e.id),
            Some(R1)
        );
        assert!(t.matches(ip("192.168.0.1"), tcp(80)).is_none());
    }

    #[test]
    fn matches_returns_all_entries_in_preference_order() {
        let mut table = RoutingTable::new();
        table.upsert(net("10.0.0.0/8"), entry(1, R1, permit_all()));
        table.upsert(net("10.20.0.0/16"), entry(1, R2, permit_tcp(443)));
        table.upsert(net("10.20.0.0/16"), entry(1, R3, permit_tcp(443)));

        let matches = &table.matches(ip("10.20.0.1"), tcp(443)).unwrap().allowed;
        assert_eq!(
            matches.iter().map(|entry| entry.id).collect::<Vec<_>>(),
            vec![R3, R2, R1]
        );

        let matches = &table.matches(ip("10.20.0.1"), tcp(80)).unwrap().allowed;
        assert_eq!(
            matches.iter().map(|entry| entry.id).collect::<Vec<_>>(),
            vec![R1]
        );
    }

    #[test]
    fn denied_matches_are_distinct_from_missing_routes() {
        let mut table = RoutingTable::new();
        table.upsert(net("10.0.0.0/8"), entry(1, R1, permit_tcp(443)));

        assert!(table.matches(ip("192.168.0.1"), tcp(80)).is_none());
        assert!(
            table
                .matches(ip("10.0.0.1"), tcp(80))
                .unwrap()
                .allowed
                .is_empty()
        );

        table.upsert(net("10.0.0.0/8"), entry(1, R2, permit_tcp(80)));
        assert_eq!(
            table.matches(ip("10.0.0.1"), tcp(80)).unwrap().allowed[0].id,
            R2
        );
        table.remove_by_id(R2);
        assert!(
            table
                .matches(ip("10.0.0.1"), tcp(80))
                .unwrap()
                .allowed
                .is_empty()
        );
    }

    #[test]
    fn cache_distinguishes_unsupported_icmp_from_other_ip_protocols() {
        use ip_packet::{Icmpv4Type, IpProtocol, icmpv4};

        let mut table = RoutingTable::new();
        table.upsert(
            net("10.0.0.0/8"),
            entry(1, R1, FilterEngine::new(&[crate::messages::Filter::Icmp])),
        );
        let icmp = Err(UnsupportedProtocol::UnsupportedIcmpv4Type(
            Icmpv4Type::DestinationUnreachable(icmpv4::DestUnreachableHeader::Host),
        ));
        let other_ip = Err(UnsupportedProtocol::UnsupportedIpPayload(IpProtocol::IGMP));

        for protocol in [icmp.clone(), other_ip.clone(), icmp, other_ip] {
            let expected = matches!(protocol, Err(UnsupportedProtocol::UnsupportedIcmpv4Type(_)));
            assert_eq!(
                !table
                    .matches(ip("10.0.0.1"), protocol)
                    .unwrap()
                    .allowed
                    .is_empty(),
                expected
            );
        }
    }

    #[test]
    fn dns_more_specific_pattern_wins_but_filter_beats_it() {
        let mut t = RoutingTable::<TestEntry>::new();
        let net = ip("1.2.3.4").into();

        // R1: higher specificity (exact), R2: lower specificity (wildcard).
        // Both permit TCP/80; R1 wins on specificity.
        t.upsert(net, entry(2, R1, permit_tcp(80)));
        t.upsert(net, entry(1, R2, permit_tcp(80)));
        assert_eq!(
            t.matches(ip("1.2.3.4"), tcp(80))
                .unwrap()
                .allowed
                .first()
                .map(|e| e.id),
            Some(R1)
        );

        // R3: lower specificity than R1, but the only entry that permits TCP/443.
        // A matching filter beats a non-matching one regardless of specificity.
        t.upsert(net, entry(1, R3, permit_tcp(443)));
        assert_eq!(
            t.matches(ip("1.2.3.4"), tcp(443))
                .unwrap()
                .allowed
                .first()
                .map(|e| e.id),
            Some(R3)
        );
    }

    #[test]
    fn remove_by_id() {
        let mut t = RoutingTable::new();
        t.upsert(net("10.0.0.0/8"), entry(1, R1, permit_all()));
        t.upsert(net("10.0.0.0/8"), entry(1, R2, permit_all()));

        t.remove_by_id(R1);
        assert_eq!(
            t.matches(ip("10.1.2.3"), tcp(80))
                .unwrap()
                .allowed
                .first()
                .map(|e| e.id),
            Some(R2)
        );

        t.remove_by_id(R3); // never inserted – no-op
        assert_eq!(
            t.matches(ip("10.1.2.3"), tcp(80))
                .unwrap()
                .allowed
                .first()
                .map(|e| e.id),
            Some(R2)
        );

        t.remove_by_id(R2);
        assert!(t.matches(ip("10.1.2.3"), tcp(80)).is_none());
    }

    #[test]
    fn cache_is_cleared_on_upsert() {
        let mut t = RoutingTable::new();

        // Use an IP that is not covered by any network yet.
        // Cache the empty result.
        assert!(t.matches(ip("10.1.2.3"), tcp(80)).is_none());

        // Inserting a covering network must evict the cached result.
        t.upsert(net("10.0.0.0/8"), entry(1, R1, permit_all()));
        assert_eq!(
            t.matches(ip("10.1.2.3"), tcp(80))
                .unwrap()
                .allowed
                .first()
                .map(|e| e.id),
            Some(R1)
        );
    }

    #[test]
    fn cache_is_cleared_on_upsert_existing_network() {
        let mut t = RoutingTable::new();
        t.upsert(net("10.0.0.0/8"), entry(1, R1, permit_all()));

        // Warm the cache: R1 is the winner for TCP/80.
        assert_eq!(
            t.matches(ip("10.1.2.3"), tcp(80))
                .unwrap()
                .allowed
                .first()
                .map(|e| e.id),
            Some(R1)
        );

        // Insert a more-specific entry on the same network; the cached result
        // must be evicted so the new winner is returned.
        t.upsert(net("10.0.0.0/8"), entry(1, R2, permit_tcp(80)));
        assert_eq!(
            t.matches(ip("10.1.2.3"), tcp(80))
                .unwrap()
                .allowed
                .first()
                .map(|e| e.id),
            Some(R2)
        );
    }

    #[test]
    fn cache_is_cleared_on_remove_by_id() {
        let mut t = RoutingTable::new();
        t.upsert(net("10.0.0.0/8"), entry(1, R1, permit_all()));
        t.upsert(net("10.0.0.0/8"), entry(1, R2, permit_all()));

        // Warm the cache with both matching entries.
        assert_eq!(t.matches(ip("10.1.2.3"), tcp(80)).unwrap().allowed.len(), 2);

        // Removing R2 must evict the cached result; R1 should now be returned.
        t.remove_by_id(R2);
        assert_eq!(
            t.matches(ip("10.1.2.3"), tcp(80))
                .unwrap()
                .allowed
                .first()
                .map(|e| e.id),
            Some(R1)
        );

        // Removing the last entry must evict the cache too; expect a miss.
        t.remove_by_id(R1);
        assert!(t.matches(ip("10.1.2.3"), tcp(80)).is_none());
    }

    #[test]
    fn networks() {
        let mut t = RoutingTable::new();
        let net1 = net("10.0.0.0/8");
        let net2 = net("172.16.0.0/12");
        t.upsert(net1, entry(1, R1, permit_all()));
        t.upsert(net2, entry(1, R2, permit_all()));

        let mut nets = t.networks().collect::<Vec<_>>();
        nets.sort_by_key(|n| n.to_string());
        assert_eq!(nets, vec![net1, net2]);
    }

    #[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
    struct TestEntry {
        id: ResourceId,
        specificity: u8, // Mimics the additional element that in production is used by `dns::Pattern`.
        filter: FilterEngine,
    }

    impl RouteEntry for TestEntry {
        fn filter(&self) -> &FilterEngine {
            &self.filter
        }

        fn resource_id(&self) -> ResourceId {
            self.id
        }

        fn specificity(&self, other: &Self) -> Ordering {
            self.specificity.cmp(&other.specificity)
        }
    }

    fn entry(specificity: u8, id: ResourceId, filter: FilterEngine) -> TestEntry {
        TestEntry {
            id,
            specificity,
            filter,
        }
    }

    fn permit_all() -> FilterEngine {
        FilterEngine::PermitAll
    }

    fn permit_tcp(port: u16) -> FilterEngine {
        use crate::messages::{Filter, PortRange};
        FilterEngine::new(&[Filter::Tcp(PortRange::single(port))])
    }

    #[expect(clippy::unnecessary_wraps)]
    fn tcp(port: u16) -> Result<Protocol, UnsupportedProtocol> {
        Ok(Protocol::Tcp(port))
    }

    fn net(s: &str) -> IpNetwork {
        s.parse().unwrap()
    }

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }
}

#[cfg(feature = "divan")]
#[allow(clippy::unwrap_used)]
mod benches {
    use super::*;

    use crate::messages::{Filter, PortRange};

    /// Benchmark `matches` against a table that has `N` resources all mapped to
    /// **the same single IP** (`1.2.3.4/32`), each permitting a distinct TCP port.
    ///
    /// This is the pathological case: every prefix lookup returns all N entries,
    /// forcing the full linear scan + comparison chain inside `matches`.
    #[divan::bench(consts = [1, 10, 100, 500, 1_000, 10_000])]
    fn matches_many_resources_same_ip<const N: u128>(bencher: divan::Bencher) {
        let mut table = RoutingTable::new();
        let net = net("1.2.3.4/32");

        for i in 0..N {
            let port = (i % 65535) as u16 + 1;
            table.upsert(net, entry(ResourceId::from_u128(i), permit_tcp_port(port)));
        }

        let ip = ip("1.2.3.4");
        let proto = Ok(Protocol::Tcp(0));

        bencher.bench_local(|| {
            table
                .matches(ip, proto.clone())
                .is_some_and(|m| !m.allowed.is_empty())
        });
    }

    /// Benchmark `matches` against a table with `N` **distinct /32 networks**
    /// (one resource each).  The probed IP always hits the last-inserted entry,
    /// so the longest-prefix match needs to walk the whole trie before settling.
    #[divan::bench(consts = [1, 10, 100, 500, 1_000])]
    fn matches_many_distinct_networks<const N: u128>(bencher: divan::Bencher) {
        let mut table = RoutingTable::new();

        for i in 0..N {
            let a = ((i >> 16) & 0xff) as u8;
            let b = ((i >> 8) & 0xff) as u8;
            let c = (i & 0xff) as u8;
            let net = net(&format!("10.{a}.{b}.{c}/32"));
            table.upsert(
                net,
                entry(ResourceId::from_u128(i), FilterEngine::PermitAll),
            );
        }

        let last = N - 1;
        let a = ((last >> 16) & 0xff) as u8;
        let b = ((last >> 8) & 0xff) as u8;
        let c = (last & 0xff) as u8;
        let ip = ip(&format!("10.{a}.{b}.{c}"));
        let proto = Ok(Protocol::Tcp(80));

        bencher.bench_local(|| {
            table
                .matches(ip, proto.clone())
                .is_some_and(|m| !m.allowed.is_empty())
        });
    }

    /// Benchmark `matches` against a table with `N` **nested CIDR prefixes**
    /// that all contain the probed IP.  This exercises the worst case for the
    /// prefix-length tie-breaker: every network in the trie is a candidate and
    /// the winning entry is the one with the longest prefix.
    #[divan::bench(consts = [1, 8, 16, 24])]
    fn matches_nested_prefixes<const N: usize>(bencher: divan::Bencher) {
        let mut table = RoutingTable::new();

        for prefix_len in 8..(8 + N as u8) {
            let net = net(&format!("10.0.0.0/{prefix_len}"));
            table.upsert(
                net,
                entry(
                    ResourceId::from_u128(prefix_len as u128),
                    FilterEngine::PermitAll,
                ),
            );
        }

        let ip = ip("10.0.0.1");
        let proto = Ok(Protocol::Tcp(80));

        bencher.bench_local(|| {
            table
                .matches(ip, proto.clone())
                .is_some_and(|m| !m.allowed.is_empty())
        });
    }

    // A minimal entry mirroring the one in the test module.
    #[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
    struct Entry {
        id: ResourceId,
        filter: FilterEngine,
    }

    impl RouteEntry for Entry {
        fn filter(&self) -> &FilterEngine {
            &self.filter
        }

        fn resource_id(&self) -> ResourceId {
            self.id
        }
    }

    fn entry(id: ResourceId, filter: FilterEngine) -> Entry {
        Entry { id, filter }
    }

    fn net(s: &str) -> IpNetwork {
        s.parse().unwrap()
    }

    fn ip(s: &str) -> std::net::IpAddr {
        s.parse().unwrap()
    }

    fn permit_tcp_port(port: u16) -> FilterEngine {
        FilterEngine::new(&[Filter::Tcp(PortRange::single(port))])
    }
}
