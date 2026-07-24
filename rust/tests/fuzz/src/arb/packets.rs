use std::{
    collections::BTreeSet,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::Instant,
};

use connlib_model::ClientId;
use dns_types::DomainName;
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_packet::Protocol;
use tunnel_proto::messages::{Filter, PortRange, client::DevicePoolMember};

use super::context::Generator;
use crate::reference::ReferenceState;
use crate::resource::StaticDevicePoolResource;
use crate::transition::{Destination, Transition};

/// The semantic destination selected by the state-aware grammar.
///
/// This deliberately remains more structured than an arbitrary IP packet. The
/// SUT still has to classify the materialized destination, while the generator
/// and reference model retain enough intent to reason about the action without
/// reproducing all of the production classifier's inputs from raw bytes.
#[derive(Clone)]
pub(super) enum PacketTarget {
    Cidr {
        client_id: ClientId,
        src: IpAddr,
        network: IpNetwork,
        filters: Vec<Filter>,
    },
    Dns {
        client_id: ClientId,
        src: IpAddr,
        domain: DomainName,
        filters: Vec<Filter>,
        tcp_service_ports: Vec<u16>,
    },
    NonResource {
        client_id: ClientId,
        src: IpAddr,
        dst: IpAddr,
    },
    ConnectedGateway {
        client_id: ClientId,
        src: IpAddr,
        network: IpNetwork,
    },
    Peer {
        client_id: ClientId,
        src: IpAddr,
        dst: IpAddr,
        filters: Vec<Filter>,
    },
}

#[derive(Clone)]
enum DstSpec {
    Domain(DomainName),
    Ip(IpAddr),
}

pub(super) fn targets(state: &ReferenceState, now: Instant) -> Vec<PacketTarget> {
    state
        .ipv4_cidr_resource_dsts()
        .into_iter()
        .map(|(client_id, network, filters)| PacketTarget::Cidr {
            client_id,
            src: IpAddr::V4(state.clients[&client_id].inner().tunnel_ip4),
            network: network.into(),
            filters,
        })
        .chain(
            state
                .ipv6_cidr_resource_dsts()
                .into_iter()
                .map(|(client_id, network, filters)| PacketTarget::Cidr {
                    client_id,
                    src: IpAddr::V6(state.clients[&client_id].inner().tunnel_ip6),
                    network: network.into(),
                    filters,
                }),
        )
        .chain(
            state
                .resolved_v4_domains()
                .into_iter()
                .map(|(client_id, domain, filters)| PacketTarget::Dns {
                    client_id,
                    src: IpAddr::V4(state.clients[&client_id].inner().tunnel_ip4),
                    tcp_service_ports: tcp_service_ports(state, &domain, true),
                    domain,
                    filters,
                }),
        )
        .chain(
            state
                .resolved_v6_domains()
                .into_iter()
                .map(|(client_id, domain, filters)| PacketTarget::Dns {
                    client_id,
                    src: IpAddr::V6(state.clients[&client_id].inner().tunnel_ip6),
                    tcp_service_ports: tcp_service_ports(state, &domain, false),
                    domain,
                    filters,
                }),
        )
        .chain(
            state
                .resolved_ip4_for_non_resources(&state.global_dns_records, now)
                .into_iter()
                .map(|(client_id, dst)| PacketTarget::NonResource {
                    client_id,
                    src: IpAddr::V4(state.clients[&client_id].inner().tunnel_ip4),
                    dst: IpAddr::V4(dst),
                }),
        )
        .chain(
            state
                .resolved_ip6_for_non_resources(&state.global_dns_records, now)
                .into_iter()
                .map(|(client_id, dst)| PacketTarget::NonResource {
                    client_id,
                    src: IpAddr::V6(state.clients[&client_id].inner().tunnel_ip6),
                    dst: IpAddr::V6(dst),
                }),
        )
        .chain(
            state
                .connected_gateway_ipv4_ips()
                .into_iter()
                .map(|(client_id, network)| PacketTarget::ConnectedGateway {
                    client_id,
                    src: IpAddr::V4(state.clients[&client_id].inner().tunnel_ip4),
                    network: network.into(),
                }),
        )
        .chain(
            state
                .connected_gateway_ipv6_ips()
                .into_iter()
                .map(|(client_id, network)| PacketTarget::ConnectedGateway {
                    client_id,
                    src: IpAddr::V6(state.clients[&client_id].inner().tunnel_ip6),
                    network: network.into(),
                }),
        )
        .chain(state.pool_routed_other_client_tun_ips().into_iter().map(
            |(client_id, dst, filters)| {
                let client = state.clients[&client_id].inner();
                let src = match dst {
                    IpAddr::V4(_) => IpAddr::V4(client.tunnel_ip4),
                    IpAddr::V6(_) => IpAddr::V6(client.tunnel_ip6),
                };
                PacketTarget::Peer {
                    client_id,
                    src,
                    dst,
                    filters,
                }
            },
        ))
        .collect::<Vec<_>>()
}

