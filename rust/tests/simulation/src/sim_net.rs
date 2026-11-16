use crate::buffered_transmits::BufferedTransmits;
use anyhow::{Context as _, Result, bail};
use connlib_model::{ClientId, GatewayId, RelayId};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use snownet::Transmit;
use std::{
    collections::BTreeMap,
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

    // The latency of incoming and outgoing packets.
    latency: Duration,

    /// Whether this host is detached from the network (e.g. mid-roam).
    ///
    /// An offline host cannot send.
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

/// The behaviour of the network edge in front of a host.
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
///
/// Two hosts behind the same NAT reach each other through it (hairpinning), so
/// the same holds for them.
pub(crate) fn direct_path_possible(
    a: EdgeConfig,
    b: EdgeConfig,
    shared_ip4: bool,
    shared_ip6: bool,
) -> bool {
    if shared_ip6 {
        return true;
    }
    if !shared_ip4 {
        return false;
    }

    fn symmetric(e: EdgeConfig) -> bool {
        matches!(e, EdgeConfig::Nat(Mapping::EndpointDependent, _, _))
    }

    fn port_filtered(e: EdgeConfig) -> bool {
        matches!(e, EdgeConfig::Nat(_, FilterMode::PortRestricted, _))
    }

    !(symmetric(a) && port_filtered(b) || symmetric(b) && port_filtered(a))
}

/// Where a host attaches to the network.
#[derive(Debug, Clone)]
pub(crate) enum Attachment {
    /// Publicly reachable.
    Direct,
    /// Behind the NAT device with the given public IPv4 address.
    Nat(Ipv4Addr),
    /// Behind a NAT device that joins the network together with the host.
    NewNat(Nat),
}

/// A NAT device that any number of hosts sit behind.
///
/// IPv4 is translated to the device's public address; the IPv4 addresses of the
/// hosts behind it are not routable from other hosts. IPv6 is not translated
/// (there is no NAT66 in the wild) but subject to the same stateful filtering
/// per host, like the "simple security" of [RFC 6092](https://datatracker.ietf.org/doc/html/rfc6092).
///
/// A public port belongs to exactly one mapping. A new mapping keeps the port
/// of its internal socket unless a live mapping holds it, and takes the next
/// free port otherwise.
#[derive(Debug, Clone)]
pub(crate) struct Nat {
    ip4: Ipv4Addr,
    mapping: Mapping,
    filter: FilterMode,
    expiry: Expiry,
    next_port: u16,
    bindings: BTreeMap<u16, Binding>,
    /// IPv6 destinations each host has sent to; the state backing [`FilterMode`] for IPv6.
    sent_to6: BTreeMap<(IpAddr, SocketAddr), Instant>,
}

#[derive(Debug, Clone)]
struct Binding {
    internal: SocketAddr,
    /// The destination of an endpoint-dependent mapping.
    destination: Option<SocketAddr>,
    /// Destinations this binding has sent to and when it last did; the state backing [`FilterMode`].
    sent_to: BTreeMap<SocketAddr, Instant>,
    /// When the binding last carried traffic that refreshes it.
    refreshed_at: Instant,
}

impl Nat {
    pub(crate) fn new(ip4: Ipv4Addr, mapping: Mapping, filter: FilterMode, expiry: Expiry) -> Self {
        Self {
            ip4,
            mapping,
            filter,
            expiry,
            next_port: 42000,
            bindings: BTreeMap::default(),
            sent_to6: BTreeMap::default(),
        }
    }

    pub(crate) fn ip4(&self) -> Ipv4Addr {
        self.ip4
    }

    fn edge_config(&self) -> EdgeConfig {
        EdgeConfig::Nat(self.mapping, self.filter, self.expiry)
    }

    fn egress(&mut self, src: SocketAddr, dst: SocketAddr, now: Instant) -> SocketAddr {
        if dst.is_ipv6() {
            self.sent_to6.insert((src.ip(), dst), now);

            return src;
        }

        let timeout = self.expiry.timeout;
        for _ in self.bindings.extract_if(.., |_, binding| {
            now.duration_since(binding.refreshed_at) >= timeout
        }) {}

        let destination = match self.mapping {
            Mapping::EndpointIndependent => None,
            Mapping::EndpointDependent => Some(dst),
        };

        let existing = self
            .bindings
            .iter_mut()
            .find(|(_, binding)| binding.internal == src && binding.destination == destination);

        if let Some((port, binding)) = existing {
            binding.refreshed_at = now;
            binding.sent_to.insert(dst, now);

            return SocketAddr::new(self.ip4.into(), *port);
        }

        let port = self.free_port(src.port());
        self.bindings.insert(
            port,
            Binding {
                internal: src,
                destination,
                sent_to: BTreeMap::from([(dst, now)]),
                refreshed_at: now,
            },
        );

        SocketAddr::new(self.ip4.into(), port)
    }

    fn free_port(&mut self, preferred: u16) -> u16 {
        if !self.bindings.contains_key(&preferred) {
            return preferred;
        }

        loop {
            let port = self.next_port;
            self.next_port += 1;

            if !self.bindings.contains_key(&port) {
                return port;
            }
        }
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
                    .bindings
                    .get_mut(&dst.port())
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
                    .filter(|((host, _), sent_at)| *host == dst.ip() && fresh(sent_at))
                    .map(|((_, dst), _)| dst);

                if !self.filter.accepts(sent_to, src) {
                    bail!("sender not in NAT filter state");
                }

                dst
            }
        };

        Ok(destination)
    }
}

