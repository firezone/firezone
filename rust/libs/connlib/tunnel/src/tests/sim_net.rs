use crate::tests::buffered_transmits::BufferedTransmits;
use crate::tests::strategies::documentation_ip6s;
use connlib_model::{ClientId, GatewayId, RelayId};
use firezone_relay::{AddressFamily, IpStack};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use proptest::prelude::*;
use snownet::Transmit;
use std::{
    collections::{BTreeMap, BTreeSet, HashSet},
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

    edge: Edge,

    /// Whether this host is detached from the network (e.g. mid-roam).
    ///
    /// An offline host can neither send nor receive.
    offline: bool,

    #[debug(skip)]
    span: Span,

    /// Messages that have "arrived" and are waiting to be dispatched.
    ///
    /// We buffer them here because we need also apply our latency on inbound packets.
    #[debug(skip)]
    inbox: BufferedTransmits,
}

/// The filtering behaviour of a host's network edge, per [RFC 4787, section 5](https://datatracker.ietf.org/doc/html/rfc4787#section-5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FilterMode {
    /// Everything is delivered (endpoint-independent filtering).
    Open,
    /// Inbound is delivered only from IPs the host has sent to (address-dependent filtering).
    AddressRestricted,
    /// Inbound is delivered only from sockets the host has sent to (address and port-dependent filtering).
    PortRestricted,
}

impl FilterMode {
    fn accepts(&self, sent_to: &BTreeSet<SocketAddr>, src: SocketAddr) -> bool {
        match self {
            FilterMode::Open => true,
            FilterMode::AddressRestricted => sent_to.iter().any(|d| d.ip() == src.ip()),
            FilterMode::PortRestricted => sent_to.contains(&src),
        }
    }
}

/// The mapping behaviour of a NAT, per [RFC 4787, section 4](https://datatracker.ietf.org/doc/html/rfc4787#section-4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Mapping {
    /// The same internal socket maps to the same public socket, regardless of destination ("cone" NATs).
    EndpointIndependent,
    /// Each (internal socket, destination) pair mints its own public socket ("symmetric" NATs).
    EndpointDependent,
}

/// The kind of network edge a host sits behind; the sampled, immutable part of [`Edge`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum EdgeConfig {
    /// Publicly reachable; everything is delivered.
    Open,
    /// A stateful firewall: filtering without address translation.
    Firewall(FilterMode),
    /// A NAT: address translation with the given mapping and filtering behaviour.
    Nat(Mapping, FilterMode),
}

/// The network edge of a host: every packet passes through it in both directions.
#[derive(Debug, Clone)]
enum Edge {
    Open,
    Firewall {
        filter: FilterMode,
        /// Destinations the host has sent to; the state backing [`FilterMode`].
        sent_to: BTreeSet<SocketAddr>,
    },
    Nat(Nat),
}

/// A NAT device with a dedicated public IP per address family.
///
/// The interface addresses of a host behind a NAT are not routable from other
/// hosts; only the NAT's public addresses are.
#[derive(Debug, Clone)]
pub(crate) struct Nat {
    ip4: Option<Ipv4Addr>,
    ip6: Option<Ipv6Addr>,
    mapping: Mapping,
    filter: FilterMode,
    next_port: u16,
    by_internal: BTreeMap<(SocketAddr, Option<SocketAddr>), SocketAddr>,
    by_public: BTreeMap<SocketAddr, Binding>,
}

#[derive(Debug, Clone)]
struct Binding {
    internal: SocketAddr,
    /// Destinations this binding has sent to; the state backing [`FilterMode`].
    sent_to: BTreeSet<SocketAddr>,
}

impl Nat {
    fn new(
        mapping: Mapping,
        filter: FilterMode,
        ip4: Option<Ipv4Addr>,
        ip6: Option<Ipv6Addr>,
    ) -> Self {
        Self {
            ip4,
            ip6,
            mapping,
            filter,
            next_port: 42000,
            by_internal: BTreeMap::default(),
            by_public: BTreeMap::default(),
        }
    }

    fn translate_outbound(&mut self, src: SocketAddr, dst: SocketAddr) -> Option<SocketAddr> {
        let public_ip: IpAddr = match dst.ip() {
            IpAddr::V4(_) => (self.ip4?).into(),
            IpAddr::V6(_) => (self.ip6?).into(),
        };

        let key = match self.mapping {
            Mapping::EndpointIndependent => (src, None),
            Mapping::EndpointDependent => (src, Some(dst)),
        };

        let next_port = &mut self.next_port;
        let public = *self.by_internal.entry(key).or_insert_with(|| {
            let port = *next_port;
            *next_port += 1;

            SocketAddr::new(public_ip, port)
        });

        self.by_public
            .entry(public)
            .or_insert_with(|| Binding {
                internal: src,
                sent_to: BTreeSet::default(),
            })
            .sent_to
            .insert(dst);

        Some(public)
    }