fn tcp_service_ports(state: &ReferenceState, domain: &DomainName, ipv4: bool) -> Vec<u16> {
    state
        .tcp_resources
        .get(domain)
        .into_iter()
        .flatten()
        .filter(|address| address.is_ipv4() == ipv4)
        .map(SocketAddr::port)
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>()
}

pub(super) fn generate(
    g: &mut Generator,
    state: &ReferenceState,
    target: PacketTarget,
) -> Transition {
    match target {
        PacketTarget::Cidr {
            client_id,
            src,
            network,
            filters,
        } => {
            let dst = DstSpec::Ip(host_in_network(g, network));
            arb_filtered_packet(g, state, client_id, src, dst, &filters)
        }
        PacketTarget::Dns {
            client_id,
            src,
            domain,
            filters,
            tcp_service_ports,
        } => {
            let can_connect_tcp = filters.is_empty()
                || filters
                    .iter()
                    .any(|filter| matches!(filter, Filter::Tcp(_)));

            if can_connect_tcp && !tcp_service_ports.is_empty() && g.bool() {
                arb_tcp_connection(
                    g,
                    state,
                    client_id,
                    src,
                    domain,
                    &filters,
                    &tcp_service_ports,
                )
            } else {
                arb_filtered_packet(g, state, client_id, src, DstSpec::Domain(domain), &filters)
            }
        }
        PacketTarget::NonResource {
            client_id,
            src,
            dst,
        } => arb_unfiltered_packet(g, state, client_id, src, dst, true),
        PacketTarget::ConnectedGateway {
            client_id,
            src,
            network,
        } => {
            let dst = host_in_network(g, network);
            arb_unfiltered_packet(g, state, client_id, src, dst, false)
        }
        PacketTarget::Peer {
            client_id,
            src,
            dst,
            filters,
        } => arb_filtered_packet(g, state, client_id, src, DstSpec::Ip(dst), &filters),
    }
}

fn host_in_network(g: &mut Generator, network: IpNetwork) -> IpAddr {
    match network {
        IpNetwork::V4(network) => IpAddr::V4(host_in_v4(g, network)),
        IpNetwork::V6(network) => IpAddr::V6(host_in_v6(g, network)),
    }
}

pub(super) fn host_in_v4(g: &mut Generator, network: Ipv4Network) -> Ipv4Addr {
    let host_bits = 32 - network.netmask();
    let base = u32::from(network.network_address());
    let off = if host_bits == 0 {
        0
    } else if host_bits >= 32 {
        g.u32()
    } else {
        g.u32() % (1u32 << host_bits)
    };
    Ipv4Addr::from(base.wrapping_add(off))
}

pub(super) fn host_in_v6(g: &mut Generator, network: Ipv6Network) -> Ipv6Addr {
    let host_bits = 128 - network.netmask();
    let base = u128::from(network.network_address());
    let off = if host_bits == 0 {
        0
    } else {
        let hi = (g.u64() as u128) << 64;
        let lo = g.u64() as u128;
        let mask = if host_bits >= 128 {
            u128::MAX
        } else {
            (1u128 << host_bits) - 1
        };
        (hi | lo) & mask
    };
    Ipv6Addr::from(base.wrapping_add(off))
}

