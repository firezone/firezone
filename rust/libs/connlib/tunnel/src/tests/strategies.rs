use super::dns_records::DnsRecords;
use super::icmp_error_hosts::IcmpErrorHosts;
use super::{sim_net::Host, sim_relay::ref_relay_host, stub_portal::StubPortal};
use crate::client::{
    CidrResource, DNS_SENTINELS, DnsResource, IPV4_RESOURCES, IPV6_RESOURCES, InternetResource,
};
use crate::messages::{UpstreamDo53, UpstreamDoH};
use crate::{IPV4_TUNNEL, IPV6_TUNNEL, proptest::*};
use connlib_model::{RelayId, Site};
use dns_types::{DoHUrl, DomainName, OwnedRecordData};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use itertools::Itertools;
use prop::sample;
use proptest::collection::btree_set;
use proptest::{collection, prelude::*};
use std::iter;
use std::num::NonZeroU16;
use std::time::Instant;
use std::{
    collections::{BTreeMap, BTreeSet},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::Duration,
};

pub(crate) fn global_dns_records(at: Instant) -> impl Strategy<Value = DnsRecords> {
    collection::btree_map(
        domain_name(2..4),
        collection::btree_set(dns_record(), 1..6)
            .prop_map(move |records| BTreeMap::from([(at, records)])),
        0..5,
    )
    .prop_map_into()
}

pub(crate) fn dns_record() -> impl Strategy<Value = OwnedRecordData> {
    prop_oneof![
        3 => non_reserved_ip().prop_map(dns_types::records::ip),
        1 => collection::vec(txt_record(), 6..=10)
            .prop_map(|sections| { sections.into_iter().flatten().collect_vec() })
            .prop_map(|content| dns_types::records::txt(content).unwrap())
    ]
}

