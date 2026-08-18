use crate::buffered_transmits::BufferedTransmits;
use anyhow::{Context as _, Result, bail};
use connlib_model::{ClientId, GatewayId, RelayId};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use relay_proto::AddressFamily;
use snownet::Transmit;
use std::{
    collections::{BTreeMap, HashSet},
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
    fn accepts<'a>(
        &self,
        mut sent_to: impl Iterator<Item = &'a SocketAddr>,
        src: SocketAddr,
    ) -> bool {
        match self {
            FilterMode::Open => true,
            FilterMode::AddressRestricted => sent_to.any(|d| d.ip() == src.ip()),
            FilterMode::PortRestricted => sent_to.any(|d| *d == src),
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

/// The idle-expiry behaviour of a NAT, per [RFC 4787, section 4.3](https://datatracker.ietf.org/doc/html/rfc4787#section-4.3).
///
/// A binding and its filter entries are dropped once they idle past `timeout`.
/// Outbound traffic always refreshes both (REQ-6); whether inbound traffic
/// refreshes the binding is a MAY that differs between NATs, so it is sampled.
/// Filter entries are only ever refreshed by outbound traffic: inbound
/// refreshing them would defeat the filter.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Expiry {
    pub(crate) timeout: Duration,
    pub(crate) inbound_refreshes: bool,
}

/// The kind of network edge a host sits behind; the sampled, immutable part of [`Edge`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum EdgeConfig {
    /// Publicly reachable; everything is delivered.
    Open,
    /// A NAT with the given mapping, filtering and expiry behaviour.
    Nat(Mapping, FilterMode, Expiry),
}

/// Whether two hosts behind the given edges can establish a direct path by hole-punching.
///
/// Over IPv6 there is no translation, only filtering, and punching through
/// filters always succeeds because both sides advertise their real sockets.
/// Over IPv4, punching fails when one side mints an unpredictable source port
/// per destination (endpoint-dependent mapping) and the other side only
/// accepts packets from sockets it has contacted: the advertised reflexive
/// candidate then never matches the source the peer actually sees.
pub(crate) fn direct_path_possible(a: EdgeConfig, b: EdgeConfig, shared_ip6: bool) -> bool {
    if shared_ip6 {
        return true;
    }

    fn symmetric(e: EdgeConfig) -> bool {
        matches!(e, EdgeConfig::Nat(Mapping::EndpointDependent, _, _))
    }

    fn port_filtered(e: EdgeConfig) -> bool {
        matches!(e, EdgeConfig::Nat(_, FilterMode::PortRestricted, _))
    }

    !(symmetric(a) && port_filtered(b) || symmetric(b) && port_filtered(a))
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
    expiry: Expiry,
    next_port: u16,
    by_internal: BTreeMap<(SocketAddr, Option<SocketAddr>), SocketAddr>,
    by_public: BTreeMap<SocketAddr, Binding>,
    /// IPv6 destinations the host has sent to; the state backing [`FilterMode`] for IPv6.
    sent_to6: BTreeMap<SocketAddr, Instant>,
}

#[derive(Debug, Clone)]
struct Binding {
    internal: SocketAddr,
    /// Destinations this binding has sent to and when it last did; the state backing [`FilterMode`].
    sent_to: BTreeMap<SocketAddr, Instant>,
    /// When the binding last carried traffic that refreshes it.
    refreshed_at: Instant,
}

impl Nat {
    fn new(mapping: Mapping, filter: FilterMode, expiry: Expiry, ip4: Ipv4Addr) -> Self {
        Self {
            ip4,
            mapping,
            filter,
            expiry,
            next_port: 42000,
            by_internal: BTreeMap::default(),
            by_public: BTreeMap::default(),
            sent_to6: BTreeMap::default(),
        }
    }

