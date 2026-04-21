use std::{cmp::Ordering, collections::BTreeSet, net::IpAddr, num::NonZeroUsize};

use connlib_model::ResourceId;
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use ip_packet::{Protocol, UnsupportedProtocol};
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
    match_cache: LruCache<(IpAddr, Option<Protocol>), Option<T>>,
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

    /// Returns the single "best" entry whose network covers `ip` for the given `protocol`.
    ///
    /// Most importantly, this will always return an entry if the IP is present in the
    /// routing table, **even if the filter doesn't allow the packet**.
    ///
    /// The filter, entry-specificity, prefix-length etc are only used to sort the entries.
    /// It is the responsibility of the caller to additionally check whether the returned, "best"
    /// entry does in fact allow the given protocol.
    pub(crate) fn matches(
        &mut self,
        ip: IpAddr,
        protocol: Result<Protocol, UnsupportedProtocol>,
    ) -> Option<&T> {
        self.match_cache
            .get_or_insert((ip, protocol.clone().ok()), || {
                let (_, entry) = self
                    .inner
                    .matches(ip)
                    .flat_map(|(network, entries)| {
                        entries.iter().map(move |entry| (network, entry))
                    })
                    .max_by(|(l_net, l_entry), (r_net, r_entry)| {
                        by_filter(protocol.clone(), l_entry.filter(), r_entry.filter())
                            .then(l_entry.specificity(r_entry))
                            .then(by_netmask(l_net, r_net))
                            .then_with(|| l_entry.resource_id().cmp(&r_entry.resource_id()))
                    })?;

                Some(entry.clone())
            })
            .as_ref()
    }

    pub(crate) fn networks(&self) -> impl Iterator<Item = IpNetwork> + '_ {
        self.inner.iter().map(|(n, _)| n)
    }
}

/// Compares two [`FilterEngine`]s for a given protocol.
///
/// A filter that *permits* the protocol is considered greater than one that does not.
/// If both permit or both reject, the result is [`Ordering::Equal`].
fn by_filter(
    protocol: Result<Protocol, UnsupportedProtocol>,
    l: &FilterEngine,
    r: &FilterEngine,
) -> Ordering {
    match (l.apply(protocol.clone()).is_ok(), r.apply(protocol).is_ok()) {
        (true, true) | (false, false) => Ordering::Equal,
        (true, false) => Ordering::Greater,
        (false, true) => Ordering::Less,
    }
}

