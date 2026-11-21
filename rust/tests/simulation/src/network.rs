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

use super::real_client::RealClient;
use super::real_gateway::RealGateway;
use super::real_relay::RealRelay;

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

/// The mapping, filtering and expiry behaviour of the NAT in front of a host.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct EdgeConfig {
    pub(crate) mapping: Mapping,
    pub(crate) filter: FilterMode,
    pub(crate) expiry: Expiry,
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
        e.mapping == Mapping::EndpointDependent
    }

    fn port_filtered(e: EdgeConfig) -> bool {
        e.filter == FilterMode::PortRestricted
    }

    !(symmetric(a) && port_filtered(b) || symmetric(b) && port_filtered(a))
}

/// A NAT device that any number of hosts sit behind.
///
/// IPv4 is translated to the device's public address; the IPv4 addresses of the
/// hosts behind it are not routable from other hosts. IPv6 is not translated
/// (there is no NAT66 in the wild) but subject to the same stateful filtering
/// per host, like the "simple security" of [RFC 6092](https://datatracker.ietf.org/doc/html/rfc6092).
///
/// A new mapping keeps the port of its internal socket unless the
/// [`PortAssignment`] gives it a fresh port.
#[derive(Debug, Clone)]
pub(crate) struct Nat {
    ip4: Ipv4Addr,
    mapping: Mapping,
    filter: FilterMode,
    expiry: Expiry,
    assignment: PortAssignment,
    next_port: u16,
    bindings: Vec<Binding>,
    /// IPv6 destinations each host has sent to; the state backing [`FilterMode`] for IPv6.
    sent_to6: BTreeMap<(IpAddr, SocketAddr), Instant>,
}

/// How a NAT assigns public ports to new mappings.
#[derive(Debug, Clone)]
pub(crate) enum PortAssignment {
    /// A public port belongs to exactly one mapping, per [RFC 4787, REQ-3](https://datatracker.ietf.org/doc/html/rfc4787#section-4.2.1).
    Compliant,
    /// Mappings of several internal sockets share a public port ("port overloading").
    ///
    /// A new mapping keeps its internal port even if other mappings hold it, unless it draws a
    /// fresh port with [`Nat::FRESH_PORT_PROBABILITY`]. An inbound packet goes to the mapping that
    /// last sent to its sender, or else to the one that sent last.
    Overloading(fastrand::Rng),
}

#[derive(Debug, Clone)]
struct Binding {
    port: u16,
    internal: SocketAddr,
    /// The destination of an endpoint-dependent mapping.
    destination: Option<SocketAddr>,
    /// Destinations this binding has sent to and when it last did; the state backing [`FilterMode`].
    sent_to: BTreeMap<SocketAddr, Instant>,
    /// When the binding last carried traffic that refreshes it.
    refreshed_at: Instant,
}

impl Nat {
    /// Makes two hosts with the same internal port about equally likely to share their public port
    /// towards a destination or not, so that they often share it towards one destination but not
    /// towards another.
    const FRESH_PORT_PROBABILITY: f64 = 0.3;

    pub(crate) fn new(
        ip4: Ipv4Addr,
        mapping: Mapping,
        filter: FilterMode,
        expiry: Expiry,
        assignment: PortAssignment,
    ) -> Self {
        Self {
            ip4,
            mapping,
            filter,
            expiry,
            assignment,
            next_port: 42000,
            bindings: Vec::default(),
            sent_to6: BTreeMap::default(),
        }
    }

    pub(crate) fn ip4(&self) -> Ipv4Addr {
        self.ip4
    }

    fn edge_config(&self) -> EdgeConfig {
        EdgeConfig {
            mapping: self.mapping,
            filter: self.filter,
            expiry: self.expiry,
        }
    }

    fn egress(&mut self, src: SocketAddr, dst: SocketAddr, now: Instant) -> SocketAddr {
        if dst.is_ipv6() {
            self.sent_to6.insert((src.ip(), dst), now);

            return src;
        }

        let timeout = self.expiry.timeout;
        for _ in self.bindings.extract_if(.., |binding| {
            now.duration_since(binding.refreshed_at) >= timeout
        }) {}

        let destination = match self.mapping {
            Mapping::EndpointIndependent => None,
            Mapping::EndpointDependent => Some(dst),
        };

        let existing = self
            .bindings
            .iter_mut()
            .find(|binding| binding.internal == src && binding.destination == destination);

        if let Some(binding) = existing {
            binding.refreshed_at = now;
            binding.sent_to.insert(dst, now);

            return SocketAddr::new(self.ip4.into(), binding.port);
        }

        let port = self.assign_port(src.port());
        self.bindings.push(Binding {
            port,
            internal: src,
            destination,
            sent_to: BTreeMap::from([(dst, now)]),
            refreshed_at: now,
        });

        SocketAddr::new(self.ip4.into(), port)
    }

