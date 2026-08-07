use std::{iter, net::IpAddr};

use connlib_model::ClientId;
use ip_packet::Protocol;

use super::context::Generator;
use crate::{
    packet_input::{UdpPacketInput, UnroutablePacketInput},
    probe::PacketRoute,
    reference::ReferenceState,
    transition::{Destination, IpFamily, Transition},
};

pub(super) fn generate(g: &mut Generator, state: &ReferenceState) -> Transition {
    let family = if g.bool() {
        IpFamily::Ipv4
    } else {
        IpFamily::Ipv6
    };
    let client_id = *state
        .clients
        .keys()
        .nth(g.choose_index(state.clients.len()))
        .expect("unroutable packet transitions require a client");
    let gateway_id = *state
        .gateways
        .keys()
        .nth(g.choose_index(state.gateways.len()))
        .expect("unroutable packet transitions require a gateway");
    let source_port = g.u16();
    let destination_port = g.u16();
    let unknown_resource_targets = unknown_resource_targets(state);
    let input_count = 4 + usize::from(!unknown_resource_targets.is_empty());

    let input = match g.choose_index(input_count) {
        0 => UnroutablePacketInput::ClientNonTunnelSource {
            client_id,
            packet: UdpPacketInput::new(
                external_ip(g, family),
                external_ip(g, family),
                source_port,
                destination_port,
            ),
        },
        1 => {
            let client = state.clients[&client_id].inner();
            let tunnel_ip = match family {
                IpFamily::Ipv4 => IpAddr::V4(client.tunnel_ip4),
                IpFamily::Ipv6 => IpAddr::V6(client.tunnel_ip6),
            };

            UnroutablePacketInput::ClientSelfDestination {
                client_id,
                packet: UdpPacketInput::new(tunnel_ip, tunnel_ip, source_port, destination_port),
            }
        }
        2 => UnroutablePacketInput::GatewayNonPeerDestination {
            gateway_id,
            packet: UdpPacketInput::new(
                external_ip(g, family),
                external_ip(g, family),
                source_port,
                destination_port,
            ),
        },
        3 => UnroutablePacketInput::GatewayUnknownPeer {
            gateway_id,
            packet: UdpPacketInput::new(
                external_ip(g, family),
                fresh_peer_ip(g, family),
                source_port,
                destination_port,
            ),
        },
        4 => {
            let target = &unknown_resource_targets[g.choose_index(unknown_resource_targets.len())];

            UnroutablePacketInput::ClientUnknownResource {
                client_id: target.client_id,
                packet: UdpPacketInput::new(target.source, target.destination, source_port, 1),
            }
        }
        _ => unreachable!("the input kind is chosen from at most five cases"),
    };

    Transition::SendUnroutablePacket(input)
}

struct UnknownResourceTarget {
    client_id: ClientId,
    source: IpAddr,
    destination: IpAddr,
}

fn unknown_resource_targets(state: &ReferenceState) -> Vec<UnknownResourceTarget> {
    iter::empty()
        .chain(
            state
                .resolved_ip4_for_non_resources(&state.global_dns_records)
                .into_iter()
                .map(|(client_id, destination)| (client_id, IpAddr::V4(destination))),
        )
        .chain(
            state
                .resolved_ip6_for_non_resources(&state.global_dns_records)
                .into_iter()
                .map(|(client_id, destination)| (client_id, IpAddr::V6(destination))),
        )
        .filter_map(|(client_id, destination)| {
            if destination.is_multicast() {
                return None;
            }

            let client = state.clients[&client_id].inner();
            let source = client.tunnel_ip_for(destination);
            let semantic_destination = Destination::IpAddr(destination);
            let protocol = Protocol::Udp(1);

            if client.has_resource_for_packet(source, &semantic_destination, protocol)
                || state.route_for_packet(client_id, source, &semantic_destination, protocol)
                    != PacketRoute::Drop
            {
                return None;
            }

            Some(UnknownResourceTarget {
                client_id,
                source,
                destination,
            })
        })
        .collect()
}

fn external_ip(g: &mut Generator, family: IpFamily) -> IpAddr {
    match family {
        IpFamily::Ipv4 => IpAddr::V4(g.socket_ip4()),
        IpFamily::Ipv6 => IpAddr::V6(g.socket_ip6()),
    }
}

fn fresh_peer_ip(g: &mut Generator, family: IpFamily) -> IpAddr {
    match family {
        IpFamily::Ipv4 => IpAddr::V4(g.tunnel_ip4()),
        IpFamily::Ipv6 => IpAddr::V6(g.tunnel_ip6()),
    }
}
