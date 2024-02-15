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

use peer::{PacketTransform, PacketTransformClient, PacketTransformGateway, Peer, PeerStats};
use sockets::{Received, Sockets};

use futures_util::task::AtomicWaker;
use std::collections::HashMap;
use std::{collections::HashSet, hash::Hash};
use std::{fmt, net::IpAddr, sync::Arc};
use std::{
    task::{ready, Context, Poll},
    time::Instant,
};

use connlib_shared::{
    messages::{GatewayId, ResourceDescription},
    Result,
};

pub use client::ClientState;
use connlib_shared::error::ConnlibError;
pub use control_protocol::{gateway::ResolvedResourceDescriptionDns, Request};
pub use gateway::GatewayState;

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

pub type GatewayTunnel<CB> = Tunnel<CB, GatewayState, Server, ClientId, PacketTransformGateway>;
pub type ClientTunnel<CB> =
    Tunnel<CB, ClientState, snownet::Client, GatewayId, PacketTransformClient>;

/// Tunnel is a wireguard state machine that uses webrtc's ICE channels instead of UDP sockets to communicate between peers.
pub struct Tunnel<CB: Callbacks, TRoleState, TRole, TId, TTransform> {
    callbacks: CallbackErrorFacade<CB>,

    /// State that differs per role, i.e. clients vs gateways.
    role_state: TRoleState,

    device: Option<Device>,
    no_device_waker: AtomicWaker,

    connections_state: ConnectionState<TRole, TId, TTransform>,

    read_buf: [u8; MAX_UDP_SIZE],
}

impl<CB> Tunnel<CB, ClientState, snownet::Client, GatewayId, PacketTransformClient>
where
    CB: Callbacks + 'static,
{
    pub fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Result<Event<GatewayId>>> {
        loop {
            let Some(device) = self.device.as_mut() else {
                self.no_device_waker.register(cx.waker());
                return Poll::Pending;
            };

            match self.role_state.poll_next_event(cx) {
                Poll::Ready(Event::SendPacket(packet)) => {
                    device.write(packet)?;
                    continue;
                }
                Poll::Ready(other) => return Poll::Ready(Ok(other)),
                _ => (),
            }

            match self.connections_state.poll_next_event(cx) {
                Poll::Ready(Event::StopPeer(id)) => {
                    self.role_state.cleanup_connected_gateway(&id);
                    continue;
                }
                Poll::Ready(other) => return Poll::Ready(Ok(other)),
                _ => (),
            }

            match device.poll_read(&mut self.read_buf, cx) {
                Poll::Ready(Ok(Some(packet))) => {
                    let Some((peer_id, packet)) = self.role_state.encapsulate(packet) else {
                        continue;
                    };

                    if let Err(e) = self
                        .connections_state
                        .send(peer_id, packet.as_immutable().into())
                    {
                        tracing::error!(to = %packet.destination(), %peer_id, "Failed to send packet: {e}");
                        continue;
                    }
                }
                Poll::Ready(Ok(None)) => {
                    tracing::info!("Device stopped");
                    self.device = None;
                    continue;
                }
                Poll::Ready(Err(e)) => {
                    self.device = None; // Ensure we don't poll a failed device again.
                    return Poll::Ready(Err(ConnlibError::Io(e)));
                }
                Poll::Pending => {}
            }

            match self.connections_state.poll_sockets(cx) {
                Poll::Ready(Some(packet)) => {
                    device.write(packet)?;
                    continue;
                }
                Poll::Ready(None) => continue,
                Poll::Pending => {}
            }

            return Poll::Pending;
        }
    }
}

