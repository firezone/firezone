use super::dns_records::{ip_to_domain_record, DnsRecords};
use super::{sim_net::Host, sim_relay::ref_relay_host, stub_portal::StubPortal};
use crate::client::{
    CidrResource, DnsResource, InternetResource, DNS_SENTINELS_V4, DNS_SENTINELS_V6,
    IPV4_RESOURCES, IPV6_RESOURCES,
};
use crate::messages::DnsServer;
use crate::proptest::*;
use connlib_model::{DomainRecord, RelayId, Site};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use itertools::Itertools;
use prop::sample;
use proptest::{collection, prelude::*};
use std::{
    collections::{BTreeMap, BTreeSet},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::Duration,
};

pub(crate) fn global_dns_records() -> impl Strategy<Value = DnsRecords> {
    collection::btree_map(
        domain_name(2..4).prop_map(|d| d.parse().unwrap()),
        collection::btree_set(dns_record(), 1..6),
        0..5,
    )
    .prop_map_into()
}

fn dns_record() -> impl Strategy<Value = DomainRecord> {
    prop_oneof![
        3 => non_reserved_ip().prop_map(ip_to_domain_record),
        1 => collection::vec(txt_record(), 6..=10)
            .prop_map(|sections| { sections.into_iter().flatten().collect_vec() })
            .prop_map(|o| domain::rdata::Txt::from_octets(o).unwrap())
            .prop_map(DomainRecord::Txt)
    ]
}