    fn egress(&mut self, src: SocketAddr, dst: SocketAddr, now: Instant) -> SocketAddr {
        if dst.is_ipv6() {
            self.sent_to6.insert(dst, now);

            return src;
        }

        let key = match self.mapping {
            Mapping::EndpointIndependent => (src, None),
            Mapping::EndpointDependent => (src, Some(dst)),
        };

        if let Some(public) = self.by_internal.get(&key).copied() {
            let binding = self
                .by_public
                .get_mut(&public)
                .expect("`by_internal` and `by_public` are in sync");

            if now.duration_since(binding.refreshed_at) < self.expiry.timeout {
                binding.refreshed_at = now;
                binding.sent_to.insert(dst, now);

                return public;
            }

            // The binding idled out. A cone NAT preserves the public socket
            // across sessions of the same internal socket (consistent
            // mapping), so `direct_path_possible` stays valid: advertised
            // reflexive candidates remain accurate after an expiry. A
            // symmetric NAT mints an unpredictable fresh port, exactly the
            // churn that makes it hard to traverse.
            match self.mapping {
                Mapping::EndpointIndependent => {
                    *binding = Binding {
                        internal: src,
                        sent_to: BTreeMap::from([(dst, now)]),
                        refreshed_at: now,
                    };

                    return public;
                }
                Mapping::EndpointDependent => {
                    self.by_internal.remove(&key);
                    self.by_public.remove(&public);
                }
            }
        }

        let port = self.next_port;
        self.next_port += 1;
        let public = SocketAddr::new(self.ip4.into(), port);

        self.by_internal.insert(key, public);
        self.by_public.insert(
            public,
            Binding {
                internal: src,
                sent_to: BTreeMap::from([(dst, now)]),
                refreshed_at: now,
            },
        );

        public
    }

    fn ingress(&mut self, src: SocketAddr, dst: SocketAddr, now: Instant) -> Result<SocketAddr> {
        let timeout = self.expiry.timeout;
        let fresh = move |sent_at: &Instant| now.duration_since(*sent_at) < timeout;

        let destination = match dst.ip() {
            IpAddr::V4(ip) => {
                if ip != self.ip4 {
                    bail!("IPv4 address behind NAT is not routable");
                }

                let binding = self
                    .by_public
                    .get_mut(&dst)
                    .context("no NAT binding for destination")?;

                if !fresh(&binding.refreshed_at) {
                    bail!("NAT binding expired");
                }

                let sent_to = binding
                    .sent_to
                    .iter()
                    .filter(|(_, sent_at)| fresh(sent_at))
                    .map(|(dst, _)| dst);

                if !self.filter.accepts(sent_to, src) {
                    bail!("sender not in NAT filter state");
                }

                if self.expiry.inbound_refreshes {
                    binding.refreshed_at = now;
                }

                binding.internal
            }
            IpAddr::V6(_) => {
                let sent_to = self
                    .sent_to6
                    .iter()
                    .filter(|(_, sent_at)| fresh(sent_at))
                    .map(|(dst, _)| dst);

                if !self.filter.accepts(sent_to, src) {
                    bail!("sender not in NAT filter state");
                }

                dst
            }
        };

        Ok(destination)
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
    pub(crate) fn new(
        inner: T,
        latency: Duration,
        port: u16,
        edge: EdgeConfig,
        nat_ip4: Ipv4Addr,
    ) -> Self {
        let edge = match edge {
            EdgeConfig::Open => Edge::Open,
            EdgeConfig::Nat(mapping, filter, expiry) => {
                Edge::Nat(Nat::new(mapping, filter, expiry, nat_ip4))
            }
        };

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
            Edge::Nat(nat) => EdgeConfig::Nat(nat.mapping, nat.filter, nat.expiry),
        }
    }

    /// Passes an outbound packet through this host's edge, returning the wire source address.
    pub(crate) fn egress(
        &mut self,
        src: SocketAddr,
        dst: SocketAddr,
        now: Instant,
    ) -> Result<SocketAddr> {
        if self.offline {
            bail!("host is offline");
        }

        let source = match &mut self.edge {
            Edge::Open => src,
            Edge::Nat(nat) => nat.egress(src, dst, now),
        };

        Ok(source)
    }

    /// Passes an inbound wire packet through this host's edge, returning the address it is delivered to.
    pub(crate) fn ingress(
        &mut self,
        src: SocketAddr,
        dst: SocketAddr,
        now: Instant,
    ) -> Result<SocketAddr> {
        if self.offline {
            bail!("host is offline");
        }

        let destination = match &mut self.edge {
            Edge::Open => dst,
            Edge::Nat(nat) => nat.ingress(src, dst, now)?,
        };

        Ok(destination)
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
        iter::empty()
            .chain(self.sut.poll_timeout())
            .chain(
                self.tcp_dns_client
                    .poll_timeout()
                    .map(|instant| (instant, "Application TCP DNS client")),
            )
            .min_by_key(|(instant, _)| *instant)
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
