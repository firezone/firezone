use super::sim_relay::SimRelay;
use crate::{ClientState, GatewayState};
use connlib_shared::{
    messages::{
        client::ResourceDescription, ClientId, DnsServer, GatewayId, Interface, ResourceId,
    },
    proptest::domain_name,
    StaticSecret,
};
use ip_network::{Ipv4Network, Ipv6Network};
use proptest::{collection, prelude::*, sample};
use rand::rngs::StdRng;
use std::{
    collections::{HashMap, HashSet},
    fmt,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
    time::Instant,
};
use tracing::Span;

#[derive(Clone)]
pub(crate) struct SimNode<ID, S> {
    pub(crate) id: ID,
    pub(crate) state: S,

    pub(crate) ip4_socket: Option<SocketAddrV4>,
    pub(crate) ip6_socket: Option<SocketAddrV6>,

    pub(crate) old_sockets: Vec<SocketAddr>,

    pub(crate) tunnel_ip4: Ipv4Addr,
    pub(crate) tunnel_ip6: Ipv6Addr,

    pub(crate) span: Span,
}

impl<ID, S> SimNode<ID, S> {
    pub(crate) fn new(
        id: ID,
        state: S,
        ip4_socket: Option<SocketAddrV4>,
        ip6_socket: Option<SocketAddrV6>,
        tunnel_ip4: Ipv4Addr,
        tunnel_ip6: Ipv6Addr,
    ) -> Self {
        Self {
            id,
            state,
            ip4_socket,
            ip6_socket,
            tunnel_ip4,
            tunnel_ip6,
            span: Span::none(),
            old_sockets: Default::default(),
        }
    }
}

impl<ID, S> SimNode<ID, S>
where
    ID: Copy,
    S: Clone,
{
    pub(crate) fn map_state<T>(&self, f: impl FnOnce(S) -> T, span: Span) -> SimNode<ID, T> {
        SimNode {
            id: self.id,
            state: f(self.state.clone()),
            ip4_socket: self.ip4_socket,
            ip6_socket: self.ip6_socket,
            tunnel_ip4: self.tunnel_ip4,
            tunnel_ip6: self.tunnel_ip6,
            old_sockets: self.old_sockets.clone(),
            span,
        }
    }
}

impl SimNode<ClientId, ClientState> {
    pub(crate) fn init_relays<const N: usize>(
        &mut self,
        relays: [&SimRelay<firezone_relay::Server<StdRng>>; N],
        now: Instant,
    ) {
        self.span.in_scope(|| {
            self.state.update_relays(
                HashSet::default(),
                HashSet::from(relays.map(|r| r.explode("client"))),
                now,
            )
        });
    }

    pub(crate) fn update_upstream_dns(&mut self, upstream_dns_resolvers: Vec<DnsServer>) {
        self.span.in_scope(|| {
            let _ = self.state.update_interface_config(Interface {
                ipv4: self.tunnel_ip4,
                ipv6: self.tunnel_ip6,
                upstream_dns: upstream_dns_resolvers,
            });
        });
    }

    pub(crate) fn update_system_dns(&mut self, system_dns_resolvers: Vec<IpAddr>) {
        self.span.in_scope(|| {
            let _ = self.state.update_system_resolvers(system_dns_resolvers);
        });
    }

    pub(crate) fn add_resource(&mut self, resource: ResourceDescription) {
        self.span.in_scope(|| {
            self.state.add_resources(&[resource]);
        })
    }

    pub(crate) fn remove_resource(&mut self, resource: ResourceId) {
        self.span.in_scope(|| {
            self.state.remove_resources(&[resource]);
        })
    }

    pub(crate) fn roam(
        &mut self,
        ip4_socket: Option<SocketAddrV4>,
        ip6_socket: Option<SocketAddrV6>,
        now: Instant,
    ) {
        // 1. Remember what the current sockets were.
        self.old_sockets.extend(self.ip4_socket.map(SocketAddr::V4));
        self.old_sockets.extend(self.ip6_socket.map(SocketAddr::V6));

        // 2. Update to the new sockets.
        self.ip4_socket = ip4_socket;
        self.ip6_socket = ip6_socket;

        // 3. Ensure our new sockets aren't present in old sockets (a client should be able to roam "back" to a previous network interface).
        if let Some(s4) = self.ip4_socket.map(SocketAddr::V4) {
            self.old_sockets.retain(|s| s != &s4);
        }
        if let Some(s6) = self.ip6_socket.map(SocketAddr::V6) {
            self.old_sockets.retain(|s| s != &s6);
        }

        self.state.reconnect(now);
    }
}

impl SimNode<GatewayId, GatewayState> {
    pub(crate) fn init_relays<const N: usize>(
        &mut self,
        relays: [&SimRelay<firezone_relay::Server<StdRng>>; N],
        now: Instant,
    ) {
        self.span.in_scope(|| {
            self.state.update_relays(
                HashSet::default(),
                HashSet::from(relays.map(|r| r.explode("gateway"))),
                now,
            )
        });
    }
}

impl<ID, S> SimNode<ID, S> {
    pub(crate) fn wants(&self, dst: SocketAddr) -> bool {
        self.ip4_socket.is_some_and(|s| SocketAddr::V4(s) == dst)
            || self.ip6_socket.is_some_and(|s| SocketAddr::V6(s) == dst)
    }

    pub(crate) fn sending_socket_for(&self, dst: impl Into<IpAddr>) -> Option<SocketAddr> {
        Some(match dst.into() {
            IpAddr::V4(_) => self.ip4_socket?.into(),
            IpAddr::V6(_) => self.ip6_socket?.into(),
        })
    }

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

impl<ID: fmt::Debug, S: fmt::Debug> fmt::Debug for SimNode<ID, S> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SimNode")
            .field("id", &self.id)
            .field("state", &self.state)
            .field("ip4_socket", &self.ip4_socket)
            .field("ip6_socket", &self.ip6_socket)
            .field("tunnel_ip4", &self.tunnel_ip4)
            .field("tunnel_ip6", &self.tunnel_ip6)
            .field("old_sockets", &self.old_sockets)
            .finish()
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
) -> impl Strategy<Value = SimNode<ID, S>>
where
    ID: fmt::Debug,
    S: fmt::Debug,
{
    (
        id,
        state,
        firezone_relay::proptest::any_ip_stack(), // We are re-using the strategy here because it is exactly what we need although we are generating a node here and not a relay.
        any::<u16>().prop_filter("port must not be 0", |p| *p != 0),
        any::<u16>().prop_filter("port must not be 0", |p| *p != 0),
        tunnel_ip4(),
        tunnel_ip6(),
    )
        .prop_filter_map(
            "must have at least one socket address",
            |(id, state, ip_stack, v4_port, v6_port, tunnel_ip4, tunnel_ip6)| {
                let ip4_socket = ip_stack.as_v4().map(|ip| SocketAddrV4::new(*ip, v4_port));
                let ip6_socket = ip_stack
                    .as_v6()
                    .map(|ip| SocketAddrV6::new(*ip, v6_port, 0, 0));

                Some(SimNode::new(
                    id, state, ip4_socket, ip6_socket, tunnel_ip4, tunnel_ip6,
                ))
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
