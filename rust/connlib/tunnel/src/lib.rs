//! Connlib tunnel implementation.
//!
//! This is both the wireguard and ICE implementation that should work in tandem.
//! [Tunnel] is the main entry-point for this crate.

use boringtun::x25519::StaticSecret;
use connlib_shared::{
    messages::{ClientId, GatewayId, ResourceId, ReuseConnection},
    CallbackErrorFacade, Callbacks, Error, Result,
};
use device_channel::Device;
use futures_util::{future::BoxFuture, task::AtomicWaker, FutureExt};
use peer::PacketTransform;
use peer_store::PeerStore;
use pnet_packet::Packet;
use snownet::{Node, Server};
use sockets::{Received, Sockets};
use std::{
    collections::HashSet,
    fmt,
    hash::Hash,
    io,
    task::{ready, Context, Poll},
    time::{Duration, Instant},
};

pub use client::ClientState;
pub use control_protocol::client::Request;
pub use gateway::{GatewayState, ResolvedResourceDescriptionDns};
use ip_packet::IpPacket;

mod client;
mod control_protocol {
    pub mod client;
}
mod device_channel;
mod dns;
mod gateway;
mod ip_packet;
mod peer;
mod peer_store;
mod sockets;
mod utils;

const MAX_UDP_SIZE: usize = (1 << 16) - 1;
const DNS_QUERIES_QUEUE_SIZE: usize = 100;

const REALM: &str = "firezone";

#[cfg(target_os = "linux")]
const FIREZONE_MARK: u32 = 0xfd002021;

pub type GatewayTunnel<CB> = Tunnel<CB, GatewayState, Server, ClientId>;
pub type ClientTunnel<CB> = Tunnel<CB, ClientState, snownet::Client, GatewayId>;

/// Tunnel is a wireguard state machine that uses webrtc's ICE channels instead of UDP sockets to communicate between peers.
pub struct Tunnel<CB: Callbacks, TRoleState, TRole, TId> {
    callbacks: CallbackErrorFacade<CB>,

    /// State that differs per role, i.e. clients vs gateways.
    role_state: TRoleState,

    device: Option<Device>,
    no_device_waker: AtomicWaker,

    connections_state: ConnectionState<TRole, TId>,

    read_buf: [u8; MAX_UDP_SIZE],
}

impl<CB> Tunnel<CB, ClientState, snownet::Client, GatewayId>
where
    CB: Callbacks + 'static,
{
    pub fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Result<Event<GatewayId>>> {
        let Some(device) = self.device.as_mut() else {
            self.no_device_waker.register(cx.waker());
            return Poll::Pending;
        };

        match self.role_state.poll_next_event(cx) {
            Poll::Ready(Event::SendPacket(packet)) => {
                device.write(packet)?;
                cx.waker().wake_by_ref();
            }
            Poll::Ready(other) => return Poll::Ready(Ok(other)),
            _ => (),
        }

        match self.connections_state.poll_next_event(cx) {
            Poll::Ready(Event::StopPeer(id)) => {
                self.role_state.cleanup_connected_gateway(&id);
                cx.waker().wake_by_ref();
            }
            Poll::Ready(other) => return Poll::Ready(Ok(other)),
            _ => (),
        }

        match self
            .connections_state
            .poll_sockets(device, &mut self.role_state.peers, cx)?
        {
            Poll::Ready(()) => {
                cx.waker().wake_by_ref();
            }
            Poll::Pending => {}
        }

        ready!(self.connections_state.sockets.poll_send_ready(cx))?; // Ensure socket is ready before we read from device.

        match device.poll_read(&mut self.read_buf, cx)? {
            Poll::Ready(Some(packet)) => {
                let Some((peer_id, packet)) = self.role_state.encapsulate(packet, Instant::now())
                else {
                    cx.waker().wake_by_ref();
                    return Poll::Pending;
                };

                self.connections_state.send(peer_id, packet.as_immutable());

                cx.waker().wake_by_ref();
            }
            Poll::Ready(None) => {
                tracing::info!("Device stopped");
                self.device = None;

                self.no_device_waker.register(cx.waker());
                return Poll::Pending;
            }
            Poll::Pending => {}
        }

        Poll::Pending
    }
}