pub(crate) fn site_specific_dns_record() -> impl Strategy<Value = OwnedRecordData> {
    prop_oneof![
        collection::vec(txt_record(), 6..=10)
            .prop_map(|sections| { sections.into_iter().flatten().collect_vec() })
            .prop_map(|content| dns_types::records::txt(content).unwrap()),
        srv_record()
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

fn srv_record() -> impl Strategy<Value = OwnedRecordData> {
    (any::<u16>(), any::<u16>(), any::<u16>(), domain_name(2..4)).prop_map(
        |(priority, weight, port, target)| dns_types::records::srv(priority, weight, port, target),
    )
}

pub(crate) fn latency(max: u64) -> impl Strategy<Value = Duration> {
    (10..max).prop_map(Duration::from_millis)
}

/// A [`Strategy`] for sampling a [`StubPortal`] that is configured with various [`Site`]s and gateways within those sites.
///
/// Similar as in production, the portal holds a list of DNS and CIDR resources (those are also sampled from the given sites).
/// Via this site mapping, these resources are implicitly assigned to a gateway.
pub(crate) fn stub_portal() -> impl Strategy<Value = StubPortal> {
    collection::btree_set(site(), 2..=4)
        .prop_flat_map(|sites| {
            let (internet_site, regular_sites) = create_internet_site(sites);

            let cidr_resources = collection::btree_set(
                cidr_resource_outside_reserved_ranges(any_site(regular_sites.clone())),
                1..5,
            );
            let dns_resources = collection::btree_set(
                prop_oneof![
                    non_wildcard_dns_resource(any_site(regular_sites.clone())),
                    star_wildcard_dns_resource(any_site(regular_sites.clone())),
                    double_star_wildcard_dns_resource(any_site(regular_sites.clone())),
                ],
                1..5,
            );
            let internet_resource = internet_resource(Just(internet_site.clone()));

            // Assign between 1 and 3 gateways to each site.
            let gateways_by_site = iter::once(internet_site)
                .chain(regular_sites)
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

/// Samples a list of TCP resource addresses from the given DNS records.
///
/// We sample at most 1 domain from the given records and create a [`SocketAddr`]
/// for _each_ IP that this domain resolves this.
/// This is equivalent for how one would deploy a service in the real world.
/// If `example.com` resolves to 4 IPs, an HTTP server needs to run on all 4 IPs on the same port.
///
/// The port is sampled together with domain.
pub(crate) fn tcp_resources(
    dns_records: DnsRecords,
    imcp_error_hosts: IcmpErrorHosts,
    at: Instant,
) -> impl Strategy<Value = BTreeMap<DomainName, BTreeSet<SocketAddr>>> {
    let all_domains = dns_records.domains_iter().collect::<Vec<_>>();

    collection::btree_set(
        (sample::select(all_domains.clone()), any::<NonZeroU16>()),
        1..=all_domains.len(),
    )
    .prop_map(move |domains| {
        domains
            .into_iter()
            .filter(|(domain, _)| {
                dns_records
                    .domain_ips_iter(domain, at)
                    .all(|ip| imcp_error_hosts.icmp_error_for_ip(ip).is_none())
            })
            .map({
                let dns_records = dns_records.clone();

                move |(domain, port)| {
                    let addresses = dns_records
                        .domain_ips_iter(&domain, at)
                        .map(|address| SocketAddr::new(address, port.get()))
                        .collect::<BTreeSet<_>>();

                    (domain, addresses)
                }
            })
            .collect()
    })
}

fn create_internet_site(mut sites: BTreeSet<Site>) -> (Site, BTreeSet<Site>) {
    // Rebrand the first site as the Internet site. That way, we can guarantee to always have one.
    let mut internet_site = sites.pop_first().unwrap();
    internet_site.name = "Internet".to_owned();

    (internet_site, sites)
}

pub(crate) fn relays(
    id: impl Strategy<Value = RelayId>,
) -> impl Strategy<Value = BTreeMap<RelayId, Host<u64>>> {
    collection::btree_map(id, ref_relay_host(), 1..=2)
}

/// Sample a list of Do53 servers.
///
/// We make sure to always have at least 1 IPv4 and 1 IPv6 DNS server.
pub(crate) fn do53_servers() -> impl Strategy<Value = BTreeSet<IpAddr>> {
    let ip4_dns_servers =
        collection::btree_set(non_reserved_ipv4().prop_map_into::<IpAddr>(), 1..4);
    let ip6_dns_servers =
        collection::btree_set(non_reserved_ipv6().prop_map_into::<IpAddr>(), 1..4);

    (ip4_dns_servers, ip6_dns_servers).prop_map(|(mut v4, v6)| {
        v4.extend(v6);
        v4
    })
}

pub(crate) fn doh_server() -> impl Strategy<Value = DoHUrl> {
    prop_oneof![
        Just(DoHUrl::quad9()),
        Just(DoHUrl::cloudflare()),
        Just(DoHUrl::google()),
        Just(DoHUrl::opendns()),
    ]
}

pub(crate) fn non_reserved_ip() -> impl Strategy<Value = IpAddr> {
    prop_oneof![
        non_reserved_ipv4().prop_map_into(),
        non_reserved_ipv6().prop_map_into(),
    ]
}

fn non_reserved_ipv4() -> impl Strategy<Value = Ipv4Addr> {
    let undesired_ranges = [
        Ipv4Network::new(Ipv4Addr::BROADCAST, 32).unwrap(),
        Ipv4Network::new(Ipv4Addr::UNSPECIFIED, 32).unwrap(),
        Ipv4Network::new(Ipv4Addr::new(224, 0, 0, 0), 4).unwrap(), // Multicast
        DNS_SENTINELS,
        IPV4_RESOURCES,
        IPV4_TUNNEL,
    ];

    any::<Ipv4Addr>().prop_map(move |mut ip| {
        while let Some(range) = undesired_ranges.iter().find(|range| range.contains(ip)) {
            ip = Ipv4Addr::from(u32::from(range.broadcast_address()).wrapping_add(1));
        }

        debug_assert!(undesired_ranges.iter().all(|range| !range.contains(ip)));

        ip
    })
}

fn non_reserved_ipv6() -> impl Strategy<Value = Ipv6Addr> {
    let undesired_ranges = [
        Ipv6Network::new(Ipv6Addr::UNSPECIFIED, 32).unwrap(),
        IPV6_RESOURCES,
        IPV6_TUNNEL,
        Ipv6Network::new(Ipv6Addr::new(0xff00, 0, 0, 0, 0, 0, 0, 0), 8).unwrap(), // Multicast
    ];

    any::<Ipv6Addr>().prop_map(move |mut ip| {
        while let Some(range) = undesired_ranges.iter().find(|range| range.contains(ip)) {
            ip = Ipv6Addr::from(u128::from(range.last_address()).wrapping_add(1));
        }

        debug_assert!(undesired_ranges.iter().all(|range| !range.contains(ip)));

        ip
    })
}

fn any_site(sites: BTreeSet<Site>) -> impl Strategy<Value = Site> {
    sample::select(Vec::from_iter(sites))
}

fn cidr_resource_outside_reserved_ranges(
    sites: impl Strategy<Value = Site>,
) -> impl Strategy<Value = CidrResource> {
    cidr_resource(
        cidr_resource_address(), sites.prop_map(|s| vec![s]))
        .prop_filter("resource must not be in the documentation range because we use those for host addresses and DNS IPs", |r| !r.address.is_documentation())
}

pub(crate) fn cidr_resource_address() -> impl Strategy<Value = IpNetwork> {
    non_reserved_ip().prop_flat_map(move |ip| ip_network(ip, 8))
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

pub(crate) fn resolved_ips() -> impl Strategy<Value = BTreeSet<OwnedRecordData>> {
    let record = prop_oneof![
        dns_resource_ip4s().prop_map_into(),
        dns_resource_ip6s().prop_map_into()
    ]
    .prop_map(dns_types::records::ip);

    collection::btree_set(record, 1..6)
}

/// A strategy for generating a set of DNS records all nested under the provided base domain.
pub(crate) fn subdomain_records(
    base: String,
    subdomains: impl Strategy<Value = String>,
    at: Instant,
) -> impl Strategy<Value = DnsRecords> {
    collection::hash_map(subdomains, resolved_ips(), 1..4).prop_map(move |subdomain_ips| {
        subdomain_ips
            .into_iter()
            .map(|(label, ips)| {
                let domain = format!("{label}.{base}");

                (domain.parse().unwrap(), BTreeMap::from([(at, ips)]))
            })
            .collect()
    })
}

/// A [`Strategy`] of [`Ipv4Addr`]s used for the "real" IPs of DNS resources.
///
/// This uses the `TEST-NET-2` (`198.51.100.0/24`) address space reserved for documentation and examples in [RFC5737](https://datatracker.ietf.org/doc/html/rfc5737).
/// `TEST-NET-2` only contains 256 addresses which is small enough to generate overlapping IPs for our DNS resources (i.e. two different domains pointing to the same IP).
fn dns_resource_ip4s() -> impl Strategy<Value = Ipv4Addr> {
    const FIRST: Ipv4Addr = Ipv4Addr::new(198, 51, 100, 0);
    const LAST: Ipv4Addr = Ipv4Addr::new(198, 51, 100, 255);

    (FIRST.to_bits()..=LAST.to_bits()).prop_map(Ipv4Addr::from_bits)
}

/// A [`Strategy`] of [`Ipv6Addr`]s used for the "real" IPs of DNS resources.
///
/// This uses a subnet of the `2001:DB8::/32` address space reserved for documentation and examples in [RFC3849](https://datatracker.ietf.org/doc/html/rfc3849).
fn dns_resource_ip6s() -> impl Strategy<Value = Ipv6Addr> {
    const DNS_SUBNET: u16 = 0x2020;

    documentation_ip6s(DNS_SUBNET)
}

pub(crate) fn documentation_ip6s(subnet: u16) -> impl Strategy<Value = Ipv6Addr> {
    let network = Ipv6Network::new_truncate(
        Ipv6Addr::new(0x2001, 0xDB80, subnet, subnet, 0, 0, 0, 0),
        32,
    )
    .unwrap();

    let first = network.network_address().to_bits();
    let last = network.last_address().to_bits();

    (first..=last).prop_map(Ipv6Addr::from_bits)
}

pub(crate) fn system_dns_servers() -> impl Strategy<Value = Vec<IpAddr>> {
    do53_servers().prop_flat_map(|dns_servers| {
        let max = dns_servers.len();

        sample::subsequence(Vec::from_iter(dns_servers), ..=max)
    })
}

pub(crate) fn upstream_do53_servers() -> impl Strategy<Value = Vec<UpstreamDo53>> {
    do53_servers().prop_flat_map(|dns_servers| {
        let max = dns_servers.len();

        sample::subsequence(Vec::from_iter(dns_servers), ..=max)
            .prop_map(|seq| seq.into_iter().map(|ip| UpstreamDo53 { ip }).collect())
    })
}

pub(crate) fn upstream_doh_servers() -> impl Strategy<Value = Vec<UpstreamDoH>> {
    btree_set(doh_server(), 0..2)
        .prop_map(|servers| servers.into_iter().map(|url| UpstreamDoH { url }).collect())
}
