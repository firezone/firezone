use crate::tests::buffered_transmits::BufferedTransmits;
use crate::tests::strategies::documentation_ip6s;
use connlib_model::{ClientId, GatewayId, RelayId};
use firezone_relay::{AddressFamily, IpStack};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use proptest::prelude::*;
use snownet::Transmit;
use std::{
    collections::HashSet,
    fmt, iter,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::{Duration, Instant},
};
use tracing::Span;

use super::sim_client::SimClient;
use super::sim_gateway::SimGateway;
use super::sim_relay::SimRelay;

#[derive(Clone, derive_more::Debug)]
pub(crate) struct Host<T> {
    inner: T,

    pub(crate) ip4: Option<Ipv4Addr>,
    pub(crate) ip6: Option<Ipv6Addr>,
    pub(crate) port: u16,

    #[debug(skip)]
    allocated_ports: HashSet<(u16, AddressFamily)>,

    // The latency of incoming and outgoing packets.
    latency: Duration,

    #[debug(skip)]
    span: Span,

    /// Messages that have "arrived" and are waiting to be dispatched.
    ///
    /// We buffer them here because we need also apply our latency on inbound packets.
    #[debug(skip)]
    inbox: BufferedTransmits,
}

impl<T> Host<T> {
    pub(crate) fn new(inner: T, latency: Duration, port: u16) -> Self {
        Self {
            inner,
            ip4: None,
            ip6: None,
            port,
            span: Span::none(),
            allocated_ports: HashSet::default(),
            latency,
            inbox: BufferedTransmits::default(),
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

        Some(SocketAddr::new(ip, self.port))
    }

    pub(crate) fn allocate_port(&mut self, port: u16, family: AddressFamily) {
        self.allocated_ports.insert((port, family));
    }

    pub(crate) fn deallocate_port(&mut self, port: u16, family: AddressFamily) {
        self.allocated_ports.remove(&(port, family));
    }

    pub(crate) fn update_interface(&mut self, ip4: Option<Ipv4Addr>, ip6: Option<Ipv6Addr>) {
        self.ip4 = ip4;
        self.ip6 = ip6;
    }

    pub(crate) fn is_sender(&self, src: IpAddr) -> bool {
        match src {
            IpAddr::V4(src) => self.ip4.is_some_and(|v4| v4 == src),
            IpAddr::V6(src) => self.ip6.is_some_and(|v6| v6 == src),
        }
    }

    pub(crate) fn latency(&self) -> Duration {
        self.latency
    }

    pub(crate) fn receive(&mut self, transmit: Transmit, now: Instant) {
        self.inbox.push(transmit, self.latency, now);
    }

    pub(crate) fn poll_inbox(&mut self, now: Instant) -> Option<Transmit> {
        self.inbox.pop(now)
    }
}

impl<T> Host<T>
where
    T: PollTimeout,
{
    pub(crate) fn poll_timeout(&mut self) -> Option<(Instant, &'static str)> {
        iter::empty()
            .chain(self.inner.poll_timeout())
            .chain(
                self.inbox
                    .next_transmit()
                    .map(|instant| (instant, "inbox transmit")),
            )
            .min_by_key(|(instant, _)| *instant)
    }
}

pub(crate) trait PollTimeout {
    fn poll_timeout(&mut self) -> Option<(Instant, &'static str)>;
}

impl PollTimeout for SimClient {
    fn poll_timeout(&mut self) -> Option<(Instant, &'static str)> {
        self.sut.poll_timeout()
    }
}

impl PollTimeout for SimGateway {
    fn poll_timeout(&mut self) -> Option<(Instant, &'static str)> {
        self.sut.poll_timeout()
    }
}

impl PollTimeout for SimRelay {
    fn poll_timeout(&mut self) -> Option<(Instant, &'static str)> {
        self.sut.poll_timeout().map(|instant| (instant, ""))
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
            inner: span.in_scope(|| f(self.inner.clone(), self.ip4, self.ip6)),
            ip4: self.ip4,
            ip6: self.ip6,
            span,
            port: self.port,
            allocated_ports: self.allocated_ports.clone(),
            latency: self.latency,
            inbox: self.inbox.clone(),
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

    pub(crate) fn overlaps_with(&self, other: &Self) -> bool {
        other
            .routes
            .iter()
            .any(|(route, _)| self.routes.exact_match(route).is_some())
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
    port: impl Strategy<Value = u16>,
    state: impl Strategy<Value = T>,
    latency: impl Strategy<Value = Duration>,
) -> impl Strategy<Value = Host<T>>
where
    T: fmt::Debug,
{
    (state, socket_ips, port, latency).prop_map(move |(state, ip_stack, port, latency)| {
        let mut host = Host::new(state, latency, port);
        host.update_interface(ip_stack.as_v4().copied(), ip_stack.as_v6().copied());

        host
    })
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
    const FIRST: Ipv4Addr = Ipv4Addr::new(203, 0, 113, 0);
    const LAST: Ipv4Addr = Ipv4Addr::new(203, 0, 113, 255);

    (FIRST.to_bits()..=LAST.to_bits()).prop_map(Ipv4Addr::from_bits)
}

/// A [`Strategy`] of [`Ipv6Addr`]s used for routing packets between hosts within our test.
///
/// This uses a subnet of the `2001:DB8::/32` address space reserved for documentation and examples in [RFC3849](https://datatracker.ietf.org/doc/html/rfc3849).
pub(crate) fn host_ip6s() -> impl Strategy<Value = Ipv6Addr> {
    const HOST_SUBNET: u16 = 0x1010;

    documentation_ip6s(HOST_SUBNET)
}