impl<CB> Tunnel<CB, GatewayState, Server, ClientId>
where
    CB: Callbacks + 'static,
{
    pub fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Result<Event<ClientId>>> {
        match self.role_state.poll(cx) {
            Poll::Ready(()) => {
                cx.waker().wake_by_ref();
            }
            Poll::Pending => {}
        }

        let Some(device) = self.device.as_mut() else {
            self.no_device_waker.register(cx.waker());
            return Poll::Pending;
        };

        match self.connections_state.poll_next_event(cx) {
            Poll::Ready(Event::StopPeer(id)) => {
                self.role_state.peers.remove(&id);
                cx.waker().wake_by_ref();
            }
            Poll::Ready(other) => return Poll::Ready(Ok(other)),
            _ => (),
        }

        match self
            .connections_state
            .poll_sockets(device, &mut self.role_state.peers, cx)?
        {
            Poll::Ready(()) => {
                cx.waker().wake_by_ref();
            }
            Poll::Pending => {}
        }

        ready!(self.connections_state.sockets.poll_send_ready(cx))?; // Ensure socket is ready before we read from device.

        match device.poll_read(&mut self.read_buf, cx)? {
            Poll::Ready(Some(packet)) => {
                let Some((peer_id, packet)) = self.role_state.encapsulate(packet) else {
                    cx.waker().wake_by_ref();
                    return Poll::Pending;
                };

                self.connections_state.send(peer_id, packet.as_immutable());

                cx.waker().wake_by_ref();
            }
            Poll::Ready(None) => {
                tracing::info!("Device stopped");
                self.device = None;

                self.no_device_waker.register(cx.waker());
                return Poll::Pending;
            }
            Poll::Pending => {
                // device not ready for reading, moving on ..
            }
        }

        Poll::Pending
    }
}

impl<CB, TRoleState, TRole, TId> Tunnel<CB, TRoleState, TRole, TId>
where
    CB: Callbacks + 'static,
    TId: Eq + Hash + Copy + fmt::Display,
    TRoleState: Default,
{
    /// Creates a new tunnel.
    ///
    /// # Parameters
    /// - `private_key`: wireguard's private key.
    /// -  `control_signaler`: this is used to send SDP from the tunnel to the control plane.
    #[tracing::instrument(level = "trace", skip(private_key, callbacks))]
    pub fn new(private_key: StaticSecret, callbacks: CB) -> Result<Self> {
        let callbacks = CallbackErrorFacade(callbacks);
        let connections_state = ConnectionState::new(private_key)?;

        // TODO: Eventually, this should move into the `connlib-client-android` crate.
        #[cfg(target_os = "android")]
        {
            if let Some(ip4_socket) = connections_state.sockets.ip4_socket_fd() {
                callbacks.protect_file_descriptor(ip4_socket)?;
            }
            if let Some(ip6_socket) = connections_state.sockets.ip6_socket_fd() {
                callbacks.protect_file_descriptor(ip6_socket)?;
            }
        }

        Ok(Self {
            device: Default::default(),
            callbacks,
            role_state: Default::default(),
            no_device_waker: Default::default(),
            connections_state,
            read_buf: [0u8; MAX_UDP_SIZE],
        })
    }

    pub fn callbacks(&self) -> &CallbackErrorFacade<CB> {
        &self.callbacks
    }
}

struct ConnectionState<TRole, TId> {
    pub node: Node<TRole, TId>,
    write_buf: Box<[u8; MAX_UDP_SIZE]>,
    connection_pool_timeout: BoxFuture<'static, std::time::Instant>,
    stats_timer: tokio::time::Interval,
    sockets: Sockets,
}