/// Compares two networks by their prefix length (netmask).
///
/// A longer prefix (e.g. `/32`) is considered greater than a shorter one (e.g. `/24`).
///
/// [`IpNetwork::netmask`] returns the prefix length as a plain `u8`, so a
/// higher value already means a more-specific network — no reversal needed.
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

        assert_eq!(t.matches(ip("10.1.2.3"), tcp(80)).map(|e| e.id), Some(R1));
        assert!(t.matches(ip("192.168.0.1"), tcp(80)).is_none());
    }

    #[test]
    fn matches_longer_prefix_wins() {
        let mut t = RoutingTable::new();
        t.upsert(net("10.0.0.0/8"), entry(1, R1, permit_all()));
        t.upsert(net("10.20.0.0/16"), entry(1, R2, permit_all()));

        assert_eq!(t.matches(ip("10.20.0.1"), tcp(80)).map(|e| e.id), Some(R2));
        assert_eq!(t.matches(ip("10.99.0.1"), tcp(80)).map(|e| e.id), Some(R1));
    }

    #[test]
    fn matches_filter_wins_then_lexical_id() {
        let mut t = RoutingTable::new();
        // R1: only TCP/443. R2: only TCP/80.
        t.upsert(net("10.0.0.0/8"), entry(1, R1, permit_tcp(443)));
        t.upsert(net("10.0.0.0/8"), entry(1, R2, permit_tcp(80)));

        // Only R1's filter matches TCP/443 → R1 wins despite lower ID.
        assert_eq!(t.matches(ip("10.1.2.3"), tcp(443)).map(|e| e.id), Some(R1));
        // Only R2's filter matches TCP/80 → R2 wins.
        assert_eq!(t.matches(ip("10.1.2.3"), tcp(80)).map(|e| e.id), Some(R2));
        // Neither matches TCP/9999; both are equal on filter → higher lexical ID (R2) wins.
        assert_eq!(t.matches(ip("10.1.2.3"), tcp(9999)).map(|e| e.id), Some(R2));
    }

    #[test]
    fn dns_more_specific_pattern_wins_but_filter_beats_it() {
        let mut t = RoutingTable::<TestEntry>::new();
        let net = ip("1.2.3.4").into();

        // R1: higher specificity (exact), R2: lower specificity (wildcard).
        // Both permit TCP/80; R1 wins on specificity.
        t.upsert(net, entry(2, R1, permit_tcp(80)));
        t.upsert(net, entry(1, R2, permit_tcp(80)));
        assert_eq!(t.matches(ip("1.2.3.4"), tcp(80)).map(|e| e.id), Some(R1));

        // R3: lower specificity than R1, but the only entry that permits TCP/443.
        // A matching filter beats a non-matching one regardless of specificity.
        t.upsert(net, entry(1, R3, permit_tcp(443)));
        assert_eq!(t.matches(ip("1.2.3.4"), tcp(443)).map(|e| e.id), Some(R3));
    }

    #[test]
    fn remove_by_id() {
        let mut t = RoutingTable::new();
        t.upsert(net("10.0.0.0/8"), entry(1, R1, permit_all()));
        t.upsert(net("10.0.0.0/8"), entry(1, R2, permit_all()));

        t.remove_by_id(R1);
        assert_eq!(t.matches(ip("10.1.2.3"), tcp(80)).map(|e| e.id), Some(R2));

        t.remove_by_id(R3); // never inserted – no-op
        assert_eq!(t.matches(ip("10.1.2.3"), tcp(80)).map(|e| e.id), Some(R2));

        t.remove_by_id(R2);
        assert!(t.matches(ip("10.1.2.3"), tcp(80)).is_none());
    }

    #[test]
    fn cache_is_cleared_on_upsert() {
        let mut t = RoutingTable::new();

        // Use an IP that is not covered by any network yet.
        // Populate the cache with a None (no route exists).
        assert!(t.matches(ip("10.1.2.3"), tcp(80)).is_none());

        // Inserting a covering network must evict the cached None.
        t.upsert(net("10.0.0.0/8"), entry(1, R1, permit_all()));
        assert_eq!(t.matches(ip("10.1.2.3"), tcp(80)).map(|e| e.id), Some(R1));
    }

    #[test]
    fn cache_is_cleared_on_upsert_existing_network() {
        let mut t = RoutingTable::new();
        t.upsert(net("10.0.0.0/8"), entry(1, R1, permit_all()));

        // Warm the cache: R1 is the winner for TCP/80.
        assert_eq!(t.matches(ip("10.1.2.3"), tcp(80)).map(|e| e.id), Some(R1));

        // Insert a more-specific entry on the same network; the cached result
        // must be evicted so the new winner is returned.
        t.upsert(net("10.0.0.0/8"), entry(1, R2, permit_tcp(80)));
        assert_eq!(t.matches(ip("10.1.2.3"), tcp(80)).map(|e| e.id), Some(R2));
    }

    #[test]
    fn cache_is_cleared_on_remove_by_id() {
        let mut t = RoutingTable::new();
        t.upsert(net("10.0.0.0/8"), entry(1, R1, permit_all()));
        t.upsert(net("10.0.0.0/8"), entry(1, R2, permit_all()));

        // Warm the cache: R2 wins the tie-break (higher lexical ID).
        assert_eq!(t.matches(ip("10.1.2.3"), tcp(80)).map(|e| e.id), Some(R2));

        // Removing R2 must evict the cached result; R1 should now be returned.
        t.remove_by_id(R2);
        assert_eq!(t.matches(ip("10.1.2.3"), tcp(80)).map(|e| e.id), Some(R1));

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
        FilterEngine::new(&[Filter::Tcp(PortRange {
            port_range_start: port,
            port_range_end: port,
        })])
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

        bencher.bench_local(|| table.matches(ip, proto.clone()).is_some());
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

        bencher.bench_local(|| table.matches(ip, proto.clone()).is_some());
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

        bencher.bench_local(|| table.matches(ip, proto.clone()).is_some());
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
        FilterEngine::new(&[Filter::Tcp(PortRange {
            port_range_start: port,
            port_range_end: port,
        })])
    }
}
