use connlib_shared::{messages::DnsServer, proptest::domain_name, DomainName};
use ip_network::{Ipv4Network, Ipv6Network};
use itertools::Itertools as _;
use proptest::{collection, prelude::*, sample};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
};

pub(crate) fn resolved_ips() -> impl Strategy<Value = HashSet<IpAddr>> {
    collection::hash_set(any::<IpAddr>(), 1..6)
}

/// A strategy for generating a set of DNS records all nested under the provided base domain.
pub(crate) fn subdomain_records(
    base: String,
    subdomains: impl Strategy<Value = String>,
) -> impl Strategy<Value = HashMap<DomainName, HashSet<IpAddr>>> {
    collection::hash_map(subdomains, resolved_ips(), 1..4).prop_map(move |subdomain_ips| {
        subdomain_ips
            .into_iter()
            .map(|(label, ips)| {
                let domain = format!("{label}.{base}");

                (domain.parse().unwrap(), ips)
            })
            .collect()
    })
}

pub(crate) fn upstream_dns_servers() -> impl Strategy<Value = Vec<DnsServer>> {
    let ip4_dns_servers = collection::vec(
        any::<Ipv4Addr>().prop_map(|ip| DnsServer::from((ip, 53))),
        1..4,
    );
    let ip6_dns_servers = collection::vec(
        any::<Ipv6Addr>().prop_map(|ip| DnsServer::from((ip, 53))),
        1..4,
    );

    // TODO: PRODUCTION CODE DOES NOT HAVE A SAFEGUARD FOR THIS YET.
    // AN ADMIN COULD CONFIGURE ONLY IPv4 SERVERS IN WHICH CASE WE ARE SCREWED IF THE CLIENT ONLY HAS IPv6 CONNECTIVITY.

    prop_oneof![
        Just(Vec::new()),
        (ip4_dns_servers, ip6_dns_servers).prop_map(|(mut ip4_servers, ip6_servers)| {
            ip4_servers.extend(ip6_servers);

            ip4_servers
        })
    ]
}

/// A [`Strategy`] of [`Ipv4Addr`]s used for routing packets between hosts within our test.
///
/// This uses the `TEST-NET-3` (`203.0.113.0/24`) address space reserved for documentation and examples in [RFC5737](https://datatracker.ietf.org/doc/html/rfc5737).
pub(crate) fn host_ip4s() -> impl Strategy<Value = Ipv4Addr> {
    let ips = Ipv4Network::new(Ipv4Addr::new(203, 0, 113, 0), 24)
        .unwrap()
        .hosts()
        .take(100)
        .collect_vec();

    sample::select(ips)
}

/// A [`Strategy`] of [`Ipv6Addr`]s used for routing packets between hosts within our test.
///
/// This uses the `2001:DB8::/32` address space reserved for documentation and examples in [RFC3849](https://datatracker.ietf.org/doc/html/rfc3849).
pub(crate) fn host_ip6s() -> impl Strategy<Value = Ipv6Addr> {
    let ips = Ipv6Network::new(Ipv6Addr::new(0x2001, 0xDB80, 0, 0, 0, 0, 0, 0), 32)
        .unwrap()
        .subnets_with_prefix(128)
        .map(|n| n.network_address())
        .take(100)
        .collect_vec();

    sample::select(ips)
}

pub(crate) fn system_dns_servers() -> impl Strategy<Value = Vec<IpAddr>> {
    collection::vec(any::<IpAddr>(), 1..4) // Always need at least 1 system DNS server. TODO: Should we test what happens if we don't?
}

pub(crate) fn global_dns_records() -> impl Strategy<Value = BTreeMap<DomainName, HashSet<IpAddr>>> {
    collection::btree_map(
        domain_name(2..4).prop_map(|d| d.parse().unwrap()),
        collection::hash_set(any::<IpAddr>(), 1..6),
        0..15,
    )
}

pub(crate) fn packet_source_v4(client: Ipv4Addr) -> impl Strategy<Value = Ipv4Addr> {
    prop_oneof![
        10 => Just(client),
        1 => any::<Ipv4Addr>()
    ]
}

pub(crate) fn packet_source_v6(client: Ipv6Addr) -> impl Strategy<Value = Ipv6Addr> {
    prop_oneof![
        10 => Just(client),
        1 => any::<Ipv6Addr>()
    ]
}