    fn translate_inbound(
        &self,
        src: SocketAddr,
        dst: SocketAddr,
    ) -> Result<SocketAddr, &'static str> {
        let binding = self
            .by_public
            .get(&dst)
            .ok_or("no NAT binding for destination")?;

        if !self.filter.accepts(&binding.sent_to, src) {
            return Err("sender not in NAT filter state");
        }

        Ok(binding.internal)
    }

    fn is_public_ip(&self, ip: IpAddr) -> bool {
        match ip {
            IpAddr::V4(ip) => self.ip4 == Some(ip),
            IpAddr::V6(ip) => self.ip6 == Some(ip),
        }
    }

    fn clear(&mut self) {
        self.by_internal.clear();
        self.by_public.clear();
    }
}

impl<T> Host<T> {
    fn new(inner: T, latency: Duration, port: u16, edge: Edge) -> Self {
        Self {
            inner,
            ip4: None,
            ip6: None,
            port,
            span: Span::none(),
            allocated_ports: HashSet::default(),
            latency,
            edge,
            offline: false,
            inbox: BufferedTransmits::default(),
        }
    }

    pub(crate) fn inner(&self) -> &T {
        &self.inner
    }

    /// Mutable access to `T` must go via this function to ensure the corresponding span is active and tracks all state modifications.
    pub(crate) fn exec_mut<R>(&mut self, f: impl FnOnce(&mut T) -> R) -> R
    where
        T: ExecMutScope,
    {
        let _guard = <T as ExecMutScope>::enter(&self.inner);

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
        self.offline = false;

        // A new network attachment means a new position behind a new edge:
        // whatever pinholes and NAT bindings the old traffic created do not follow us.
        self.clear_edge_state();
    }

    /// Detaches this host from the network, e.g. for the dead window of a roam.
    pub(crate) fn set_offline(&mut self) {
        self.offline = true;
        self.clear_edge_state();
    }

    fn clear_edge_state(&mut self) {
        match &mut self.edge {
            Edge::Open => {}
            Edge::Firewall { sent_to, .. } => sent_to.clear(),
            Edge::Nat(nat) => nat.clear(),
        }
    }

    /// The public addresses of this host's NAT, if it sits behind one.
    pub(crate) fn nat_ips(&self) -> (Option<Ipv4Addr>, Option<Ipv6Addr>) {
        match &self.edge {
            Edge::Nat(nat) => (nat.ip4, nat.ip6),
            Edge::Open | Edge::Firewall { .. } => (None, None),
        }
    }

    pub(crate) fn edge_config(&self) -> EdgeConfig {
        match &self.edge {
            Edge::Open => EdgeConfig::Open,
            Edge::Firewall { filter, .. } => EdgeConfig::Firewall(*filter),
            Edge::Nat(nat) => EdgeConfig::Nat(nat.mapping, nat.filter),
        }
    }

    /// Passes an outbound packet through this host's edge, returning the wire source address.
    pub(crate) fn egress(
        &mut self,
        src: SocketAddr,
        dst: SocketAddr,
    ) -> Result<SocketAddr, &'static str> {
        if self.offline {
            return Err("host is offline");
        }

