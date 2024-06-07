use super::{PrivateKey, SimNode, SimRelay, Transition};
use crate::tests::PacketSource;
use connlib_shared::{
    messages::{client::ResourceDescriptionDns, DnsServer, RelayId},
    proptest::{dns_resource, domain_label, domain_name},
    DomainName,
};
use hickory_proto::rr::RecordType;
use ip_network::{Ipv4Network, Ipv6Network};
use proptest::{collection, prelude::*, sample};
use std::{
    collections::{HashMap, HashSet},
    fmt,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddrV4, SocketAddrV6},
};

/// Generates a [`Transition`] that sends an ICMP packet to a random IP.
///
/// By chance, it could be that we pick a resource IP here.
/// That is okay as our reference state machine checks separately whether we are pinging a resource here.
pub(crate) fn icmp_to_random_ip() -> impl Strategy<Value = Transition> {
    (any::<IpAddr>(), any::<u16>(), any::<u16>()).prop_map(|(dst, seq, identifier)| {
        Transition::SendICMPPacketToNonResourceIp {
            dst,
            seq,
            identifier,
        }
    })
}

pub(crate) fn icmp_to_cidr_resource() -> impl Strategy<Value = Transition> {
    (
        any::<sample::Index>(),
        any::<u16>(),
        any::<u16>(),
        packet_source(),
    )
        .prop_map(
            move |(r_idx, seq, identifier, src)| Transition::SendICMPPacketToResource {
                idx: r_idx,
                seq,
                identifier,
                src,
            },
        )
}

/// Sample a random [`PacketSource`].
///
/// Packets from random source addresses are tested less frequently.
/// Those are dropped by the gateway so this transition only ensures we have this safe-guard.
pub(crate) fn packet_source() -> impl Strategy<Value = PacketSource> {
    prop_oneof![
        10 => Just(PacketSource::TunnelIp4),
        10 => Just(PacketSource::TunnelIp6),
        1 => any::<IpAddr>().prop_map(PacketSource::Other)
    ]
}

pub(crate) fn icmp_to_resolved_non_resource() -> impl Strategy<Value = Transition> {
    (any::<sample::Index>(), any::<u16>(), any::<u16>()).prop_map(move |(idx, seq, identifier)| {
        Transition::SendICMPPacketToResolvedNonResourceIp {
            idx,
            seq,
            identifier,
        }
    })
}

pub(crate) fn resolved_ips() -> impl Strategy<Value = HashSet<IpAddr>> {
    collection::hash_set(any::<IpAddr>(), 1..6)
}

pub(crate) fn non_wildcard_dns_resource() -> impl Strategy<Value = Transition> {
    (dns_resource(), resolved_ips()).prop_map(|(resource, resolved_ips)| {
        Transition::AddDnsResource {
            records: HashMap::from([(resource.address.parse().unwrap(), resolved_ips)]),
            resource,
        }
    })
}

pub(crate) fn star_wildcard_dns_resource() -> impl Strategy<Value = Transition> {
    dns_resource().prop_flat_map(|r| {
        let wildcard_address = format!("*.{}", r.address);

        let records = subdomain_records(r.address, domain_name(1..3));
        let resource = Just(ResourceDescriptionDns {
            address: wildcard_address,
            ..r
        });

        (resource, records)
            .prop_map(|(resource, records)| Transition::AddDnsResource { records, resource })
    })
}

