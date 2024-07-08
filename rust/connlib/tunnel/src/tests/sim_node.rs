use super::{sim_net::Host, sim_relay::SimRelay};
use crate::{ClientState, GatewayState};
use connlib_shared::{
    messages::{ClientId, DnsServer, GatewayId, Interface},
    proptest::domain_name,
    StaticSecret,
};
use firezone_relay::IpStack;
use ip_network::{Ipv4Network, Ipv6Network};
use proptest::{collection, prelude::*};
use rand::rngs::StdRng;
use std::{
    collections::{HashMap, HashSet},
    fmt,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    time::Instant,
};

#[derive(Clone, Debug)]
pub(crate) struct SimNode<ID, S> {
    pub(crate) id: ID,
    pub(crate) state: S,

    pub(crate) tunnel_ip4: Ipv4Addr,
    pub(crate) tunnel_ip6: Ipv6Addr,
}

impl<ID, S> SimNode<ID, S> {
    pub(crate) fn new(id: ID, state: S, tunnel_ip4: Ipv4Addr, tunnel_ip6: Ipv6Addr) -> Self {
        Self {
            id,
            state,
            tunnel_ip4,
            tunnel_ip6,
        }
    }
}

impl<ID, S> SimNode<ID, S>
where
    ID: Copy,
    S: Clone,
{
    pub(crate) fn map<T>(&self, f: impl FnOnce(S) -> T) -> SimNode<ID, T> {
        SimNode {
            id: self.id,
            state: f(self.state.clone()),
            tunnel_ip4: self.tunnel_ip4,
            tunnel_ip6: self.tunnel_ip6,
        }
    }
}

impl SimNode<ClientId, ClientState> {
    pub(crate) fn init_relays<const N: usize>(
        &mut self,
        relays: [&SimRelay<firezone_relay::Server<StdRng>>; N],
        now: Instant,
    ) {
        self.state.update_relays(
            HashSet::default(),
            HashSet::from(relays.map(|r| r.explode("client"))),
            now,
        )
    }

    pub(crate) fn update_upstream_dns(&mut self, upstream_dns_resolvers: Vec<DnsServer>) {
        let _ = self.state.update_interface_config(Interface {
            ipv4: self.tunnel_ip4,
            ipv6: self.tunnel_ip6,
            upstream_dns: upstream_dns_resolvers,
        });
    }
}

impl SimNode<GatewayId, GatewayState> {
    pub(crate) fn init_relays<const N: usize>(
        &mut self,
        relays: [&SimRelay<firezone_relay::Server<StdRng>>; N],
        now: Instant,
    ) {
        self.state.update_relays(
            HashSet::default(),
            HashSet::from(relays.map(|r| r.explode("gateway"))),
            now,
        )
    }
}

impl<ID, S> SimNode<ID, S> {
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

#[derive(Clone, Copy, PartialEq)]
pub(crate) struct PrivateKey([u8; 32]);

impl From<PrivateKey> for StaticSecret {
    fn from(key: PrivateKey) -> Self {
        StaticSecret::from(key.0)
    }
}

impl fmt::Debug for PrivateKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("PrivateKey")
            .field(&hex::encode(self.0))
            .finish()
    }
}

pub(crate) fn sim_node_prototype<ID, S>(
    id: impl Strategy<Value = ID>,
    state: impl Strategy<Value = S>,
    socket_ip4s: &mut impl Iterator<Item = Ipv4Addr>,
    socket_ip6s: &mut impl Iterator<Item = Ipv6Addr>,
    tunnel_ip4s: &mut impl Iterator<Item = Ipv4Addr>,
    tunnel_ip6s: &mut impl Iterator<Item = Ipv6Addr>,
) -> impl Strategy<Value = Host<SimNode<ID, S>>>
where
    ID: fmt::Debug,
    S: fmt::Debug,
{
    let socket_ip4 = socket_ip4s.next().unwrap();
    let socket_ip6 = socket_ip6s.next().unwrap();
    let socket_ips = prop_oneof![
        Just(IpStack::Ip4(socket_ip4)),
        Just(IpStack::Ip6(socket_ip6)),
        Just(IpStack::Dual {
            ip4: socket_ip4,
            ip6: socket_ip6
        })
    ];

    let tunnel_ip4 = tunnel_ip4s.next().unwrap();
    let tunnel_ip6 = tunnel_ip6s.next().unwrap();

    (
        id,
        state,
        socket_ips,
        any::<u16>().prop_filter("port must not be 0", |p| *p != 0),
    )
        .prop_map(move |(id, state, ip_stack, port)| {
            let mut host = Host::new(SimNode::new(id, state, tunnel_ip4, tunnel_ip6));
            host.update_interface(ip_stack.as_v4().copied(), ip_stack.as_v6().copied(), port);

            host
        })
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
    Ipv6Network::new(Ipv6Addr::new(64_768, 8_225, 4_369, 0, 0, 0, 0, 0), 107)
        .unwrap()
        .subnets_with_prefix(128)
        .map(|n| n.network_address())
}

fn private_key() -> impl Strategy<Value = PrivateKey> {
    any::<[u8; 32]>().prop_map(PrivateKey)
}

pub(crate) fn gateway_state() -> impl Strategy<Value = PrivateKey> {
    private_key()
}

pub(crate) fn client_state() -> impl Strategy<Value = (PrivateKey, HashMap<String, Vec<IpAddr>>)> {
    (private_key(), known_hosts())
}

pub(crate) fn known_hosts() -> impl Strategy<Value = HashMap<String, Vec<IpAddr>>> {
    collection::hash_map(
        domain_name(2..4).prop_map(|d| d.parse().unwrap()),
        collection::vec(any::<IpAddr>(), 1..6),
        0..15,
    )
}
