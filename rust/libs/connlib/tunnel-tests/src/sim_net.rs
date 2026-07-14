use crate::buffered_transmits::BufferedTransmits;
use anyhow::{Context as _, Result, bail};
use connlib_model::{ClientId, GatewayId, RelayId};
use firezone_relay::AddressFamily;
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use snownet::Transmit;
use std::{
    collections::{BTreeMap, BTreeSet, HashSet},
    iter,
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
    /// A NAT with the given mapping and filtering behaviour.
    Nat(Mapping, FilterMode),
}

/// The network edge of a host: every packet passes through it in both directions.
#[derive(Debug, Clone)]
enum Edge {
    Open,
    Nat(Nat),
}

/// A NAT device.
///
/// IPv4 is translated to a dedicated public address; the host's own IPv4
/// address is not routable from other hosts. IPv6 is not translated (there is
/// no NAT66 in the wild) but subject to the same stateful filtering, like the
/// "simple security" of [RFC 6092](https://datatracker.ietf.org/doc/html/rfc6092).
#[derive(Debug, Clone)]
pub(crate) struct Nat {
    ip4: Ipv4Addr,
    mapping: Mapping,
    filter: FilterMode,
    next_port: u16,
    by_internal: BTreeMap<(SocketAddr, Option<SocketAddr>), SocketAddr>,
    by_public: BTreeMap<SocketAddr, Binding>,
    /// IPv6 destinations the host has sent to; the state backing [`FilterMode`] for IPv6.
    sent_to6: BTreeSet<SocketAddr>,
}

#[derive(Debug, Clone)]
struct Binding {
    internal: SocketAddr,
    /// Destinations this binding has sent to; the state backing [`FilterMode`].
    sent_to: BTreeSet<SocketAddr>,
}

impl Nat {
    fn new(mapping: Mapping, filter: FilterMode, ip4: Ipv4Addr) -> Self {
        Self {
            ip4,
            mapping,
            filter,
            next_port: 42000,
            by_internal: BTreeMap::default(),
            by_public: BTreeMap::default(),
            sent_to6: BTreeSet::default(),
        }
    }

    fn egress(&mut self, src: SocketAddr, dst: SocketAddr) -> SocketAddr {
        if dst.is_ipv6() {
            self.sent_to6.insert(dst);

            return src;
        }

        let key = match self.mapping {
            Mapping::EndpointIndependent => (src, None),
            Mapping::EndpointDependent => (src, Some(dst)),
        };

        let public_ip = self.ip4;
        let next_port = &mut self.next_port;
        let public = *self.by_internal.entry(key).or_insert_with(|| {
            let port = *next_port;
            *next_port += 1;

            SocketAddr::new(public_ip.into(), port)
        });

        self.by_public
            .entry(public)
            .or_insert_with(|| Binding {
                internal: src,
                sent_to: BTreeSet::default(),
            })
            .sent_to
            .insert(dst);

        public
    }

    fn ingress(&self, src: SocketAddr, dst: SocketAddr) -> Result<SocketAddr> {
        match dst.ip() {
            IpAddr::V4(ip) => {
                if ip != self.ip4 {
                    bail!("IPv4 address behind NAT is not routable");
                }

                let binding = self
                    .by_public
                    .get(&dst)
                    .context("no NAT binding for destination")?;

                if !self.filter.accepts(&binding.sent_to, src) {
                    bail!("sender not in NAT filter state");
                }

                Ok(binding.internal)
            }
            IpAddr::V6(_) => {
                if !self.filter.accepts(&self.sent_to6, src) {
                    bail!("sender not in NAT filter state");
                }

                Ok(dst)
            }
        }
    }

    /// Moves this NAT to a new public address, e.g. because the host roamed to a different network.
    fn migrate(&mut self, ip4: Ipv4Addr) {
        self.ip4 = ip4;
        self.clear();
    }

    fn clear(&mut self) {
        self.by_internal.clear();
        self.by_public.clear();
        self.sent_to6.clear();
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
            Edge::Nat(nat) => nat.clear(),
        }
    }

    /// The public IPv4 address of this host's NAT, if it sits behind one.
    pub(crate) fn nat_ip4(&self) -> Option<Ipv4Addr> {
        match &self.edge {
            Edge::Nat(nat) => Some(nat.ip4),
            Edge::Open => None,
        }
    }

    /// Moves this host's NAT to a new public address, e.g. because it roamed to a different network.
    pub(crate) fn migrate_nat(&mut self, ip4: Ipv4Addr) {
        match &mut self.edge {
            Edge::Open => {}
            Edge::Nat(nat) => nat.migrate(ip4),
        }
    }

    pub(crate) fn edge_config(&self) -> EdgeConfig {
        match &self.edge {
            Edge::Open => EdgeConfig::Open,
            Edge::Nat(nat) => EdgeConfig::Nat(nat.mapping, nat.filter),
        }
    }

    /// Passes an outbound packet through this host's edge, returning the wire source address.
    pub(crate) fn egress(&mut self, src: SocketAddr, dst: SocketAddr) -> Result<SocketAddr> {
        if self.offline {
            bail!("host is offline");
        }

        match &mut self.edge {
            Edge::Open => Ok(src),
            Edge::Nat(nat) => Ok(nat.egress(src, dst)),
        }
    }

    /// Passes an inbound wire packet through this host's edge, returning the address it is delivered to.
    pub(crate) fn ingress(&self, src: SocketAddr, dst: SocketAddr) -> Result<SocketAddr> {
        if self.offline {
            bail!("host is offline");
        }

        match &self.edge {
            Edge::Open => Ok(dst),
            Edge::Nat(nat) => nat.ingress(src, dst),
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

        let nat_ips = host
            .nat_ip4()
            .map(IpAddr::from)
            .into_iter()
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
            .chain(host.nat_ip4().map(IpAddr::from))
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
