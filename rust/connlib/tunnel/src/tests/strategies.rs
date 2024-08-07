use super::{
    sim_dns::{dns_server_id, ref_dns_host, DnsServerId, RefDns},
    sim_net::Host,
    sim_relay::ref_relay_host,
    stub_portal::StubPortal,
};
use crate::client::{IPV4_RESOURCES, IPV6_RESOURCES};
use connlib_shared::{
    messages::{
        client::{
            ResourceDescriptionCidr, ResourceDescriptionDns, ResourceDescriptionInternet, Site,
            SiteId,
        },
        GatewayId, RelayId,
    },
    proptest::{
        any_ip_network, cidr_resource, dns_resource, domain_name, gateway_id, relay_id, site,
    },
    DomainName,
};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use itertools::Itertools;
use prop::sample;
use proptest::{collection, prelude::*};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::Duration,
};

pub(crate) fn global_dns_records() -> impl Strategy<Value = BTreeMap<DomainName, HashSet<IpAddr>>> {
    collection::btree_map(
        domain_name(2..4).prop_map(|d| d.parse().unwrap()),
        collection::hash_set(any::<IpAddr>(), 1..6),
        0..5,
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

pub(crate) fn latency(max: u64) -> impl Strategy<Value = Duration> {
    (10..max).prop_map(Duration::from_millis)
}

/// A [`Strategy`] for sampling a [`StubPortal`] that is configured with various [`Site`]s and gateways within those sites.
///
/// Similar as in production, the portal holds a list of DNS and CIDR resources (those are also sampled from the given sites).
/// Via this site mapping, these resources are implicitly assigned to a gateway.
pub(crate) fn stub_portal() -> impl Strategy<Value = StubPortal> {
    collection::hash_set(site(), 1..=3)
        .prop_flat_map(|sites| {
            let gateway_site = any_site(sites.clone()).prop_map(|s| s.id);
            let cidr_resources = collection::hash_set(
                cidr_resource_outside_reserved_ranges(any_site(sites.clone())),
                1..5,
            );
            let dns_resources = collection::hash_set(
                prop_oneof![
                    non_wildcard_dns_resource(any_site(sites.clone())),
                    star_wildcard_dns_resource(any_site(sites.clone())),
                    question_mark_wildcard_dns_resource(any_site(sites.clone())),
                ],
                1..5,
            );
            let internet_resource = internet_resource(any_site(sites));

            // Gateways are unique across sites.
            // Generate a map with `GatewayId`s as keys and then flip it into a map of site -> set(gateways).
            let gateways_by_site = collection::hash_map(gateway_id(), gateway_site, 1..=3)
                .prop_map(|gateway_site| {
                    let mut gateways_by_site = HashMap::<SiteId, HashSet<GatewayId>>::default();

                    for (gid, sid) in gateway_site {
                        gateways_by_site.entry(sid).or_default().insert(gid);
                    }

                    gateways_by_site
                });

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

pub(crate) fn relays() -> impl Strategy<Value = BTreeMap<RelayId, Host<u64>>> {
    collection::btree_map(relay_id(), ref_relay_host(), 1..=2)
}

/// Sample a list of DNS servers.
///
/// We make sure to always have at least 1 IPv4 and 1 IPv6 DNS server.
pub(crate) fn dns_servers() -> impl Strategy<Value = BTreeMap<DnsServerId, Host<RefDns>>> {
    let ip4_dns_servers = collection::hash_set(
        any::<Ipv4Addr>().prop_map(|ip| SocketAddr::from((ip, 53))),
        1..4,
    );
    let ip6_dns_servers = collection::hash_set(
        any::<Ipv6Addr>().prop_map(|ip| SocketAddr::from((ip, 53))),
        1..4,
    );

    (ip4_dns_servers, ip6_dns_servers).prop_flat_map(|(ip4_dns_servers, ip6_dns_servers)| {
        let servers = Vec::from_iter(ip4_dns_servers.into_iter().chain(ip6_dns_servers));

        // First, generate a unique number of IDs, one for each DNS server.
        let ids = collection::hash_set(dns_server_id(), servers.len());

        (ids, Just(servers))
            .prop_flat_map(move |(ids, servers)| {
                let ids = ids.into_iter();

                // Second, zip the IDs and addresses together.
                ids.zip(servers)
                    .map(|(id, addr)| (Just(id), ref_dns_host(addr)))
                    .collect::<Vec<_>>()
            })
            .prop_map(BTreeMap::from_iter) // Third, turn the `Vec` of tuples into a `BTreeMap`.
    })
}

fn any_site(sites: HashSet<Site>) -> impl Strategy<Value = Site> {
    sample::select(Vec::from_iter(sites))
}

fn cidr_resource_outside_reserved_ranges(
    sites: impl Strategy<Value = Site>,
) -> impl Strategy<Value = ResourceDescriptionCidr> {
    cidr_resource(any_ip_network(8), sites.prop_map(|s| vec![s]))
        .prop_filter(
            "tests doesn't support yet CIDR resources overlapping DNS resources",
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

fn internet_resource(
    site: impl Strategy<Value = Site>,
) -> impl Strategy<Value = ResourceDescriptionInternet> {
    connlib_shared::proptest::internet_resource(site.prop_map(|s| vec![s]))
}

fn non_wildcard_dns_resource(
    site: impl Strategy<Value = Site>,
) -> impl Strategy<Value = ResourceDescriptionDns> {
    dns_resource(site.prop_map(|s| vec![s]))
}

fn star_wildcard_dns_resource(
    site: impl Strategy<Value = Site>,
) -> impl Strategy<Value = ResourceDescriptionDns> {
    dns_resource(site.prop_map(|s| vec![s])).prop_map(|r| ResourceDescriptionDns {
        address: format!("*.{}", r.address),
        ..r
    })
}

fn question_mark_wildcard_dns_resource(
    site: impl Strategy<Value = Site>,
) -> impl Strategy<Value = ResourceDescriptionDns> {
    dns_resource(site.prop_map(|s| vec![s])).prop_map(|r| ResourceDescriptionDns {
        address: format!("?.{}", r.address),
        ..r
    })
}

pub(crate) fn resolved_ips() -> impl Strategy<Value = HashSet<IpAddr>> {
    collection::hash_set(
        prop_oneof![
            dns_resource_ip4s().prop_map_into(),
            dns_resource_ip6s().prop_map_into()
        ],
        1..6,
    )
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
