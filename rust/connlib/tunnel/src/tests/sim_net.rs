use connlib_shared::messages::{ClientId, GatewayId, RelayId};
use firezone_relay::{AddressFamily, IpStack};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_network_table::IpNetworkTable;
use itertools::Itertools as _;
use prop::sample;
use proptest::prelude::*;
use snownet::Transmit;
use std::{
    collections::HashSet,
    fmt,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    num::NonZeroU16,
};
use tracing::Span;

#[derive(Clone, derivative::Derivative)]
#[derivative(Debug)]
pub(crate) struct Host<T> {
    inner: T,

    pub(crate) ip4: Option<Ipv4Addr>,
    pub(crate) ip6: Option<Ipv6Addr>,

    // In production, we always rebind to a new port.
    // To mimic this, we track the used ports here to not sample an existing one.
    pub(crate) old_ports: HashSet<u16>,

    default_port: u16,
    allocated_ports: HashSet<(u16, AddressFamily)>,

    #[derivative(Debug = "ignore")]
    span: Span,
}

impl<T> Host<T> {
    pub(crate) fn new(inner: T) -> Self {
        Self {
            inner,
            ip4: None,
            ip6: None,
            span: Span::none(),
            default_port: 0,
            allocated_ports: HashSet::default(),
            old_ports: HashSet::default(),
        }
    }

    pub(crate) fn inner(&self) -> &T {
        &self.inner
    }

    /// Mutable access to `T` must go via this function to ensure the corresponding span is active and tracks all state modifications.
    pub(crate) fn exec_mut<R>(&mut self, f: impl FnOnce(&mut T) -> R) -> R {
        self.span.in_scope(|| f(&mut self.inner))
    }

    pub(crate) fn sending_socket_for(&self, dst: impl Into<IpAddr>) -> Option<SocketAddr> {
        let ip = match dst.into() {
            IpAddr::V4(_) => self.ip4?.into(),
            IpAddr::V6(_) => self.ip6?.into(),
        };

        Some(SocketAddr::new(ip, self.default_port))
    }

    pub(crate) fn allocate_port(&mut self, port: u16, family: AddressFamily) {
        self.allocated_ports.insert((port, family));
    }

    pub(crate) fn deallocate_port(&mut self, port: u16, family: AddressFamily) {
        self.allocated_ports.remove(&(port, family));
    }

    pub(crate) fn update_interface(
        &mut self,
        ip4: Option<Ipv4Addr>,
        ip6: Option<Ipv6Addr>,
        port: u16,
    ) {
        // 1. Remember what the current port was.
        self.old_ports.insert(self.default_port);

        // 2. Update to the new IPs.
        self.ip4 = ip4;
        self.ip6 = ip6;

        // 3. Allocate the new port.
        self.default_port = port;

        self.deallocate_port(port, AddressFamily::V4);
        self.deallocate_port(port, AddressFamily::V6);

        if ip4.is_some() {
            self.allocate_port(port, AddressFamily::V4);
        }
        if ip6.is_some() {
            self.allocate_port(port, AddressFamily::V6);
        }
    }

    /// Sets the `src` of the given [`Transmit`] in case it is missing.
    ///
    /// The `src` of a [`Transmit`] is empty if we want to send if via the default interface.
    /// In production, the kernel does this for us.
    /// In this test, we need to always set a `src` so that the remote peer knows where the packet is coming from.
    pub(crate) fn set_transmit_src(
        &self,
        transmit: Transmit<'static>,
    ) -> Option<Transmit<'static>> {
        if transmit.src.is_some() {
            return Some(transmit);
        }

        let Some(src) = self.sending_socket_for(transmit.dst.ip()) else {
            tracing::debug!(dst = %transmit.dst, "No socket");

            return None;
        };

        Some(Transmit {
            src: Some(src),
            ..transmit
        })
    }
}

impl<T> Host<T>
where
    T: Clone,
{
    pub(crate) fn map<U>(
        &self,
        f: impl FnOnce(T, Option<Ipv4Addr>, Option<Ipv6Addr>) -> U,
        span: Span,
    ) -> Host<U> {
        Host {
            inner: f(self.inner.clone(), self.ip4, self.ip6),
            ip4: self.ip4,
            ip6: self.ip6,
            span,
            default_port: self.default_port,
            allocated_ports: self.allocated_ports.clone(),
            old_ports: self.old_ports.clone(),
        }
    }
}

#[derive(Debug, Clone)]
pub(crate) struct RoutingTable {
    routes: IpNetworkTable<HostId>,
}

impl Default for RoutingTable {
    fn default() -> Self {
        Self {
            routes: IpNetworkTable::new(),
        }
    }
}

