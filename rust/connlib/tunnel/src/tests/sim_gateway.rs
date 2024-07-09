use super::{
    reference::{private_key, PrivateKey},
    sim_net::{any_ip_stack, any_port, host, Host},
};
use connlib_shared::{messages::GatewayId, proptest::gateway_id};
use proptest::prelude::*;
use std::net::{Ipv4Addr, Ipv6Addr};

#[derive(Debug, Clone)]
pub(crate) struct SimGateway {
    pub(crate) id: GatewayId,
    pub(crate) _tunnel_ip4: Ipv4Addr,
    pub(crate) _tunnel_ip6: Ipv6Addr,
}

pub(crate) fn gateway_prototype(
    tunnel_ip4s: &mut impl Iterator<Item = Ipv4Addr>,
    tunnel_ip6s: &mut impl Iterator<Item = Ipv6Addr>,
) -> impl Strategy<Value = Host<PrivateKey, SimGateway>> {
    host(
        any_ip_stack(),
        any_port(),
        private_key(),
        sim_gateway(tunnel_ip4s, tunnel_ip6s),
    )
}

fn sim_gateway(
    tunnel_ip4s: &mut impl Iterator<Item = Ipv4Addr>,
    tunnel_ip6s: &mut impl Iterator<Item = Ipv6Addr>,
) -> impl Strategy<Value = SimGateway> {
    let tunnel_ip4 = tunnel_ip4s.next().unwrap();
    let tunnel_ip6 = tunnel_ip6s.next().unwrap();

    gateway_id().prop_map(move |id| SimGateway {
        id,
        _tunnel_ip4: tunnel_ip4,
        _tunnel_ip6: tunnel_ip6,
    })
}
