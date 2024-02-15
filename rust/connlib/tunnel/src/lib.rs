//! Connlib tunnel implementation.
//!
//! This is both the wireguard and ICE implementation that should work in tandem.
//! [Tunnel] is the main entry-point for this crate.
use boringtun::x25519::StaticSecret;

use connlib_shared::{messages::ReuseConnection, CallbackErrorFacade, Callbacks, Error};
use futures_util::future::BoxFuture;
use futures_util::FutureExt;
use ip_network_table::IpNetworkTable;
use pnet_packet::Packet;
use snownet::{IpPacket, Node, Server};

use hickory_resolver::proto::rr::RecordType;
use parking_lot::Mutex;
use peer::{PacketTransform, PacketTransformClient, PacketTransformGateway, Peer, PeerStats};
use sockets::{Received, Sockets};
use tokio::time::MissedTickBehavior;

use arc_swap::{access::Access, ArcSwapOption};
use futures_util::task::AtomicWaker;
use std::collections::HashMap;
use std::net::{Ipv4Addr, Ipv6Addr};
use std::{collections::HashSet, hash::Hash};
use std::{fmt, net::IpAddr, sync::Arc, time::Duration};
use std::{
    task::{ready, Context, Poll},
    time::Instant,
};
use tokio::time::Interval;

use connlib_shared::{
    messages::{GatewayId, ResourceDescription},
    Result,
};

pub use client::ClientState;
use connlib_shared::error::ConnlibError;
pub use control_protocol::{gateway::ResolvedResourceDescriptionDns, Request};
pub use gateway::GatewayState;

use crate::ip_packet::MutableIpPacket;
use connlib_shared::messages::ClientId;
use device_channel::Device;

mod client;
mod control_protocol;
mod device_channel;
mod dns;
mod gateway;
mod ip_packet;
mod peer;
mod sockets;

const MAX_UDP_SIZE: usize = (1 << 16) - 1;
const DNS_QUERIES_QUEUE_SIZE: usize = 100;

const REALM: &str = "firezone";

#[cfg(target_os = "linux")]
const FIREZONE_MARK: u32 = 0xfd002021;

pub(crate) fn get_v4(ip: IpAddr) -> Option<Ipv4Addr> {
    match ip {
        IpAddr::V4(v4) => Some(v4),
        IpAddr::V6(_) => None,
    }
}

pub(crate) fn get_v6(ip: IpAddr) -> Option<Ipv6Addr> {
    match ip {
        IpAddr::V4(_) => None,
        IpAddr::V6(v6) => Some(v6),
    }
}

struct Connections<TRole, TId, TTransform> {
    pub node: Node<TRole, TId>,
    write_buf: Box<[u8; MAX_UDP_SIZE]>,
    peers_by_id: HashMap<TId, Arc<Peer<TId, TTransform>>>,
}

impl<TRole, TId, TTransform> Connections<TRole, TId, TTransform>
where
    TId: Eq + Hash + Copy + fmt::Display,
    TTransform: PacketTransform,
{
    fn new(connection_pool: Node<TRole, TId>) -> Self {
        Self {
            node: connection_pool,
            write_buf: Box::new([0; MAX_UDP_SIZE]),
            peers_by_id: HashMap::new(),
        }
    }

    fn handle_socket_packet<'a>(
        &'a mut self,
        packet: Received<'a>,
    ) -> Option<device_channel::Packet<'a>> {
        let Received {
            local,
            from,
            packet,
        } = packet;

        let (conn_id, packet) = self
            .node
            .decapsulate(
                local,
                from,
                packet,
                std::time::Instant::now(),
                self.write_buf.as_mut(),
            )
            .inspect_err(
                |e| tracing::warn!(%local, %from, "Failed to decapsulate incoming packet: {e}"),
            )
            .ok()??;

        tracing::trace!(target: "wire", %local, %from, bytes = %packet.packet().len(), "read new packet");

        let Some(peer) = self.peers_by_id.get(&conn_id) else {
            tracing::error!(%conn_id, %local, %from, "Couldn't find connection");
            return None;
        };

        return peer
            .untransform(packet.source(), self.write_buf.as_mut())
            .ok();
    }
}

struct ConnectionState<TRole, TId, TTransform> {
    connections: Connections<TRole, TId, TTransform>,
    connection_pool_timeout: BoxFuture<'static, std::time::Instant>,
    sockets: Sockets,
}