pub(crate) fn question_mark_wildcard_dns_resource() -> impl Strategy<Value = Transition> {
    dns_resource().prop_flat_map(|r| {
        let wildcard_address = format!("?.{}", r.address);

        let records = subdomain_records(r.address, domain_label());
        let resource = Just(ResourceDescriptionDns {
            address: wildcard_address,
            ..r
        });

        (resource, records)
            .prop_map(|(resource, records)| Transition::AddDnsResource { records, resource })
    })
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

pub(crate) fn dns_query() -> impl Strategy<Value = Transition> {
    (
        any::<sample::Index>(),
        any::<sample::Index>(),
        prop_oneof![Just(RecordType::A), Just(RecordType::AAAA)],
        any::<u16>(),
    )
        .prop_map(
            move |(r_idx, dns_server_idx, r_type, query_id)| Transition::SendDnsQuery {
                r_idx,
                r_type,
                query_id,
                dns_server_idx,
            },
        )
}

/// Generates an IPv4 address for the tunnel interface.
///
/// We use the CG-NAT range for IPv4.
/// See <https://github.com/firezone/firezone/blob/81dfa90f38299595e14ce9e022d1ee919909f124/elixir/apps/domain/lib/domain/network.ex#L7>.
pub(crate) fn tunnel_ip4() -> impl Strategy<Value = Ipv4Addr> {
    any::<sample::Index>().prop_map(|idx| {
        let cgnat_block = Ipv4Network::new(Ipv4Addr::new(100, 64, 0, 0), 11).unwrap();

        let mut hosts = cgnat_block.hosts();

        hosts.nth(idx.index(hosts.len())).unwrap()
    })
}

/// Generates an IPv6 address for the tunnel interface.
///
/// See <https://github.com/firezone/firezone/blob/81dfa90f38299595e14ce9e022d1ee919909f124/elixir/apps/domain/lib/domain/network.ex#L8>.
pub(crate) fn tunnel_ip6() -> impl Strategy<Value = Ipv6Addr> {
    any::<sample::Index>().prop_map(|idx| {
        let cgnat_block =
            Ipv6Network::new(Ipv6Addr::new(64_768, 8_225, 4_369, 0, 0, 0, 0, 0), 107).unwrap();

        let mut subnets = cgnat_block.subnets_with_prefix(128);

        subnets
            .nth(idx.index(subnets.len()))
            .unwrap()
            .network_address()
    })
}

pub(crate) fn sim_node_prototype<ID>(
    id: impl Strategy<Value = ID>,
) -> impl Strategy<Value = SimNode<ID, PrivateKey>>
where
    ID: fmt::Debug,
{
    (
        id,
        any::<[u8; 32]>(),
        firezone_relay::proptest::any_ip_stack(), // We are re-using the strategy here because it is exactly what we need although we are generating a node here and not a relay.
        any::<u16>().prop_filter("port must not be 0", |p| *p != 0),
        any::<u16>().prop_filter("port must not be 0", |p| *p != 0),
        tunnel_ip4(),
        tunnel_ip6(),
    )
        .prop_filter_map(
            "must have at least one socket address",
            |(id, key, ip_stack, v4_port, v6_port, tunnel_ip4, tunnel_ip6)| {
                let ip4_socket = ip_stack.as_v4().map(|ip| SocketAddrV4::new(*ip, v4_port));
                let ip6_socket = ip_stack
                    .as_v6()
                    .map(|ip| SocketAddrV6::new(*ip, v6_port, 0, 0));

                Some(SimNode::new(
                    id,
                    PrivateKey(key),
                    ip4_socket,
                    ip6_socket,
                    tunnel_ip4,
                    tunnel_ip6,
                ))
            },
        )
}

pub(crate) fn sim_relay_prototype() -> impl Strategy<Value = SimRelay<u64>> {
    (
        any::<u64>(),
        firezone_relay::proptest::dual_ip_stack(), // For this test, our relays always run in dual-stack mode to ensure connectivity!
        any::<u128>(),
    )
        .prop_map(|(seed, ip_stack, id)| SimRelay::new(RelayId::from_u128(id), seed, ip_stack))
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

pub(crate) fn global_dns_records() -> impl Strategy<Value = HashMap<DomainName, HashSet<IpAddr>>> {
    collection::hash_map(
        domain_name(2..4).prop_map(|d| d.parse().unwrap()),
        collection::hash_set(any::<IpAddr>(), 1..6),
        0..15,
    )
}
