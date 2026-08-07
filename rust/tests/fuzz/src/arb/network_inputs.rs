use std::{iter, net::SocketAddr};

use crate::{
    network_input::{MalformedNetworkDatagramInput, NetworkInputTarget},
    reference::ReferenceState,
    transition::Transition,
};

use super::context::Generator;

pub(super) fn generate(g: &mut Generator, state: &ReferenceState) -> Transition {
    let targets = iter::empty()
        .chain(state.clients.iter().flat_map(|(client_id, client)| {
            iter::empty()
                .chain(client.ip4.map(|ip| {
                    (
                        NetworkInputTarget::Client(*client_id),
                        SocketAddr::new(ip.into(), client.port),
                    )
                }))
                .chain(client.ip6.map(|ip| {
                    (
                        NetworkInputTarget::Client(*client_id),
                        SocketAddr::new(ip.into(), client.port),
                    )
                }))
        }))
        .chain(state.gateways.iter().flat_map(|(gateway_id, gateway)| {
            iter::empty()
                .chain(gateway.ip4.map(|ip| {
                    (
                        NetworkInputTarget::Gateway(*gateway_id),
                        SocketAddr::new(ip.into(), gateway.port),
                    )
                }))
                .chain(gateway.ip6.map(|ip| {
                    (
                        NetworkInputTarget::Gateway(*gateway_id),
                        SocketAddr::new(ip.into(), gateway.port),
                    )
                }))
        }))
        .collect::<Vec<_>>();
    let (target, local) = targets[g.choose_index(targets.len())];
    let from_ip = if local.is_ipv4() {
        g.socket_ip4().into()
    } else {
        g.socket_ip6().into()
    };
    let from_port = if g.bool() { 3478 } else { g.u16() };
    let payload = (0..g.count(0, MalformedNetworkDatagramInput::MAX_PAYLOAD_LEN))
        .map(|_| g.u8())
        .collect();

    Transition::ReceiveMalformedNetworkDatagram(MalformedNetworkDatagramInput::new(
        target,
        local,
        SocketAddr::new(from_ip, from_port),
        payload,
    ))
}