impl<TRole, TId, TTransform> ConnectionState<TRole, TId, TTransform>
where
    TId: Eq + Hash + Copy + fmt::Display,
    TTransform: PacketTransform,
{
    fn new(private_key: StaticSecret) -> Result<Self> {
        Ok(ConnectionState {
            connections: Connections::new(Node::new(private_key, std::time::Instant::now())),
            connection_pool_timeout: sleep_until(std::time::Instant::now()).boxed(),
            sockets: Sockets::new()?,
        })
    }

    fn send(&mut self, id: TId, packet: IpPacket) -> Result<()> {
        // TODO: handle NotConnected
        let Some(transmit) = self.connections.node.encapsulate(id, packet)? else {
            return Ok(());
        };

        self.sockets.try_send(&transmit)?;

        tracing::trace!(target: "wire", action = "write", to = %transmit.dst, src = ?transmit.src, bytes = %transmit.payload.len());

        Ok(())
    }

    fn poll_sockets<'a>(
        &'a mut self,
        cx: &mut Context<'_>,
    ) -> Poll<Option<device_channel::Packet<'a>>> {
        let received = match ready!(self.sockets.poll_recv_from(cx)) {
            Ok(received) => received,
            Err(e) => {
                tracing::warn!("Failed to read socket: {e}");

                cx.waker().wake_by_ref(); // Immediately schedule a new wake-up.
                return Poll::Pending;
            }
        };

        let maybe_device_packet = self.connections.handle_socket_packet(received);

        Poll::Ready(maybe_device_packet)
    }

    fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Event<TId>> {
        loop {
            while let Some(transmit) = self.connections.node.poll_transmit() {
                if let Err(e) = self.sockets.try_send(&transmit) {
                    tracing::warn!(src = ?transmit.src, dst = %transmit.dst, "Failed to send UDP packet: {e}");
                }
            }

            match self.connections.node.poll_event() {
                Some(snownet::Event::SignalIceCandidate {
                    connection,
                    candidate,
                }) => {
                    return Poll::Ready(Event::SignalIceCandidate {
                        conn_id: connection,
                        candidate,
                    });
                }
                Some(snownet::Event::ConnectionFailed(id)) => {
                    self.connections.peers_by_id.remove(&id);
                    return Poll::Ready(Event::StopPeer(id));
                }
                _ => {}
            }

            if let Poll::Ready(instant) = self.connection_pool_timeout.poll_unpin(cx) {
                self.connections.node.handle_timeout(instant);
                if let Some(timeout) = self.connections.node.poll_timeout() {
                    self.connection_pool_timeout = sleep_until(timeout).boxed();
                }

                continue;
            }

            return Poll::Pending;
        }
    }
}

pub type GatewayTunnel<CB> = Tunnel<CB, GatewayState, Server, ClientId, PacketTransformGateway>;
pub type ClientTunnel<CB> =
    Tunnel<CB, ClientState, snownet::Client, GatewayId, PacketTransformClient>;

/// Tunnel is a wireguard state machine that uses webrtc's ICE channels instead of UDP sockets to communicate between peers.
pub struct Tunnel<CB: Callbacks, TRoleState, TRole, TId, TTransform> {
    callbacks: CallbackErrorFacade<CB>,

    /// State that differs per role, i.e. clients vs gateways.
    role_state: Mutex<TRoleState>,

    mtu_refresh_interval: Mutex<Interval>,

    device: Arc<ArcSwapOption<Device>>,
    no_device_waker: AtomicWaker,

    connections_state: Mutex<ConnectionState<TRole, TId, TTransform>>,
}