        match &mut self.edge {
            Edge::Open => Ok(src),
            Edge::Firewall { sent_to, .. } => {
                sent_to.insert(dst);

                Ok(src)
            }
            Edge::Nat(nat) => nat
                .translate_outbound(src, dst)
                .ok_or("no public NAT address for family"),
        }
    }

    /// Passes an inbound wire packet through this host's edge, returning the address it is delivered to.
    pub(crate) fn ingress(
        &self,
        src: SocketAddr,
        dst: SocketAddr,
    ) -> Result<SocketAddr, &'static str> {
        if self.offline {
            return Err("host is offline");
        }

        match &self.edge {
            Edge::Open => Ok(dst),
            Edge::Firewall { filter, sent_to } => {
                if !filter.accepts(sent_to, src) {
                    return Err("sender not in firewall filter state");
                }

                Ok(dst)
            }
            Edge::Nat(nat) => {
                if !nat.is_public_ip(dst.ip()) {
                    return Err("interface address behind NAT is not routable");
                }

                nat.translate_inbound(src, dst)
            }
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

pub(crate) trait ExecMutScope {
    type Guard;

    fn enter(&self) -> Self::Guard;
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
            edge: self.edge.clone(),
            offline: self.offline,
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

        let interface_ips = interface_ips(host);
        assert!(
            !interface_ips.is_empty(),
            "Node must have at least one network IP"
        );

        if interface_ips.iter().any(|ip| self.contains(*ip)) {
            return false;
        }

        // A host's NAT is fixed for its lifetime, so re-attaching after a roam
        // re-registers the same public addresses; anything else is a collision.
        let (nat4, nat6) = host.nat_ips();
        let nat_ips = iter::empty()
            .chain(nat4.map(IpAddr::from))
            .chain(nat6.map(IpAddr::from))
            .collect::<Vec<_>>();

        for ip in &nat_ips {
            match self.host_by_ip(*ip) {
                None | Some(HostId::Stale) => {}
                Some(existing) if existing == id => {}
                Some(_) => return false,
            }
        }

        for ip in interface_ips.into_iter().chain(nat_ips) {
            self.routes.insert(ip, id);
        }

        true
    }

    pub(crate) fn remove_host<T>(&mut self, host: &Host<T>) {
        let ips = interface_ips(host)
            .into_iter()
            .chain({
                let (nat4, nat6) = host.nat_ips();

                iter::empty()
                    .chain(nat4.map(IpAddr::from))
                    .chain(nat6.map(IpAddr::from))
            })
            .collect::<Vec<_>>();
        assert!(!ips.is_empty(), "Node must have at least one network IP");

        for ip in ips {
            debug_assert!(self.contains(ip), "Cannot remove a non-existing host");

            self.routes.insert(ip, HostId::Stale);
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

fn interface_ips<T>(host: &Host<T>) -> Vec<IpAddr> {
    iter::empty()
        .chain(host.ip4.map(IpAddr::from))
        .chain(host.ip6.map(IpAddr::from))
        .collect()
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
    edge: impl Strategy<Value = EdgeConfig>,
) -> impl Strategy<Value = Host<T>>
where
    T: fmt::Debug,
{
    (
        state,
        socket_ips,
        port,
        latency,
        edge,
        nat_ip4s(),
        nat_ip6s(),
    )
        .prop_map(
            move |(state, ip_stack, port, latency, edge, nat_ip4, nat_ip6)| {
                let edge = match edge {
                    EdgeConfig::Open => Edge::Open,
                    EdgeConfig::Firewall(filter) => Edge::Firewall {
                        filter,
                        sent_to: BTreeSet::default(),
                    },
                    EdgeConfig::Nat(mapping, filter) => Edge::Nat(Nat::new(
                        mapping,
                        filter,
                        ip_stack.as_v4().map(|_| nat_ip4),
                        ip_stack.as_v6().map(|_| nat_ip6),
                    )),
                };

                let mut host = Host::new(state, latency, port, edge);
                host.update_interface(ip_stack.as_v4().copied(), ip_stack.as_v6().copied());

                host
            },
        )
}

/// All [`EdgeConfig`]s that occur in the wild, uniformly.
///
/// A symmetric NAT (endpoint-dependent mapping) always filters by port; the
/// cone NATs (endpoint-independent mapping) span the full filtering spectrum.
pub(crate) fn any_edge() -> impl Strategy<Value = EdgeConfig> {
    prop_oneof![
        Just(EdgeConfig::Open),
        Just(EdgeConfig::Firewall(FilterMode::AddressRestricted)),
        Just(EdgeConfig::Firewall(FilterMode::PortRestricted)),
        Just(EdgeConfig::Nat(
            Mapping::EndpointIndependent,
            FilterMode::Open
        )),
        Just(EdgeConfig::Nat(
            Mapping::EndpointIndependent,
            FilterMode::AddressRestricted
        )),
        Just(EdgeConfig::Nat(
            Mapping::EndpointIndependent,
            FilterMode::PortRestricted
        )),
        Just(EdgeConfig::Nat(
            Mapping::EndpointDependent,
            FilterMode::PortRestricted
        )),
    ]
}

/// Whether two hosts behind the given edges can establish a direct path by hole-punching.
///
/// Punching fails only when one side mints an unpredictable source port per
/// destination (endpoint-dependent mapping) and the other side only accepts
/// packets from sockets it has contacted: the advertised reflexive candidate
/// then never matches the source the peer actually sees.
pub(crate) fn direct_path_possible(a: EdgeConfig, b: EdgeConfig) -> bool {
    fn symmetric(e: EdgeConfig) -> bool {
        matches!(e, EdgeConfig::Nat(Mapping::EndpointDependent, _))
    }

    fn port_filtered(e: EdgeConfig) -> bool {
        matches!(
            e,
            EdgeConfig::Firewall(FilterMode::PortRestricted)
                | EdgeConfig::Nat(_, FilterMode::PortRestricted)
        )
    }

    !(symmetric(a) && port_filtered(b) || symmetric(b) && port_filtered(a))
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

/// A [`Strategy`] of [`Ipv4Addr`]s for the public side of NAT devices.
///
/// This uses `TEST-NET-2` (`198.51.100.0/24`) so NAT addresses never collide with host addresses.
fn nat_ip4s() -> impl Strategy<Value = Ipv4Addr> {
    const FIRST: Ipv4Addr = Ipv4Addr::new(198, 51, 100, 0);
    const LAST: Ipv4Addr = Ipv4Addr::new(198, 51, 100, 255);

    (FIRST.to_bits()..=LAST.to_bits()).prop_map(Ipv4Addr::from_bits)
}

/// A [`Strategy`] of [`Ipv6Addr`]s for the public side of NAT devices.
fn nat_ip6s() -> impl Strategy<Value = Ipv6Addr> {
    const NAT_SUBNET: u16 = 0x2020;

    documentation_ip6s(NAT_SUBNET)
}