/// Generate a packet for a resource-like destination. Most draws use a filter
/// that admits the packet; the remainder deliberately exercise the drop path.
fn arb_filtered_packet(
    g: &mut Generator,
    state: &ReferenceState,
    client_id: ClientId,
    src: IpAddr,
    dst: DstSpec,
    filters: &[Filter],
) -> Transition {
    let usable = filters
        .iter()
        .filter(|f| !matches!(f, Filter::Tcp(_)))
        .filter(|f| {
            !matches!(
                f,
                Filter::Udp(PortRange {
                    port_range_start: 53,
                    port_range_end: 53,
                })
            )
        })
        .copied()
        .collect::<Vec<_>>();

    let use_matching = !usable.is_empty() && g.flip(80);

    if use_matching {
        let filter = usable[g.choose_index(usable.len())];
        match filter {
            Filter::Icmp => arb_icmp_packet(g, state, client_id, src, dst),
            Filter::Udp(PortRange {
                port_range_start,
                port_range_end,
            }) => {
                let dport = g.u16_in(port_range_start..=port_range_end);
                arb_udp_packet(g, state, client_id, src, dst, dport)
            }
            Filter::Tcp(_) => unreachable!("TCP filters were excluded above"),
        }
    } else {
        if g.bool() {
            arb_icmp_packet(g, state, client_id, src, dst)
        } else {
            let dport = arb_non_dns_port(g);
            arb_udp_packet(g, state, client_id, src, dst, dport)
        }
    }
}

fn arb_tcp_connection(
    g: &mut Generator,
    state: &ReferenceState,
    client_id: ClientId,
    src: IpAddr,
    domain: DomainName,
    filters: &[Filter],
    service_ports: &[u16],
) -> Transition {
    let tcp_filters = filters
        .iter()
        .filter_map(|f| match f {
            Filter::Tcp(r) => Some(*r),
            Filter::Udp(_) | Filter::Icmp => None,
        })
        .collect::<Vec<_>>();

    let matching_service_ports = service_ports
        .iter()
        .copied()
        .filter(|port| {
            filters.is_empty()
                || tcp_filters
                    .iter()
                    .any(|range| (range.port_range_start..=range.port_range_end).contains(port))
        })
        .collect::<Vec<_>>();

    let dport = if !matching_service_ports.is_empty() && g.flip(75) {
        matching_service_ports[g.choose_index(matching_service_ports.len())]
    } else if !tcp_filters.is_empty() {
        let r = tcp_filters[g.choose_index(tcp_filters.len())];
        g.u16_in(r.port_range_start..=r.port_range_end)
    } else {
        arb_non_dns_port(g).max(1)
    };

    let (sport, dport) = g.fresh_tcp_connection(dport);
    let dst = arb_destination(g, DstSpec::Domain(domain));
    let expected_route = state.route_for_packet(client_id, &dst, Protocol::Tcp(dport.0));
    Transition::ConnectTcp {
        client_id,
        src,
        dst,
        expected_route,
        sport,
        dport,
    }
}

fn arb_unfiltered_packet(
    g: &mut Generator,
    state: &ReferenceState,
    client_id: ClientId,
    src: IpAddr,
    dst: IpAddr,
    allow_dns_ports: bool,
) -> Transition {
    if g.bool() {
        arb_icmp_packet(g, state, client_id, src, DstSpec::Ip(dst))
    } else {
        let dport = if allow_dns_ports {
            g.u16()
        } else {
            arb_non_dns_port(g)
        };
        arb_udp_packet(g, state, client_id, src, DstSpec::Ip(dst), dport)
    }
}
/// Select any subset of online clients (as `/32` + `/128` device members) and
/// preserve every offline member already in the pool.
pub(super) fn arb_static_pool_members(
    g: &mut Generator,
    state: &ReferenceState,
    pool: &StaticDevicePoolResource,
) -> Vec<DevicePoolMember> {
    arb_online_static_pool_members(g, state)
        .into_iter()
        .chain(offline_static_pool_members(state, pool))
        .collect()
}

