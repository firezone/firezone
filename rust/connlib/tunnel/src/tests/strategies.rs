use crate::tests::PacketSource;
use connlib_shared::{messages::DnsServer, proptest::domain_name, DomainName};
use proptest::{collection, prelude::*};
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

pub(crate) fn packet_source_v4() -> impl Strategy<Value = PacketSource> {
    prop_oneof![
        10 => Just(PacketSource::TunnelIp4),
        1 => any::<Ipv4Addr>().prop_map(IpAddr::V4).prop_map(PacketSource::Other)
    ]
}

pub(crate) fn packet_source_v6() -> impl Strategy<Value = PacketSource> {
    prop_oneof![
        10 => Just(PacketSource::TunnelIp6),
        1 => any::<Ipv6Addr>().prop_map(IpAddr::V6).prop_map(PacketSource::Other)
    ]
}