impl<TRole, TId> ConnectionState<TRole, TId>
where
    TId: Eq + Hash + Copy + fmt::Display,
{
    fn new(private_key: StaticSecret) -> Result<Self> {
        Ok(ConnectionState {
            node: Node::new(private_key, std::time::Instant::now()),
            write_buf: Box::new([0; MAX_UDP_SIZE]),
            connection_pool_timeout: sleep_until(std::time::Instant::now()).boxed(),
            sockets: Sockets::new()?,
            stats_timer: tokio::time::interval(Duration::from_secs(60)),
        })
    }

    fn send(&mut self, id: TId, packet: IpPacket) {
        let to = packet.destination();

        if let Err(e) = self.try_send(id, packet) {
            tracing::warn!(%to, %id, "Failed to send packet: {e}");
        }
    }

    fn try_send(&mut self, id: TId, packet: IpPacket) -> Result<()> {
        // TODO: handle NotConnected
        let Some(transmit) = self.node.encapsulate(id, packet.into())? else {
            return Ok(());
        };

        self.sockets.try_send(&transmit)?;

        Ok(())
    }

    // TODO: passing the peer_store looks weird, we can just remove ConnectionState and move everything into Tunnel, there's no Mutexes any longer that justify this separation
    fn poll_sockets<TTransform, TResource>(
        &mut self,
        device: &mut Device,
        peer_store: &mut PeerStore<TId, TTransform, TResource>,
        cx: &mut Context<'_>,
    ) -> Poll<io::Result<()>>
    where
        TTransform: PacketTransform,
        TResource: Clone,
    {
        let received = match ready!(self.sockets.poll_recv_from(cx)) {
            Ok(received) => received,
            Err(e) => {
                tracing::warn!("Failed to read socket: {e}");

                cx.waker().wake_by_ref(); // Immediately schedule a new wake-up.
                return Poll::Pending;
            }
        };

        for received in received {
            let Received {
                local,
                from,
                packet,
            } = received;

            let (conn_id, packet) = match self.node.decapsulate(
                local,
                from,
                packet.as_ref(),
                std::time::Instant::now(),
                self.write_buf.as_mut(),
            ) {
                Ok(Some(packet)) => packet,
                Ok(None) => {
                    continue;
                }
                Err(e) => {
                    tracing::warn!(%local, %from, num_bytes = %packet.len(), "Failed to decapsulate incoming packet: {e}");

                    continue;
                }
            };

            tracing::trace!(target: "wire", %local, %from, bytes = %packet.packet().len(), "read new packet");

            let Some(peer) = peer_store.get_mut(&conn_id) else {
                tracing::error!(%conn_id, %local, %from, "Couldn't find connection");

                continue;
            };

            let packet = match peer.untransform(packet.into()) {
                Ok(packet) => packet,
                Err(e) => {
                    tracing::warn!(%conn_id, %local, %from, "Failed to transform packet: {e}");

                    continue;
                }
            };

            device.write(packet.as_immutable())?;
        }

        Poll::Ready(Ok(()))
    }

    fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Event<TId>> {
        if self.stats_timer.poll_tick(cx).is_ready() {
            let (node_stats, conn_stats) = self.node.stats();

            tracing::debug!(target: "connlib::stats", "{node_stats:?}");

            for (id, stats) in conn_stats {
                tracing::debug!(target: "connlib::stats", %id, "{stats:?}");
            }

            cx.waker().wake_by_ref();
        }

        if let Err(e) = ready!(self.sockets.poll_send_ready(cx)) {
            tracing::warn!("Failed to poll sockets for readiness: {e}");
        };

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
                return Poll::Ready(Event::StopPeer(id));
            }
            _ => {}
        }

        if let Poll::Ready(instant) = self.connection_pool_timeout.poll_unpin(cx) {
            self.node.handle_timeout(instant);
            if let Some(timeout) = self.node.poll_timeout() {
                self.connection_pool_timeout = sleep_until(timeout).boxed();
            }

            cx.waker().wake_by_ref();
        }

        Poll::Pending
    }
}

pub enum Event<TId> {
    SignalIceCandidate {
        conn_id: TId,
        candidate: String,
    },
    ConnectionIntent {
        resource: ResourceId,
        connected_gateway_ids: HashSet<GatewayId>,
    },
    RefreshResources {
        connections: Vec<ReuseConnection>,
    },
    SendPacket(IpPacket<'static>),
    StopPeer(TId),
}

async fn sleep_until(deadline: Instant) -> Instant {
    tokio::time::sleep_until(deadline.into()).await;

    deadline
}