impl<CB> Tunnel<CB, GatewayState, Server, ClientId, PacketTransformGateway>
where
    CB: Callbacks + 'static,
{
    pub fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Result<Event<ClientId>>> {
        loop {
            let Some(device) = self.device.as_mut() else {
                self.no_device_waker.register(cx.waker());
                return Poll::Pending;
            };

            match self.connections_state.poll_next_event(cx) {
                Poll::Ready(Event::StopPeer(id)) => {
                    self.role_state.peers_by_ip.retain(|_, p| p.conn_id != id);
                    continue;
                }
                Poll::Ready(other) => return Poll::Ready(Ok(other)),
                _ => (),
            }

            match device.poll_read(&mut self.read_buf, cx) {
                Poll::Ready(Ok(Some(packet))) => {
                    let Some((peer_id, packet)) = self.role_state.encapsulate(packet) else {
                        continue;
                    };

                    if let Err(e) = self
                        .connections_state
                        .send(peer_id, packet.as_immutable().into())
                    {
                        tracing::error!(to = %packet.destination(), %peer_id, "Failed to send packet: {e}");
                    }

                    continue;
                }
                Poll::Ready(Ok(None)) => {
                    tracing::info!("Device stopped");
                    self.device = None;
                    continue;
                }
                Poll::Ready(Err(e)) => return Poll::Ready(Err(ConnlibError::Io(e))),
                Poll::Pending => {
                    // device not ready for reading, moving on ..
                }
            }

            match self.connections_state.poll_sockets(cx) {
                Poll::Ready(Some(packet)) => {
                    device.write(packet)?;
                    continue;
                }
                Poll::Ready(None) => continue,
                Poll::Pending => {}
            }

            return Poll::Pending;
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
            no_device_waker: Default::default(),
            connections_state: ConnectionState::new(private_key)?,
            read_buf: [0u8; MAX_UDP_SIZE],
        })
    }

    pub fn callbacks(&self) -> &CallbackErrorFacade<CB> {
        &self.callbacks
    }

    pub fn stats(&self) -> HashMap<TId, PeerStats<TId>> {
        self.connections_state
            .peers_by_id
            .iter()
            .map(|(&id, p)| (id, p.stats()))
            .collect()
    }
}

struct ConnectionState<TRole, TId, TTransform> {
    pub node: Node<TRole, TId>,
    write_buf: Box<[u8; MAX_UDP_SIZE]>,
    peers_by_id: HashMap<TId, Arc<Peer<TId, TTransform>>>,
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
            node: Node::new(private_key, std::time::Instant::now()),
            write_buf: Box::new([0; MAX_UDP_SIZE]),
            peers_by_id: HashMap::new(),
            connection_pool_timeout: sleep_until(std::time::Instant::now()).boxed(),
            sockets: Sockets::new()?,
        })
    }

    fn send(&mut self, id: TId, packet: IpPacket) -> Result<()> {
        // TODO: handle NotConnected
        let Some(transmit) = self.node.encapsulate(id, packet)? else {
            return Ok(());
        };

        self.sockets.try_send(&transmit)?;

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

        let Received {
            local,
            from,
            packet,
        } = received;

        let (conn_id, packet) = match self.node.decapsulate(
            local,
            from,
            packet,
            std::time::Instant::now(),
            self.write_buf.as_mut(),
        ) {
            Ok(Some(packet)) => packet,
            Ok(None) => return Poll::Ready(None),
            Err(e) => {
                tracing::warn!(%local, %from, "Failed to decapsulate incoming packet: {e}");
                return Poll::Ready(None);
            }
        };

        tracing::trace!(target: "wire", %local, %from, bytes = %packet.packet().len(), "read new packet");

        let Some(peer) = self.peers_by_id.get(&conn_id) else {
            tracing::error!(%conn_id, %local, %from, "Couldn't find connection");
            return Poll::Ready(None);
        };

        let maybe_device_packet = peer
            .untransform(packet.source(), self.write_buf.as_mut())
            .ok();

        Poll::Ready(maybe_device_packet)
    }

    fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Event<TId>> {
        loop {
            while let Some(transmit) = self.node.poll_transmit() {
                if let Err(e) = self.sockets.try_send(&transmit) {
                    tracing::warn!(src = ?transmit.src, dst = %transmit.dst, "Failed to send UDP packet: {e}");
                }
            }

            match self.node.poll_event() {
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
                    self.peers_by_id.remove(&id);
                    return Poll::Ready(Event::StopPeer(id));
                }
                _ => {}
            }

            if let Poll::Ready(instant) = self.connection_pool_timeout.poll_unpin(cx) {
                self.node.handle_timeout(instant);
                if let Some(timeout) = self.node.poll_timeout() {
                    self.connection_pool_timeout = sleep_until(timeout).boxed();
                }

                continue;
            }

            return Poll::Pending;
        }
    }
}

pub(crate) fn peer_by_ip<Id, TTransform>(
    peers_by_ip: &IpNetworkTable<Arc<Peer<Id, TTransform>>>,
    ip: IpAddr,
) -> Option<&Peer<Id, TTransform>> {
    peers_by_ip.longest_match(ip).map(|(_, peer)| peer.as_ref())
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

async fn sleep_until(deadline: Instant) -> Instant {
    tokio::time::sleep_until(deadline.into()).await;

    deadline
}
