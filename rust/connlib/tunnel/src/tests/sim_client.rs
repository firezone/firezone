use super::{
    reference::{private_key, PrivateKey},
    sim_net::{any_ip_stack, any_port, host, Host},
};
use connlib_shared::{
    messages::ClientId,
    proptest::{client_id, domain_name},
};
use prop::collection;
use proptest::prelude::*;
use std::{
    collections::HashMap,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
};

#[derive(Debug, Clone)]
pub(crate) struct SimClient {
    pub(crate) id: ClientId,
    pub(crate) tunnel_ip4: Ipv4Addr,
    pub(crate) tunnel_ip6: Ipv6Addr,
}

impl SimClient {
    pub(crate) fn tunnel_ip(&self, dst: impl Into<IpAddr>) -> IpAddr {
        match dst.into() {
            IpAddr::V4(_) => IpAddr::from(self.tunnel_ip4),
            IpAddr::V6(_) => IpAddr::from(self.tunnel_ip6),
        }
    }

    pub(crate) fn is_tunnel_ip(&self, ip: IpAddr) -> bool {
        self.tunnel_ip(ip) == ip
    }
}

pub(crate) fn client_prototype(
    tunnel_ip4s: &mut impl Iterator<Item = Ipv4Addr>,
    tunnel_ip6s: &mut impl Iterator<Item = Ipv6Addr>,
) -> impl Strategy<Value = Host<(PrivateKey, HashMap<String, Vec<IpAddr>>), SimClient>> {
    host(
        any_ip_stack(),
        any_port(),
        (private_key(), known_hosts()),
        sim_client(tunnel_ip4s, tunnel_ip6s),
    )
}

fn sim_client(
    tunnel_ip4s: &mut impl Iterator<Item = Ipv4Addr>,
    tunnel_ip6s: &mut impl Iterator<Item = Ipv6Addr>,
) -> impl Strategy<Value = SimClient> {
    let tunnel_ip4 = tunnel_ip4s.next().unwrap();
    let tunnel_ip6 = tunnel_ip6s.next().unwrap();

    client_id().prop_map(move |id| SimClient {
        id,
        tunnel_ip4,
        tunnel_ip6,
    })
}

fn known_hosts() -> impl Strategy<Value = HashMap<String, Vec<IpAddr>>> {
    collection::hash_map(
        domain_name(2..4).prop_map(|d| d.parse().unwrap()),
        collection::vec(any::<IpAddr>(), 1..6),
        0..15,
    )
}
