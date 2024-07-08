use super::{sim_node::SimNode, sim_relay::SimRelay};
use crate::{ClientState, GatewayState};
use connlib_shared::messages::{ClientId, GatewayId, RelayId};
use firezone_relay::AddressFamily;
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use ip_packet::MutableIpPacket;
use rand::rngs::StdRng;
use snownet::Transmit;
use std::{
    collections::HashSet,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::Instant,
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
    fn set_transmit_src(&self, transmit: Transmit<'static>) -> Option<Transmit<'static>> {
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
    pub(crate) fn map<S>(
        &self,
        f: impl FnOnce(T, Option<Ipv4Addr>, Option<Ipv6Addr>) -> S,
        span: Span,
    ) -> Host<S> {
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

#[allow(private_bounds)]
impl<T> Host<T>
where
    T: PollTransmit,
{
    pub(crate) fn poll_transmit(&mut self) -> Option<Transmit<'static>> {
        let _guard = self.span.enter();
        let transmit = self.span.in_scope(|| self.inner.poll_transmit())?;

        self.set_transmit_src(transmit)
    }
}

#[allow(private_bounds)]
impl<T> Host<T>
where
    T: Encapsulate,
{
    pub(crate) fn encapsulate(
        &mut self,
        packet: MutableIpPacket<'_>,
        now: Instant,
    ) -> Option<Transmit<'static>> {
        let _guard = self.span.enter();

        let transmit = self
            .span
            .in_scope(|| self.inner.encapsulate(packet, now))?
            .into_owned();

        self.set_transmit_src(transmit)
    }
}

trait Encapsulate {
    fn encapsulate(&mut self, packet: MutableIpPacket<'_>, now: Instant) -> Option<Transmit<'_>>;
}

impl<TId> Encapsulate for SimNode<TId, ClientState> {
    fn encapsulate(&mut self, packet: MutableIpPacket<'_>, now: Instant) -> Option<Transmit<'_>> {
        self.state.encapsulate(packet, now)
    }
}

impl<TId> Encapsulate for SimNode<TId, GatewayState> {
    fn encapsulate(&mut self, packet: MutableIpPacket<'_>, now: Instant) -> Option<Transmit<'_>> {
        self.state.encapsulate(packet, now)
    }
}

trait PollTransmit {
    fn poll_transmit(&mut self) -> Option<Transmit<'static>>;
}

impl<TId> PollTransmit for SimNode<TId, ClientState> {
    fn poll_transmit(&mut self) -> Option<Transmit<'static>> {
        self.state.poll_transmit()
    }
}

impl<TId> PollTransmit for SimNode<TId, GatewayState> {
    fn poll_transmit(&mut self) -> Option<Transmit<'static>> {
        self.state.poll_transmit()
    }
}

impl PollTransmit for SimRelay<firezone_relay::Server<StdRng>> {
    fn poll_transmit(&mut self) -> Option<Transmit<'static>> {
        None
    }
}

#[derive(Debug, Clone)]
pub(crate) struct RoutingTable {
    routes: IpNetworkTable<ComponentId>,
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
    pub(crate) fn add_host<T>(&mut self, host: &Host<T>) -> bool
    where
        T: Id,
    {
        match (host.ip4, host.ip6) {
            (None, None) => panic!("Node must have at least one network IP"),
            (None, Some(ip6)) => {
                if self.contains(ip6) {
                    return false;
                }

                self.routes.insert(ip6, host.inner.id());
            }
            (Some(ip4), None) => {
                if self.contains(ip4) {
                    return false;
                }

                self.routes.insert(ip4, host.inner.id());
            }
            (Some(ip4), Some(ip6)) => {
                if self.contains(ip4) {
                    return false;
                }
                if self.contains(ip6) {
                    return false;
                }

                self.routes.insert(ip4, host.inner.id());
                self.routes.insert(ip6, host.inner.id());
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

                self.routes.insert(ip6, ComponentId::Stale);
            }
            (Some(ip4), None) => {
                debug_assert!(self.contains(ip4), "Cannot remove a non-existing host");

                self.routes.insert(ip4, ComponentId::Stale);
            }
            (Some(ip4), Some(ip6)) => {
                debug_assert!(self.contains(ip4), "Cannot remove a non-existing host");
                debug_assert!(self.contains(ip6), "Cannot remove a non-existing host");

                self.routes.insert(ip4, ComponentId::Stale);
                self.routes.insert(ip6, ComponentId::Stale);
            }
        }
    }

    pub(crate) fn contains(&self, ip: impl Into<IpNetwork>) -> bool {
        self.routes.exact_match(ip).is_some()
    }

    pub(crate) fn host_by_ip(&self, ip: IpAddr) -> Option<ComponentId> {
        self.routes.exact_match(ip).copied()
    }
}

trait Id {
    fn id(&self) -> ComponentId;
}

impl<TId, S> Id for SimNode<TId, S>
where
    TId: Into<ComponentId> + Copy,
{
    fn id(&self) -> ComponentId {
        self.id.into()
    }
}

impl<S> Id for SimRelay<S> {
    fn id(&self) -> ComponentId {
        self.id.into()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, PartialOrd, Ord, Eq, Hash)]
pub(crate) enum ComponentId {
    Client(ClientId),
    Gateway(GatewayId),
    Relay(RelayId),
    Stale,
}

impl From<RelayId> for ComponentId {
    fn from(v: RelayId) -> Self {
        Self::Relay(v)
    }
}

impl From<GatewayId> for ComponentId {
    fn from(v: GatewayId) -> Self {
        Self::Gateway(v)
    }
}

impl From<ClientId> for ComponentId {
    fn from(v: ClientId) -> Self {
        Self::Client(v)
    }
}