impl RoutingTable {
    #[allow(private_bounds)]
    pub(crate) fn add_host<T>(&mut self, id: impl Into<HostId>, host: &Host<T>) -> bool {
        let id = id.into();

        match (host.ip4, host.ip6) {
            (None, None) => panic!("Node must have at least one network IP"),
            (None, Some(ip6)) => {
                if self.contains(ip6) {
                    return false;
                }

                self.routes.insert(ip6, id);
            }
            (Some(ip4), None) => {
                if self.contains(ip4) {
                    return false;
                }

                self.routes.insert(ip4, id);
            }
            (Some(ip4), Some(ip6)) => {
                if self.contains(ip4) {
                    return false;
                }
                if self.contains(ip6) {
                    return false;
                }

                self.routes.insert(ip4, id);
                self.routes.insert(ip6, id);
            }
        }

        true
    }

    #[allow(private_bounds)]
    pub(crate) fn remove_host<T>(&mut self, host: &Host<T>) {
        match (host.ip4, host.ip6) {
            (None, None) => panic!("Node must have at least one network IP"),
            (None, Some(ip6)) => {
                debug_assert!(self.contains(ip6), "Cannot remove a non-existing host");

                self.routes.insert(ip6, HostId::Stale);
            }
            (Some(ip4), None) => {
                debug_assert!(self.contains(ip4), "Cannot remove a non-existing host");

                self.routes.insert(ip4, HostId::Stale);
            }
            (Some(ip4), Some(ip6)) => {
                debug_assert!(self.contains(ip4), "Cannot remove a non-existing host");
                debug_assert!(self.contains(ip6), "Cannot remove a non-existing host");

                self.routes.insert(ip4, HostId::Stale);
                self.routes.insert(ip6, HostId::Stale);
            }
        }
    }

    pub(crate) fn contains(&self, ip: impl Into<IpNetwork>) -> bool {
        self.routes.exact_match(ip).is_some()
    }

    pub(crate) fn host_by_ip(&self, ip: IpAddr) -> Option<HostId> {
        self.routes.exact_match(ip).copied()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, PartialOrd, Ord, Eq, Hash)]
pub(crate) enum HostId {
    Client(ClientId),
    Gateway(GatewayId),
    Relay(RelayId),
    Stale,
}

impl From<RelayId> for HostId {
    fn from(v: RelayId) -> Self {
        Self::Relay(v)
    }
}

impl From<GatewayId> for HostId {
    fn from(v: GatewayId) -> Self {
        Self::Gateway(v)
    }
}

impl From<ClientId> for HostId {
    fn from(v: ClientId) -> Self {
        Self::Client(v)
    }
}

pub(crate) fn host<T>(
    socket_ips: impl Strategy<Value = IpStack>,
    default_port: impl Strategy<Value = u16>,
    state: impl Strategy<Value = T>,
) -> impl Strategy<Value = Host<T>>
where
    T: fmt::Debug,
{
    (state, socket_ips, default_port).prop_map(move |(state, ip_stack, port)| {
        let mut host = Host::new(state);
        host.update_interface(ip_stack.as_v4().copied(), ip_stack.as_v6().copied(), port);

        host
    })
}

pub(crate) fn any_port() -> impl Strategy<Value = u16> {
    any::<NonZeroU16>().prop_map(|v| v.into())
}

pub(crate) fn any_ip_stack() -> impl Strategy<Value = IpStack> {
    prop_oneof![
        host_ip4s().prop_map(IpStack::Ip4),
        host_ip6s().prop_map(IpStack::Ip6),
        dual_ip_stack()
    ]
}

pub(crate) fn dual_ip_stack() -> impl Strategy<Value = IpStack> {
    (host_ip4s(), host_ip6s()).prop_map(|(ip4, ip6)| IpStack::Dual { ip4, ip6 })
}

/// A [`Strategy`] of [`Ipv4Addr`]s used for routing packets between hosts within our test.
///
/// This uses the `TEST-NET-3` (`203.0.113.0/24`) address space reserved for documentation and examples in [RFC5737](https://datatracker.ietf.org/doc/html/rfc5737).
pub(crate) fn host_ip4s() -> impl Strategy<Value = Ipv4Addr> {
    let ips = Ipv4Network::new(Ipv4Addr::new(203, 0, 113, 0), 24)
        .unwrap()
        .hosts()
        .take(100)
        .collect_vec();

    sample::select(ips)
}

/// A [`Strategy`] of [`Ipv6Addr`]s used for routing packets between hosts within our test.
///
/// This uses the `2001:DB8::/32` address space reserved for documentation and examples in [RFC3849](https://datatracker.ietf.org/doc/html/rfc3849).
pub(crate) fn host_ip6s() -> impl Strategy<Value = Ipv6Addr> {
    let ips = Ipv6Network::new(Ipv6Addr::new(0x2001, 0xDB80, 0, 0, 0, 0, 0, 0), 32)
        .unwrap()
        .subnets_with_prefix(128)
        .map(|n| n.network_address())
        .take(100)
        .collect_vec();

    sample::select(ips)
}
