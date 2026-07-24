use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use connlib_model::IpStack;
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use tunnel_proto::messages::{Filter, PortRange, UpstreamDo53, UpstreamDoH};

use super::context::Generator;
use super::packets::{host_in_v4, host_in_v6};
use crate::reference::ReferenceState;

/// Generate at least one IPv4 and one IPv6 Do53 server.
pub(super) fn arb_do53_pool(g: &mut Generator) -> Vec<IpAddr> {
    let n4 = g.count(1, 3);
    let n6 = g.count(1, 3);
    (0..n4 + n6)
        .map(|i| {
            if i < n4 {
                IpAddr::V4(g.do53_ip4())
            } else {
                IpAddr::V6(g.do53_ip6())
            }
        })
        .collect::<Vec<_>>()
}

/// Per-element keep-bit subset of a fresh do53 pool that keeps at least one
/// server per address family, so DNS queries stay possible regardless of the
/// client's socket stack. 10% of the time the subset is deliberately empty to
/// keep the no-DNS-servers edge reachable.
pub(super) fn arb_do53_subset(g: &mut Generator) -> Vec<IpAddr> {
    let pool = arb_do53_pool(g);

    if g.flip(10) {
        return Vec::new();
    }

    let subset = pool
        .iter()
        .copied()
        .filter(|_| g.bool())
        .collect::<Vec<_>>();
    let has_ipv4 = subset.iter().any(IpAddr::is_ipv4);
    let has_ipv6 = subset.iter().any(IpAddr::is_ipv6);

    subset
        .into_iter()
        .chain(
            pool.iter()
                .find(|ip| ip.is_ipv4())
                .filter(|_| !has_ipv4)
                .copied(),
        )
        .chain(
            pool.iter()
                .find(|ip| ip.is_ipv6())
                .filter(|_| !has_ipv6)
                .copied(),
        )
        .collect::<Vec<_>>()
}

pub(super) fn arb_system_dns_servers(g: &mut Generator) -> Vec<IpAddr> {
    arb_do53_subset(g)
}

pub(super) fn arb_upstream_do53_servers(g: &mut Generator) -> Vec<UpstreamDo53> {
    arb_do53_subset(g)
        .into_iter()
        .map(|ip| UpstreamDo53 { ip })
        .collect::<Vec<_>>()
}

pub(super) fn arb_compatible_upstream_do53_servers(
    g: &mut Generator,
    state: &ReferenceState,
) -> Vec<UpstreamDo53> {
    let clients_share_ipv4 = state.clients.values().all(|client| client.ip4.is_some());
    let clients_share_ipv6 = state.clients.values().all(|client| client.ip6.is_some());

    arb_upstream_do53_servers(g)
        .into_iter()
        .filter(|server| {
            (server.ip.is_ipv4() && clients_share_ipv4)
                || (server.ip.is_ipv6() && clients_share_ipv6)
        })
        .collect::<Vec<_>>()
}

pub(super) fn arb_upstream_doh_servers(g: &mut Generator) -> Vec<UpstreamDoH> {
    // Generate at most one DoH server.
    let n = g.count(0, 1);
    (0..n)
        .map(|_| {
            let url = match g.choose_index(4) {
                0 => dns_types::DoHUrl::quad9(),
                1 => dns_types::DoHUrl::cloudflare(),
                2 => dns_types::DoHUrl::google(),
                _ => dns_types::DoHUrl::opendns(),
            };
            UpstreamDoH { url }
        })
        .collect::<Vec<_>>()
}

pub(super) fn arb_filters(g: &mut Generator) -> Vec<Filter> {
    let n = g.count(0, 2);
    (0..n).map(|_| arb_filter(g)).collect::<Vec<_>>()
}

pub(super) fn arb_different_filters(g: &mut Generator, current: &[Filter]) -> Vec<Filter> {
    let filters = arb_filters(g);

    if filters != current {
        return filters;
    }

    if filters.is_empty() {
        vec![Filter::Icmp]
    } else {
        Vec::new()
    }
}

pub(super) fn arb_filter(g: &mut Generator) -> Filter {
    match g.choose_index(3) {
        0 => Filter::Icmp,
        1 => Filter::Udp(arb_port_range(g)),
        _ => Filter::Tcp(arb_port_range(g)),
    }
}

pub(super) fn arb_port_range(g: &mut Generator) -> PortRange {
    let start = g.u16();
    let end = g.u16_in(start..=u16::MAX);
    PortRange {
        port_range_start: start,
        port_range_end: end,
    }
}