impl<CB> Tunnel<CB, ClientState, snownet::Client, GatewayId, PacketTransformClient>
where
    CB: Callbacks + 'static,
{
    pub async fn next_event(&self) -> Result<Event<GatewayId>> {
        std::future::poll_fn(|cx| loop {
            {
                let guard = self.device.load();

                if let Some(device) = guard.as_ref() {
                    match self.poll_device(device, cx) {
                        Poll::Ready(Ok(Some(event))) => return Poll::Ready(Ok(event)),
                        Poll::Ready(Ok(None)) => {
                            tracing::info!("Device stopped");
                            self.device.store(None);
                            continue;
                        }
                        Poll::Ready(Err(e)) => {
                            self.device.store(None); // Ensure we don't poll a failed device again.
                            return Poll::Ready(Err(e));
                        }
                        Poll::Pending => {}
                    }
                } else {
                    self.no_device_waker.register(cx.waker());
                }
            }

            match self.role_state.lock().poll_next_event(cx) {
                Poll::Ready(Event::SendPacket(packet)) => {
                    let Some(device) = self.device.load().clone() else {
                        continue;
                    };

                    device.write(packet)?;
                    continue;
                }
                Poll::Ready(other) => return Poll::Ready(Ok(other)),
                _ => (),
            }

            match ready!(self.poll_next_event_common(cx)) {
                Event::StopPeer(id) => self.role_state.lock().cleanup_connected_gateway(&id),
                e => return Poll::Ready(Ok(e)),
            }
        })
        .await
    }

    pub(crate) fn poll_device(
        &self,
        device: &Device,
        cx: &mut Context<'_>,
    ) -> Poll<Result<Option<Event<GatewayId>>>> {
        let mut read_buf = [0; MAX_UDP_SIZE];

        loop {
            let Some(packet) = ready!(device.poll_read(&mut read_buf, cx))? else {
                return Poll::Ready(Ok(None));
            };

            tracing::trace!(target: "wire", action = "read", from = "device", dest = %packet.destination(), bytes = %packet.packet().len());

            let (packet, peer_id) = {
                let mut role_state = self.role_state.lock();
                let (packet, dest) = match role_state.handle_dns(packet) {
                    Ok(Some(response)) => {
                        device.write(response)?;
                        continue;
                    }
                    Ok(None) => continue,
                    Err(non_dns_packet) => non_dns_packet,
                };

                let Some(peer) = peer_by_ip(&role_state.peers_by_ip, dest) else {
                    role_state.on_connection_intent_ip(dest);
                    continue;
                };

                let Some(packet) = peer.transform(packet) else {
                    continue;
                };
                (packet, peer.conn_id)
            };

            self.send_peer(packet, peer_id);
        }
    }
}

impl<CB> Tunnel<CB, GatewayState, Server, ClientId, PacketTransformGateway>
where
    CB: Callbacks + 'static,
{
    pub fn poll_next_event(&self, cx: &mut Context<'_>) -> Poll<Result<Event<ClientId>>> {
        let mut read_buf = [0; MAX_UDP_SIZE];

        loop {
            {
                let device = self.device.load();

                match device.as_ref().map(|d| d.poll_read(&mut read_buf, cx)) {
                    Some(Poll::Ready(Ok(Some(packet)))) => {
                        let (packet, peer_id) = {
                            let dest = packet.destination();

                            let role_state = self.role_state.lock();
                            let Some(peer) = peer_by_ip(&role_state.peers_by_ip, dest) else {
                                continue;
                            };

                            let Some(packet) = peer.transform(packet) else {
                                continue;
                            };
                            (packet, peer.conn_id)
                        };
                        self.send_peer(packet, peer_id);

                        continue;
                    }
                    Some(Poll::Ready(Ok(None))) => {
                        tracing::info!("Device stopped");
                        self.device.store(None);
                    }
                    Some(Poll::Ready(Err(e))) => return Poll::Ready(Err(ConnlibError::Io(e))),
                    Some(Poll::Pending) => {
                        // device not ready for reading, moving on ..
                    }
                    None => {
                        self.no_device_waker.register(cx.waker());
                    }
                }
            }

            match ready!(self.poll_next_event_common(cx)) {
                Event::StopPeer(id) => self
                    .role_state
                    .lock()
                    .peers_by_ip
                    .retain(|_, p| p.conn_id != id),
                e => return Poll::Ready(Ok(e)),
            }
        }
    }
}

#[allow(dead_code)]
#[derive(Debug, Clone)]
pub struct TunnelStats<TId> {
    peer_connections: HashMap<TId, PeerStats<TId>>,
}

