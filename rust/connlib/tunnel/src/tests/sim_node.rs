use super::SimRelay;
use crate::{ClientState, GatewayState};
use connlib_shared::messages::{
    client::ResourceDescription, ClientId, DnsServer, GatewayId, Interface,
};
use rand::rngs::StdRng;
use std::{
    collections::HashSet,
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
        }
    }
}

impl<ID, S> SimNode<ID, S>
where
    ID: Copy,
    S: Copy,
{
    pub(crate) fn map_state<T>(&self, f: impl FnOnce(S) -> T, span: Span) -> SimNode<ID, T> {
        SimNode {
            id: self.id,
            state: f(self.state),
            ip4_socket: self.ip4_socket,
            ip6_socket: self.ip6_socket,
            tunnel_ip4: self.tunnel_ip4,
            tunnel_ip6: self.tunnel_ip6,
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
            .finish()
    }
}