pub(super) fn arb_address_description(g: &mut Generator) -> Option<String> {
    if g.bool() {
        Some(g.lower_ascii(4, 10))
    } else {
        None
    }
}

pub(super) fn arb_ip_stack_kind(g: &mut Generator) -> IpStack {
    match g.choose_index(3) {
        0 => IpStack::Dual,
        1 => IpStack::Ipv4Only,
        _ => IpStack::Ipv6Only,
    }
}

pub(super) fn arb_domain_name_string(g: &mut Generator, lo: usize, hi: usize) -> String {
    let n = g.count(lo, hi);
    (0..n)
        .map(|_| g.lower_ascii(3, 6))
        .collect::<Vec<_>>()
        .join(".")
}

/// The IP ranges that DNS records (resource + global) resolve into, plus the host
/// socket ranges and the DNS sentinel ranges.
///
/// CIDR / Internet resource addresses must avoid these: a resource whose range
/// contains a DNS-resolvable IP (or a sentinel) makes the reference (which routes
/// a `Destination::DomainName` by domain) and the SUT (which routes by the
/// resolved IP) disagree on the gateway. Defining a resource inside the DNS
/// sentinel range is also explicitly unsupported by connlib.
pub(super) fn cidr_reserved_v4() -> [Ipv4Network; 4] {
    use tunnel_proto::DNS_SENTINELS_V4;
    [
        "192.0.2.0/24".parse::<Ipv4Network>().unwrap(), // TEST-NET-1 (documentation)
        "198.51.100.0/24".parse::<Ipv4Network>().unwrap(), // TEST-NET-2 (DNS resource real IPs)
        "203.0.113.0/24".parse::<Ipv4Network>().unwrap(), // TEST-NET-3 (host socket IPs)
        DNS_SENTINELS_V4,                               // 100.100.111.0/24
    ]
}

pub(super) fn cidr_reserved_v6() -> [Ipv6Network; 3] {
    use tunnel_proto::DNS_SENTINELS_V6;
    [
        // The host (`2001:db80:1010:1010::/64`) and DNS (`2001:db80:2020:2020::/64`)
        // documentation subnets both live under `2001:db80::/32`.
        Ipv6Network::new_truncate(Ipv6Addr::new(0x2001, 0xDB80, 0, 0, 0, 0, 0, 0), 32).unwrap(),
        Ipv6Network::new_truncate(Ipv6Addr::new(0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0), 32).unwrap(),
        DNS_SENTINELS_V6, // fd00:2021:1111:8000:100:100:111:0/120
    ]
}

pub(super) fn overlapping_reserved_v4(net: Ipv4Network) -> Option<Ipv4Network> {
    cidr_reserved_v4().into_iter().find(|reserved| {
        reserved.contains(net.network_address()) || net.contains(reserved.network_address())
    })
}

pub(super) fn overlapping_reserved_v6(net: Ipv6Network) -> Option<Ipv6Network> {
    cidr_reserved_v6().into_iter().find(|reserved| {
        reserved.contains(net.network_address()) || net.contains(reserved.network_address())
    })
}

/// A CIDR address outside all reserved + documentation + DNS + sentinel ranges
/// (so it never overlaps the host / DNS / tunnel / sentinel ranges).
///
/// Wrap-around repair, no rejection loop: at most `cidr_reserved_*().len()`
/// advances, since each advance moves the network strictly past one reserved
/// range and the ranges are disjoint.
pub(super) fn arb_cidr_resource_address(g: &mut Generator) -> IpNetwork {
    let ip = arb_non_reserved_ip(g);
    // Keep generated networks small enough to materialize individual hosts.
    let mask_offset = g.count(0, 8);
    match ip {
        IpAddr::V4(v4) => {
            let netmask = 32 - mask_offset as u8;
            let net = std::iter::successors(
                Some(Ipv4Network::new_truncate(v4, netmask).unwrap()),
                |network| {
                    let reserved = overlapping_reserved_v4(*network)?;
                    let next = u32::from(reserved.broadcast_address()).wrapping_add(1);
                    Ipv4Network::new_truncate(Ipv4Addr::from(next), netmask).ok()
                },
            )
            .find(|network| overlapping_reserved_v4(*network).is_none())
            .expect("reserved IPv4 ranges are finite");
            IpNetwork::V4(net)
        }
        IpAddr::V6(v6) => {
            let netmask = 128 - mask_offset as u8;
            let net = std::iter::successors(
                Some(Ipv6Network::new_truncate(v6, netmask).unwrap()),
                |network| {
                    let reserved = overlapping_reserved_v6(*network)?;
                    let next = u128::from(reserved.last_address()).wrapping_add(1);
                    Ipv6Network::new_truncate(Ipv6Addr::from(next), netmask).ok()
                },
            )
            .find(|network| overlapping_reserved_v6(*network).is_none())
            .expect("reserved IPv6 ranges are finite");
            IpNetwork::V6(net)
        }
    }
}