// A maximum length txt record section
fn txt_record() -> impl Strategy<Value = Vec<u8>> {
    "[a-z]{255}".prop_map(|s| {
        let mut b = s.into_bytes();
        // This is always 255 but this is less error-prone
        let length = b.len() as u8;
        let mut section = Vec::new();
        section.push(length);
        section.append(&mut b);
        section
    })
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

pub(crate) fn latency(max: u64) -> impl Strategy<Value = Duration> {
    (10..max).prop_map(Duration::from_millis)
}

/// A [`Strategy`] for sampling a [`StubPortal`] that is configured with various [`Site`]s and gateways within those sites.
///
/// Similar as in production, the portal holds a list of DNS and CIDR resources (those are also sampled from the given sites).
/// Via this site mapping, these resources are implicitly assigned to a gateway.
pub(crate) fn stub_portal() -> impl Strategy<Value = StubPortal> {
    collection::btree_set(site(), 1..=3)
        .prop_flat_map(|sites| {
            let cidr_resources = collection::btree_set(
                cidr_resource_outside_reserved_ranges(any_site(sites.clone())),
                1..5,
            );
            let dns_resources = collection::btree_set(
                prop_oneof![
                    non_wildcard_dns_resource(any_site(sites.clone())),
                    star_wildcard_dns_resource(any_site(sites.clone())),
                    double_star_wildcard_dns_resource(any_site(sites.clone())),
                ],
                1..5,
            );
            let internet_resource = internet_resource(any_site(sites.clone()));

            // Assign between 1 and 3 gateways to each site.
            let gateways_by_site = sites
                .into_iter()
                .map(|site| (Just(site.id), collection::btree_set(gateway_id(), 1..=3)))
                .collect::<Vec<_>>()
                .prop_map(BTreeMap::from_iter);

            let gateway_selector = any::<sample::Selector>();

            (
                gateways_by_site,
                cidr_resources,
                dns_resources,
                internet_resource,
                gateway_selector,
            )
        })
        .prop_map(
            |(
                gateways_by_site,
                cidr_resources,
                dns_resources,
                internet_resource,
                gateway_selector,
            )| {
                StubPortal::new(
                    gateways_by_site,
                    gateway_selector,
                    cidr_resources,
                    dns_resources,
                    internet_resource,
                )
            },
        )
}

pub(crate) fn relays(
    id: impl Strategy<Value = RelayId>,
) -> impl Strategy<Value = BTreeMap<RelayId, Host<u64>>> {
    collection::btree_map(id, ref_relay_host(), 1..=2)
}

/// Sample a list of DNS servers.
///
/// We make sure to always have at least 1 IPv4 and 1 IPv6 DNS server.
pub(crate) fn dns_servers() -> impl Strategy<Value = BTreeSet<SocketAddr>> {
    let ip4_dns_servers = collection::btree_set(
        non_reserved_ipv4().prop_map(|ip| SocketAddr::from((ip, 53))),
        1..4,
    );
    let ip6_dns_servers = collection::btree_set(
        non_reserved_ipv6().prop_map(|ip| SocketAddr::from((ip, 53))),
        1..4,
    );

    (ip4_dns_servers, ip6_dns_servers).prop_map(|(mut v4, v6)| {
        v4.extend(v6);
        v4
    })
}

pub(crate) fn non_reserved_ip() -> impl Strategy<Value = IpAddr> {
    prop_oneof![
        non_reserved_ipv4().prop_map_into(),
        non_reserved_ipv6().prop_map_into(),
    ]
}

fn non_reserved_ipv4() -> impl Strategy<Value = Ipv4Addr> {
    any::<Ipv4Addr>()
        .prop_filter("must not be in sentinel IP range", |ip| {
            !DNS_SENTINELS_V4.contains(*ip)
        })
        .prop_filter("must not be in IPv4 resources range", |ip| {
            !IPV4_RESOURCES.contains(*ip)
        })
        .prop_filter("must be addressable IP", |ip| {
            !ip.is_unspecified() && !ip.is_multicast() && !ip.is_broadcast()
        })
}

fn non_reserved_ipv6() -> impl Strategy<Value = Ipv6Addr> {
    any::<Ipv6Addr>()
        .prop_filter("must not be in sentinel IP range", |ip| {
            !DNS_SENTINELS_V6.contains(*ip)
        })
        .prop_filter("must not be in IPv6 resources range", |ip| {
            !IPV6_RESOURCES.contains(*ip)
        })
        .prop_filter("must be addressable IP", |ip| {
            !ip.is_unspecified() && !ip.is_multicast()
        })
}

fn any_site(sites: BTreeSet<Site>) -> impl Strategy<Value = Site> {
    sample::select(Vec::from_iter(sites))
}

fn cidr_resource_outside_reserved_ranges(
    sites: impl Strategy<Value = Site>,
) -> impl Strategy<Value = CidrResource> {
    cidr_resource(any_ip_network(8), sites.prop_map(|s| vec![s]))
        .prop_filter(
            "tests doesn't support CIDR resources overlapping DNS resources",
            |r| {
                // This works because CIDR resources' host mask is always <8 while IP resource is 21
                let is_ip4_reserved = IpNetwork::V4(IPV4_RESOURCES)
                    .contains(r.address.network_address());
                let is_ip6_reserved = IpNetwork::V6(IPV6_RESOURCES)
                    .contains(r.address.network_address());

                !is_ip4_reserved && !is_ip6_reserved
            },
        )
        .prop_filter("resource must not be in the documentation range because we use those for host addresses and DNS IPs", |r| !r.address.is_documentation())
}

fn internet_resource(site: impl Strategy<Value = Site>) -> impl Strategy<Value = InternetResource> {
    crate::proptest::internet_resource(site.prop_map(|s| vec![s]))
}

fn non_wildcard_dns_resource(
    site: impl Strategy<Value = Site>,
) -> impl Strategy<Value = DnsResource> {
    dns_resource(site.prop_map(|s| vec![s]))
}

fn star_wildcard_dns_resource(
    site: impl Strategy<Value = Site>,
) -> impl Strategy<Value = DnsResource> {
    dns_resource(site.prop_map(|s| vec![s])).prop_map(|r| DnsResource {
        address: format!("*.{}", r.address),
        ..r
    })
}

fn double_star_wildcard_dns_resource(
    site: impl Strategy<Value = Site>,
) -> impl Strategy<Value = DnsResource> {
    dns_resource(site.prop_map(|s| vec![s])).prop_map(|r| DnsResource {
        address: format!("**.{}", r.address),
        ..r
    })
}

pub(crate) fn resolved_ips() -> impl Strategy<Value = BTreeSet<DomainRecord>> {
    let record = prop_oneof![
        dns_resource_ip4s().prop_map_into(),
        dns_resource_ip6s().prop_map_into()
    ]
    .prop_map(ip_to_domain_record);

    collection::btree_set(record, 1..6)
}

/// A strategy for generating a set of DNS records all nested under the provided base domain.
pub(crate) fn subdomain_records(
    base: String,
    subdomains: impl Strategy<Value = String>,
) -> impl Strategy<Value = DnsRecords> {
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

/// A [`Strategy`] of [`Ipv4Addr`]s used for the "real" IPs of DNS resources.
///
/// This uses the `TEST-NET-2` (`198.51.100.0/24`) address space reserved for documentation and examples in [RFC5737](https://datatracker.ietf.org/doc/html/rfc5737).
/// `TEST-NET-2` only contains 256 addresses which is small enough to generate overlapping IPs for our DNS resources (i.e. two different domains pointing to the same IP).
fn dns_resource_ip4s() -> impl Strategy<Value = Ipv4Addr> {
    let ips = Ipv4Network::new(Ipv4Addr::new(198, 51, 100, 0), 24)
        .unwrap()
        .hosts()
        .collect_vec();

    sample::select(ips)
}

/// A [`Strategy`] of [`Ipv6Addr`]s used for the "real" IPs of DNS resources.
///
/// This uses a subnet of the `2001:DB8::/32` address space reserved for documentation and examples in [RFC3849](https://datatracker.ietf.org/doc/html/rfc3849).
fn dns_resource_ip6s() -> impl Strategy<Value = Ipv6Addr> {
    const DNS_SUBNET: u16 = 0x2020;

    documentation_ip6s(DNS_SUBNET, 256)
}

pub(crate) fn documentation_ip6s(subnet: u16, num_ips: usize) -> impl Strategy<Value = Ipv6Addr> {
    let ips = Ipv6Network::new_truncate(
        Ipv6Addr::new(0x2001, 0xDB80, subnet, subnet, 0, 0, 0, 0),
        32,
    )
    .unwrap()
    .subnets_with_prefix(128)
    .map(|n| n.network_address())
    .take(num_ips)
    .collect_vec();

    sample::select(ips)
}

pub(crate) fn system_dns_servers() -> impl Strategy<Value = Vec<IpAddr>> {
    dns_servers().prop_flat_map(|dns_servers| {
        let max = dns_servers.len();

        sample::subsequence(Vec::from_iter(dns_servers), ..=max)
            .prop_map(|seq| seq.into_iter().map(|h| h.ip()).collect())
    })
}

pub(crate) fn upstream_dns_servers() -> impl Strategy<Value = Vec<DnsServer>> {
    dns_servers().prop_flat_map(|dns_servers| {
        let max = dns_servers.len();

        sample::subsequence(Vec::from_iter(dns_servers), ..=max)
            .prop_map(|seq| seq.into_iter().map(|h| h.into()).collect())
    })
}