pub(super) fn arb_online_static_pool_members(
    g: &mut Generator,
    state: &ReferenceState,
) -> Vec<DevicePoolMember> {
    state
        .clients
        .iter()
        .filter(|_| g.bool())
        .map(|(id, client)| {
            let client = client.inner();
            DevicePoolMember {
                id: *id,
                ipv4: Ipv4Network::new(client.tunnel_ip4, 32).unwrap(),
                ipv6: Ipv6Network::new(client.tunnel_ip6, 128).unwrap(),
            }
        })
        .collect()
}

fn offline_static_pool_members(
    state: &ReferenceState,
    pool: &StaticDevicePoolResource,
) -> impl Iterator<Item = DevicePoolMember> {
    let online_ids = state.clients.keys().copied().collect::<BTreeSet<_>>();

    pool.devices
        .iter()
        .filter(move |d| !online_ids.contains(&d.id))
        .cloned()
}

fn arb_icmp_packet(
    g: &mut Generator,
    state: &ReferenceState,
    client_id: ClientId,
    src: IpAddr,
    dst: DstSpec,
) -> Transition {
    let (seq, identifier) = g.fresh_icmp_packet();
    let resolved_ip = g.u32();
    let payload = g.fresh_payload();
    let dst = into_destination(dst, resolved_ip);
    let expected_route = state.route_for_packet(client_id, &dst, Protocol::IcmpEcho(identifier.0));
    Transition::SendIcmpPacket {
        client_id,
        src,
        dst,
        expected_route,
        seq,
        identifier,
        payload,
    }
}

fn arb_udp_packet(
    g: &mut Generator,
    state: &ReferenceState,
    client_id: ClientId,
    src: IpAddr,
    dst: DstSpec,
    dport: u16,
) -> Transition {
    let (sport, dport) = g.fresh_udp_packet(dport);
    let resolved_ip = g.u32();
    let payload = g.fresh_payload();
    let dst = into_destination(dst, resolved_ip);
    let expected_route = state.route_for_packet(client_id, &dst, Protocol::Udp(dport.0));
    Transition::SendUdpPacket {
        client_id,
        src,
        dst,
        expected_route,
        sport,
        dport,
        payload,
    }
}

fn arb_destination(g: &mut Generator, dst: DstSpec) -> Destination {
    let resolved_ip = g.u32();
    into_destination(dst, resolved_ip)
}

fn into_destination(dst: DstSpec, resolved_ip: u32) -> Destination {
    match dst {
        DstSpec::Domain(name) => Destination::DomainName { resolved_ip, name },
        DstSpec::Ip(addr) => Destination::IpAddr(addr),
    }
}

/// A port that is not 53 or 53535, as a total bijection over the allowed set.
///
/// There are `u16::MAX + 1 = 65536` ports and two holes (53, 53535), leaving
/// `65534` allowed values. We draw an index in `0..=65533` and shift it past
/// each hole. The second threshold is expressed in the *original* index space
/// (53535 - 1 = 53534, because the hole at 53 already shifted everything below
/// it down by one).
fn arb_non_dns_port(g: &mut Generator) -> u16 {
    non_dns_port(g.u32_in(0..=65533))
}

fn non_dns_port(index: u32) -> u16 {
    let after_do53 = index + u32::from(index >= 53);

    (after_do53 + u32::from(after_do53 >= 53535)) as u16
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::non_dns_port;

    /// The mapping is a bijection onto `[0, 65535] \ {53, 53535}`.
    #[test]
    fn non_dns_port_is_a_bijection() {
        let seen = (0..=65533).map(non_dns_port).collect::<BTreeSet<_>>();

        assert_eq!(seen.len(), 65534);
        assert!(!seen.contains(&53));
        assert!(!seen.contains(&53535));
    }
}