impl<CB, TRoleState, TRole, TId, TTransform> Tunnel<CB, TRoleState, TRole, TId, TTransform>
where
    CB: Callbacks + 'static,
    TId: Eq + Hash + Copy + fmt::Display,
    TTransform: PacketTransform,
{
    pub fn stats(&self) -> HashMap<TId, PeerStats<TId>> {
        self.connections_state
            .lock()
            .connections
            .peers_by_id
            .iter()
            .map(|(&id, p)| (id, p.stats()))
            .collect()
    }

    fn poll_next_event_common(&self, cx: &mut Context<'_>) -> Poll<Event<TId>> {
        loop {
            if self.mtu_refresh_interval.lock().poll_tick(cx).is_ready() {
                let Some(device) = self.device.load().clone() else {
                    tracing::debug!("Device temporarily not available");
                    continue;
                };

                if let Err(e) = device.refresh_mtu() {
                    tracing::error!(error = ?e, "refresh_mtu");
                }
            }

            if let Poll::Ready(event) = self.connections_state.lock().poll_next_event(cx) {
                return Poll::Ready(event);
            }

            let mut connection_state = self.connections_state.lock();
            let Some(p) = ready!(connection_state.poll_sockets(cx)) else {
                continue;
            };

            let dev = self.device.load();
            let Some(dev) = dev.as_ref() else {
                continue;
            };

            // TODO: add info
            tracing::trace!(target: "wire", action = "write", to = "device");
            if let Err(e) = dev.write(p) {
                tracing::error!("Error writing packet to device: {e:?}");
            }
        }
    }

    fn send_peer(&self, packet: MutableIpPacket, peer_id: TId) {
        if let Err(e) = self
            .connections_state
            .lock()
            .send(peer_id, packet.as_immutable().into())
        {
            tracing::error!(to = %packet.destination(), %peer_id, "Failed to send packet: {e}");
        }
    }
}

pub(crate) fn peer_by_ip<Id, TTransform>(
    peers_by_ip: &IpNetworkTable<Arc<Peer<Id, TTransform>>>,
    ip: IpAddr,
) -> Option<&Peer<Id, TTransform>> {
    peers_by_ip.longest_match(ip).map(|(_, peer)| peer.as_ref())
}

#[derive(Debug)]
pub struct DnsQuery<'a> {
    pub name: String,
    pub record_type: RecordType,
    // We could be much more efficient with this field,
    // we only need the header to create the response.
    pub query: crate::ip_packet::IpPacket<'a>,
}

impl<'a> DnsQuery<'a> {
    pub(crate) fn into_owned(self) -> DnsQuery<'static> {
        let Self {
            name,
            record_type,
            query,
        } = self;
        let buf = query.packet().to_vec();
        let query = ip_packet::IpPacket::owned(buf)
            .expect("We are constructing the ip packet from an ip packet");

        DnsQuery {
            name,
            record_type,
            query,
        }
    }
}

pub enum Event<TId> {
    SignalIceCandidate {
        conn_id: TId,
        candidate: String,
    },
    ConnectionIntent {
        resource: ResourceDescription,
        connected_gateway_ids: HashSet<GatewayId>,
        reference: usize,
    },
    RefreshResources {
        connections: Vec<ReuseConnection>,
    },
    SendPacket(device_channel::Packet<'static>),
    StopPeer(TId),
}

impl<CB, TRoleState, TRole, TId, TTransform> Tunnel<CB, TRoleState, TRole, TId, TTransform>
where
    CB: Callbacks + 'static,
    TId: Eq + Hash + Copy + fmt::Display,
    TTransform: PacketTransform,
    TRoleState: Default,
{
    /// Creates a new tunnel.
    ///
    /// # Parameters
    /// - `private_key`: wireguard's private key.
    /// -  `control_signaler`: this is used to send SDP from the tunnel to the control plane.
    #[tracing::instrument(level = "trace", skip(private_key, callbacks))]
    pub fn new(private_key: StaticSecret, callbacks: CB) -> Result<Self> {
        Ok(Self {
            device: Default::default(),
            callbacks: CallbackErrorFacade(callbacks),
            role_state: Default::default(),
            mtu_refresh_interval: Mutex::new(mtu_refresh_interval()),
            no_device_waker: Default::default(),
            connections_state: Mutex::new(ConnectionState::new(private_key)?),
        })
    }

    pub fn callbacks(&self) -> &CallbackErrorFacade<CB> {
        &self.callbacks
    }
}

/// Constructs the interval for refreshing the MTU of our TUN device.
fn mtu_refresh_interval() -> Interval {
    let mut interval = tokio::time::interval(Duration::from_secs(30));
    interval.set_missed_tick_behavior(MissedTickBehavior::Delay);

    interval
}

async fn sleep_until(deadline: Instant) -> Instant {
    tokio::time::sleep_until(deadline.into()).await;

    deadline
}