pub(super) fn arb_different_cidr_resource_address(
    g: &mut Generator,
    current: IpNetwork,
) -> IpNetwork {
    let address = arb_cidr_resource_address(g);

    if address != current {
        return address;
    }

    match current {
        IpNetwork::V4(_) => IpNetwork::V6(
            Ipv6Network::new(Ipv6Addr::new(0x2001, 0xDB81, 0, 0, 0, 0, 0, 1), 128).unwrap(),
        ),
        IpNetwork::V6(_) => {
            IpNetwork::V4(Ipv4Network::new(Ipv4Addr::new(192, 0, 3, 1), 32).unwrap())
        }
    }
}

pub(super) fn arb_more_specific_subnet(
    g: &mut Generator,
    address: IpNetwork,
    extra_bits: usize,
) -> IpNetwork {
    // Pick a host within `address`, then a longer prefix.
    let add = g.count(1, extra_bits.max(1));
    match address {
        IpNetwork::V4(n) => {
            let ip = host_in_v4(g, n);
            let netmask = (n.netmask() as usize + add).min(32) as u8;
            IpNetwork::new_truncate(IpAddr::V4(ip), netmask).unwrap()
        }
        IpNetwork::V6(n) => {
            let ip = host_in_v6(g, n);
            let netmask = (n.netmask() as usize + add).min(128) as u8;
            IpNetwork::new_truncate(IpAddr::V6(ip), netmask).unwrap()
        }
    }
}

/// An IP outside connlib's reserved ranges, via wrap-around repair (no rejection).
pub(super) fn arb_non_reserved_ip(g: &mut Generator) -> IpAddr {
    use tunnel_proto::{
        DNS_SENTINELS_V4, DNS_SENTINELS_V6, IPV4_RESOURCES, IPV4_TUNNEL, IPV6_RESOURCES,
        IPV6_TUNNEL,
    };

    if g.bool() {
        let undesired = [
            Ipv4Network::new(Ipv4Addr::BROADCAST, 32).unwrap(),
            Ipv4Network::new(Ipv4Addr::UNSPECIFIED, 32).unwrap(),
            Ipv4Network::new(Ipv4Addr::new(224, 0, 0, 0), 4).unwrap(),
            DNS_SENTINELS_V4,
            IPV4_RESOURCES,
            IPV4_TUNNEL,
        ];
        let ip = std::iter::successors(Some(Ipv4Addr::from(g.u32())), |ip| {
            let range = undesired.iter().find(|range| range.contains(*ip))?;
            Some(Ipv4Addr::from(
                u32::from(range.broadcast_address()).wrapping_add(1),
            ))
        })
        .find(|ip| undesired.iter().all(|range| !range.contains(*ip)))
        .expect("undesired IPv4 ranges are finite");
        IpAddr::V4(ip)
    } else {
        let undesired = [
            Ipv6Network::new(Ipv6Addr::UNSPECIFIED, 32).unwrap(),
            DNS_SENTINELS_V6,
            IPV6_RESOURCES,
            IPV6_TUNNEL,
            Ipv6Network::new(Ipv6Addr::new(0xff00, 0, 0, 0, 0, 0, 0, 0), 8).unwrap(),
        ];
        let hi = (g.u64() as u128) << 64;
        let lo = g.u64() as u128;
        let ip = std::iter::successors(Some(Ipv6Addr::from(hi | lo)), |ip| {
            let range = undesired.iter().find(|range| range.contains(*ip))?;
            Some(Ipv6Addr::from(
                u128::from(range.last_address()).wrapping_add(1),
            ))
        })
        .find(|ip| undesired.iter().all(|range| !range.contains(*ip)))
        .expect("undesired IPv6 ranges are finite");
        IpAddr::V6(ip)
    }
}
