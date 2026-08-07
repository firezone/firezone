use std::net::IpAddr;

use super::context::Generator;
use crate::{
    packet_input::{UdpPacketInput, UnroutablePacketInput},
    reference::ReferenceState,
    transition::{IpFamily, Transition},
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

    let input = match g.choose_index(4) {
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
        _ => unreachable!("the input kind is chosen from four cases"),
    };

    Transition::SendUnroutablePacket(input)
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
