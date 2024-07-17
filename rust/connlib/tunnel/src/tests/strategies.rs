use super::{
    sim_gateway::{ref_gateway_host, RefGateway},
    sim_net::Host,
    stub_portal::StubPortal,
};
use connlib_shared::{
    messages::{client::SiteId, DnsServer, GatewayId},
    proptest::{domain_name, gateway_id, site},
    DomainName,
};
use ip_network::{Ipv4Network, Ipv6Network};
use prop::sample;
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

/// An [`Iterator`] over the possible IPv4 addresses of a tunnel interface.
///
/// We use the CG-NAT range for IPv4.
/// See <https://github.com/firezone/firezone/blob/81dfa90f38299595e14ce9e022d1ee919909f124/elixir/apps/domain/lib/domain/network.ex#L7>.
pub(crate) fn tunnel_ip4s() -> impl Iterator<Item = Ipv4Addr> {
    Ipv4Network::new(Ipv4Addr::new(100, 64, 0, 0), 11)
        .unwrap()
        .hosts()
}

/// An [`Iterator`] over the possible IPv6 addresses of a tunnel interface.
///
/// See <https://github.com/firezone/firezone/blob/81dfa90f38299595e14ce9e022d1ee919909f124/elixir/apps/domain/lib/domain/network.ex#L8>.
pub(crate) fn tunnel_ip6s() -> impl Iterator<Item = Ipv6Addr> {
    Ipv6Network::new(Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 0), 107)
        .unwrap()
        .subnets_with_prefix(128)
        .map(|n| n.network_address())
}

/// A [`Strategy`] for sampling a set of gateways and a corresponding [`StubPortal`] that has a set of [`Site`]s configured with those gateways.
pub(crate) fn gateways_and_portal(
) -> impl Strategy<Value = (HashMap<GatewayId, Host<RefGateway>>, StubPortal)> {
    collection::hash_set(site(), 1..=3)
        .prop_flat_map(|sites| {
            let gateway_site = sample::select(sites.iter().map(|s| s.id).collect::<Vec<_>>());

            let gateways =
                collection::hash_map(gateway_id(), (ref_gateway_host(), gateway_site), 1..=3);
            let gateway_selector = any::<sample::Selector>();

            (gateways, Just(sites), gateway_selector)
        })
        .prop_map(|(gateways, sites, gateway_selector)| {
            let (gateways, gateways_by_site) = gateways.into_iter().fold(
                (
                    HashMap::<GatewayId, _>::default(),
                    HashMap::<SiteId, HashSet<GatewayId>>::default(),
                ),
                |(mut gateways, mut sites), (gid, (gateway, site))| {
                    sites.entry(site).or_default().insert(gid);
                    gateways.insert(gid, gateway);

                    (gateways, sites)
                },
            );
            let portal = StubPortal::new(gateways_by_site, sites, gateway_selector);

            (gateways, portal)
        })
}