impl<T> Host<T> {
    pub(crate) fn new(inner: T, latency: Duration, port: u16) -> Self {
        Self {
            inner,
            ip4: None,
            ip6: None,
            port,
            span: Span::none(),
            latency,
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

    pub(crate) fn update_interface(&mut self, ip4: Option<Ipv4Addr>, ip6: Option<Ipv6Addr>) {
        self.ip4 = ip4;
        self.ip6 = ip6;
        self.offline = false;
    }

    /// Detaches this host from the network, e.g. for the dead window of a roam.
    pub(crate) fn set_offline(&mut self) {
        self.offline = true;
    }

    pub(crate) fn is_offline(&self) -> bool {
        self.offline
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
    pub(crate) fn poll_timeout(&mut self) -> Option<Instant> {
        iter::empty()
            .chain(self.inner.poll_timeout())
            .chain(self.inbox.next_transmit())
            .min()
    }
}

pub(crate) trait PollTimeout {
    fn poll_timeout(&mut self) -> Option<Instant>;
}

impl PollTimeout for SimClient {
    fn poll_timeout(&mut self) -> Option<Instant> {
        iter::empty()
            .chain(self.tunnel.alarm)
            .chain(self.tcp_dns_client.poll_timeout())
            .min()
    }
}

impl PollTimeout for SimGateway {
    fn poll_timeout(&mut self) -> Option<Instant> {
        self.tunnel.alarm
    }
}

impl PollTimeout for SimRelay {
    fn poll_timeout(&mut self) -> Option<Instant> {
        self.sut.poll_timeout()
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
            latency: self.latency,
            offline: self.offline,
            inbox: self.inbox.clone(),
        }
    }
}

/// The network: which host each address belongs to and the NAT devices hosts sit behind.
#[derive(Debug, Clone)]
pub(crate) struct RoutingTable {
    routes: IpNetworkTable<HostId>,
    nats: BTreeMap<Ipv4Addr, Nat>,
    /// The public address of the NAT device each host sits behind; hosts without one are attached directly.
    attachments: BTreeMap<HostId, Ipv4Addr>,
}

impl Default for RoutingTable {
    fn default() -> Self {
        Self {
            routes: IpNetworkTable::new(),
            nats: BTreeMap::default(),
            attachments: BTreeMap::default(),
        }
    }
}

impl RoutingTable {
    pub(crate) fn add_host<T>(
        &mut self,
        id: impl Into<HostId>,
        host: &Host<T>,
        attachment: Attachment,
    ) -> bool {
        let id = id.into();

        let interface_ips = interface_ips(host);
        assert!(
            !interface_ips.is_empty(),
            "Node must have at least one network IP"
        );

        if interface_ips.iter().any(|ip| self.contains(*ip)) {
            return false;
        }

        match attachment {
            Attachment::Direct => {
                self.attachments.remove(&id);
            }
            Attachment::Nat(ip) => {
                if !self.nats.contains_key(&ip) {
                    return false;
                }

                self.attachments.insert(id, ip);
            }
            Attachment::NewNat(nat) => {
                let ip = nat.ip4();
                if self.nats.contains_key(&ip) {
                    return false;
                }

                self.nats.insert(ip, nat);
                self.attachments.insert(id, ip);
            }
        }

        for ip in interface_ips {
            self.routes.insert(ip, id);
        }

        true
    }

    pub(crate) fn remove_host<T>(&mut self, host: &Host<T>) {
        let ips = interface_ips(host);
        assert!(!ips.is_empty(), "Node must have at least one network IP");

        for ip in ips {
            debug_assert!(self.contains(ip), "Cannot remove a non-existing host");

            self.routes.insert(ip, HostId::Stale);
        }
    }

    /// The public addresses of all NAT devices.
    pub(crate) fn nat_ips(&self) -> impl Iterator<Item = Ipv4Addr> + '_ {
        self.nats.keys().copied()
    }

    pub(crate) fn edge_config(&self, id: impl Into<HostId>) -> EdgeConfig {
        match self.attachments.get(&id.into()) {
            Some(ip) => self.nats[ip].edge_config(),
            None => EdgeConfig::Open,
        }
    }

    /// Passes a packet through the NAT devices of its sender and its receiver.
    ///
    /// Returns the receiving host and the packet with the source it sees and the address it is
    /// delivered to, or `None` if the network drops the packet.
    pub(crate) fn route(&mut self, transmit: Transmit, now: Instant) -> Option<(HostId, Transmit)> {
        let src = transmit
            .src
            .expect("`src` should always be set in these tests");
        let dst = transmit.dst;

        let src = match self.nat_of(src.ip()) {
            Some(nat) => nat.egress(src, dst, now),
            None => src,
        };

        let (host, delivered_to) = match self.deliver(src, dst, now) {
            Ok(Some(delivery)) => delivery,
            Ok(None) => {
                tracing::error!("Unhandled packet: {src} -> {dst}");
                return None;
            }
            Err(e) => {
                tracing::debug!(%src, %dst, "NAT dropped packet: {e:#}");
                return None;
            }
        };

        let transmit = Transmit {
            src: Some(src),
            dst: delivered_to,
            ..transmit
        };

        Some((host, transmit))
    }

    /// Returns the host a packet from `src` to `dst` is for and the address it is delivered to.
    fn deliver(
        &mut self,
        src: SocketAddr,
        dst: SocketAddr,
        now: Instant,
    ) -> Result<Option<(HostId, SocketAddr)>> {
        let nat_at_dst = match dst.ip() {
            IpAddr::V4(ip) => self.nats.get_mut(&ip),
            IpAddr::V6(_) => None,
        };

        if let Some(nat) = nat_at_dst {
            let internal = nat.ingress(src, dst, now)?;

            return Ok(self.host_by_ip(internal.ip()).map(|host| (host, internal)));
        }

        let Some(host) = self.host_by_ip(dst.ip()) else {
            return Ok(None);
        };

        let delivered_to = match self.attachments.get(&host) {
            Some(ip) => self
                .nats
                .get_mut(ip)
                .expect("attached NAT exists")
                .ingress(src, dst, now)?,
            None => dst,
        };

        Ok(Some((host, delivered_to)))
    }

    /// The NAT device that the host with the address `ip` sits behind, if any.
    fn nat_of(&mut self, ip: IpAddr) -> Option<&mut Nat> {
        let host = self.host_by_ip(ip)?;
        let nat_ip = self.attachments.get(&host)?;

        self.nats.get_mut(nat_ip)
    }

    fn contains(&self, ip: impl Into<IpNetwork>) -> bool {
        self.routes.exact_match(ip).is_some()
    }

    fn host_by_ip(&self, ip: IpAddr) -> Option<HostId> {
        self.routes.exact_match(ip).copied()
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