    fn assign_port(&mut self, preferred: u16) -> u16 {
        let keep = match &mut self.assignment {
            PortAssignment::Compliant => !self.is_held(preferred),
            PortAssignment::Overloading(rng) => rng.f64() >= Self::FRESH_PORT_PROBABILITY,
        };

        if keep {
            return preferred;
        }

        loop {
            let port = self.next_port;
            self.next_port += 1;

            if !self.is_held(port) {
                return port;
            }
        }
    }

    fn is_held(&self, port: u16) -> bool {
        self.bindings.iter().any(|binding| binding.port == port)
    }

    fn ingress(&mut self, src: SocketAddr, dst: SocketAddr, now: Instant) -> Result<SocketAddr> {
        let timeout = self.expiry.timeout;
        let fresh = move |sent_at: &Instant| now.duration_since(*sent_at) < timeout;

        let destination = match dst.ip() {
            IpAddr::V4(ip) => {
                if ip != self.ip4 {
                    bail!("IPv4 address behind NAT is not routable");
                }

                let filter = self.filter;
                let binding = self
                    .bindings
                    .iter_mut()
                    .filter(|binding| binding.port == dst.port() && fresh(&binding.refreshed_at))
                    .filter(|binding| {
                        let sent_to = binding
                            .sent_to
                            .iter()
                            .filter(|(_, sent_at)| fresh(sent_at))
                            .map(|(dst, _)| dst);

                        filter.accepts(sent_to, src)
                    })
                    .max_by_key(|binding| {
                        (
                            binding.sent_to.get(&src).copied(),
                            binding.sent_to.values().max().copied(),
                        )
                    })
                    .context("no NAT binding admits the sender")?;

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

impl PollTimeout for RealClient {
    fn poll_timeout(&mut self) -> Option<Instant> {
        iter::empty()
            .chain(self.tunnel.alarm)
            .chain(self.tcp_dns_client.poll_timeout())
            .min()
    }
}

impl PollTimeout for RealGateway {
    fn poll_timeout(&mut self) -> Option<Instant> {
        self.tunnel.alarm
    }
}

impl PollTimeout for RealRelay {
    fn poll_timeout(&mut self) -> Option<Instant> {
        self.server.poll_timeout()
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
    /// The public address of the NAT device each host sits behind; relays have none.
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
    pub(crate) fn add_nat(&mut self, nat: Nat) -> bool {
        let ip = nat.ip4();
        if self.nats.contains_key(&ip) {
            return false;
        }

        self.nats.insert(ip, nat);

        true
    }

    /// Adds a host behind the NAT device with the public IPv4 address `nat`.
    pub(crate) fn add_host<T>(
        &mut self,
        id: impl Into<HostId>,
        host: &Host<T>,
        nat: Ipv4Addr,
    ) -> bool {
        let id = id.into();

        if !self.nats.contains_key(&nat) {
            return false;
        }

        if !self.add_routes(id, host) {
            return false;
        }

        self.attachments.insert(id, nat);

        true
    }

    /// Adds a relay, which is publicly reachable.
    pub(crate) fn add_relay<T>(&mut self, id: RelayId, host: &Host<T>) -> bool {
        self.add_routes(HostId::Relay(id), host)
    }

    fn add_routes<T>(&mut self, id: HostId, host: &Host<T>) -> bool {
        let interface_ips = interface_ips(host);
        assert!(
            !interface_ips.is_empty(),
            "Node must have at least one network IP"
        );

        if interface_ips.iter().any(|ip| self.contains(*ip)) {
            return false;
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

    /// The edge and port assignment of each NAT device that two or more Clients sit behind.
    pub(crate) fn edges_shared_by_clients(
        &self,
    ) -> impl Iterator<Item = (EdgeConfig, &PortAssignment)> + '_ {
        self.nats.iter().filter_map(|(ip, nat)| {
            let clients = self
                .attachments
                .iter()
                .filter(|(id, attached)| matches!(id, HostId::Client(_)) && *attached == ip)
                .count();

            (clients >= 2).then(|| (nat.edge_config(), &nat.assignment))
        })
    }

    /// The edge of a host behind a NAT device, i.e. a Client or a Gateway.
    pub(crate) fn edge_config(&self, id: impl Into<HostId>) -> EdgeConfig {
        self.nats[&self.attachments[&id.into()]].edge_config()
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

    pub(crate) fn contains(&self, ip: impl Into<IpNetwork>) -> bool {
        self.routes.exact_match(ip).is_some()
    }

    pub(crate) fn host_by_ip(&self, ip: IpAddr) -> Option<HostId> {
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

#[cfg(test)]
mod tests {
    use super::*;

    const NAT_IP: Ipv4Addr = Ipv4Addr::new(203, 0, 113, 1);
    const SERVER_1: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(198, 51, 100, 1)), 3478);
    const SERVER_2: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(198, 51, 100, 2)), 3478);
    const HOST_1: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1)), 52625);
    const HOST_2: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 2)), 52625);
    /// Keeps the internal port on the first two new mappings.
    const SEED: u64 = 1;
    const EXPIRY: Expiry = Expiry {
        timeout: Duration::from_secs(30),
        inbound_refreshes: false,
    };

    #[test]
    fn new_mapping_keeps_internal_port() {
        let mut nat = Nat::new(
            NAT_IP,
            Mapping::EndpointIndependent,
            FilterMode::Open,
            EXPIRY,
            PortAssignment::Compliant,
        );

        let public = nat.egress(HOST_1, SERVER_1, Instant::now());

        assert_eq!(public, SocketAddr::new(NAT_IP.into(), HOST_1.port()));
    }

    #[test]
    fn port_held_by_live_mapping_is_not_reused() {
        let mut nat = Nat::new(
            NAT_IP,
            Mapping::EndpointIndependent,
            FilterMode::Open,
            EXPIRY,
            PortAssignment::Compliant,
        );
        let now = Instant::now();

        let first = nat.egress(HOST_1, SERVER_1, now);
        let second = nat.egress(HOST_2, SERVER_1, now);

        assert_eq!(first.port(), HOST_1.port());
        assert_ne!(second.port(), HOST_2.port());
    }

    #[test]
    fn endpoint_independent_mapping_reuses_public_socket() {
        let mut nat = Nat::new(
            NAT_IP,
            Mapping::EndpointIndependent,
            FilterMode::Open,
            EXPIRY,
            PortAssignment::Compliant,
        );
        let now = Instant::now();

        let to_server_1 = nat.egress(HOST_1, SERVER_1, now);
        let to_server_2 = nat.egress(HOST_1, SERVER_2, now);

        assert_eq!(to_server_1, to_server_2);
    }

    #[test]
    fn endpoint_dependent_mapping_mints_public_socket_per_destination() {
        let mut nat = Nat::new(
            NAT_IP,
            Mapping::EndpointDependent,
            FilterMode::PortRestricted,
            EXPIRY,
            PortAssignment::Compliant,
        );
        let now = Instant::now();

        let to_server_1 = nat.egress(HOST_1, SERVER_1, now);
        let to_server_2 = nat.egress(HOST_1, SERVER_2, now);

        assert_ne!(to_server_1, to_server_2);
    }

    #[test]
    fn expired_mapping_frees_its_port() {
        let mut nat = Nat::new(
            NAT_IP,
            Mapping::EndpointIndependent,
            FilterMode::Open,
            EXPIRY,
            PortAssignment::Compliant,
        );
        let now = Instant::now();

        nat.egress(HOST_1, SERVER_1, now);
        let public = nat.egress(HOST_2, SERVER_1, now + EXPIRY.timeout);

        assert_eq!(public.port(), HOST_2.port());
    }

    #[test]
    fn overloading_keeps_internal_port_held_by_another_mapping() {
        let mut nat = Nat::new(
            NAT_IP,
            Mapping::EndpointIndependent,
            FilterMode::Open,
            EXPIRY,
            PortAssignment::Overloading(fastrand::Rng::with_seed(SEED)),
        );
        let now = Instant::now();

        let first = nat.egress(HOST_1, SERVER_1, now);
        let second = nat.egress(HOST_2, SERVER_1, now);

        assert_eq!(first, second);
    }

    #[test]
    fn overloading_delivers_inbound_to_last_sender() {
        let mut nat = Nat::new(
            NAT_IP,
            Mapping::EndpointIndependent,
            FilterMode::Open,
            EXPIRY,
            PortAssignment::Overloading(fastrand::Rng::with_seed(SEED)),
        );
        let now = Instant::now();

        let public = nat.egress(HOST_1, SERVER_1, now);
        nat.egress(HOST_2, SERVER_1, now + Duration::from_secs(1));
        let internal = nat
            .ingress(SERVER_1, public, now + Duration::from_secs(2))
            .unwrap();

        assert_eq!(internal, HOST_2);
    }
}
