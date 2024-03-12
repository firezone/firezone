//! Connlib tunnel implementation.
//!
//! This is both the wireguard and ICE implementation that should work in tandem.
//! [Tunnel] is the main entry-point for this crate.

use boringtun::x25519::StaticSecret;
use connlib_shared::{
    messages::{ClientId, GatewayId, ResourceId, ReuseConnection},
    CallbackErrorFacade, Callbacks, Error, Result,
};
use snownet::{Node, Server};
use sockets::Received;
use std::{
    collections::HashSet,
    fmt,
    hash::Hash,
    task::{ready, Context, Poll},
    time::{Duration, Instant},
};

pub use client::ClientState;
pub use control_protocol::client::Request;
pub use gateway::{GatewayState, ResolvedResourceDescriptionDns};
use io::Io;
use ip_packet::IpPacket;

mod client;
mod io;
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
    node: Node<TRole, TId>,

    io: Io,
    stats_timer: tokio::time::Interval,

    write_buf: Box<[u8; MAX_UDP_SIZE]>,
    read_buf: Box<[u8; MAX_UDP_SIZE]>,
}

impl<CB> Tunnel<CB, ClientState, snownet::Client, GatewayId>
where
    CB: Callbacks + 'static,
{
    pub fn reconnect(&mut self) {
        self.connections_state.node.reconnect(Instant::now());
    }

    pub fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Result<Event<GatewayId>>> {
        match self.role_state.poll_next_event(cx) {
            Poll::Ready(Event::SendPacket(packet)) => {
                self.io.send_device(packet)?;
                cx.waker().wake_by_ref();
            }
            Poll::Ready(other) => return Poll::Ready(Ok(other)),
            _ => (),
        }

        match self.node.poll_event() {
            Some(snownet::Event::ConnectionFailed(id)) => {
                self.role_state.cleanup_connected_gateway(&id);
                cx.waker().wake_by_ref();
            }
            Some(snownet::Event::SignalIceCandidate {
                connection,
                candidate,
            }) => {
                return Poll::Ready(Ok(Event::SignalIceCandidate {
                    conn_id: connection,
                    candidate,
                }));
            }
            Some(_) => {
                cx.waker().wake_by_ref();
            }
            None => (),
        }

        if let Some(timeout) = self.node.poll_timeout() {
            self.io.reset_timeout(timeout);
        }

        ready!(self.io.sockets_ref().poll_send_ready(cx))?; // Ensure socket is ready before continuing

        match self.io.poll(cx, self.read_buf.as_mut())? {
            Poll::Ready(io::Input::Timeout(timeout)) => {
                self.node.handle_timeout(timeout);
                cx.waker().wake_by_ref();
            }
            Poll::Ready(io::Input::Device(packet)) => {
                let Some((peer_id, packet)) = self.role_state.encapsulate(packet, Instant::now())
                else {
                    cx.waker().wake_by_ref();
                    return Poll::Pending;
                };

                if let Some(transmit) =
                    self.node
                        .encapsulate(peer_id, packet.as_immutable().into(), Instant::now())?
                {
                    self.io.send_network(transmit)?;
                }

                cx.waker().wake_by_ref();
            }
            Poll::Ready(io::Input::Network(packets)) => {
                for received in packets {
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

                    let Some(peer) = self.role_state.peers.get_mut(&conn_id) else {
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

                    self.io.device_mut().write(packet.as_immutable())?;
                }
            }
            Poll::Pending => {}
        }

        if self.stats_timer.poll_tick(cx).is_ready() {
            let (node_stats, conn_stats) = self.node.stats();

            tracing::debug!(target: "connlib::stats", "{node_stats:?}");

            for (id, stats) in conn_stats {
                tracing::debug!(target: "connlib::stats", %id, "{stats:?}");
            }

            cx.waker().wake_by_ref();
        }

        Poll::Pending
    }
}

impl<CB> Tunnel<CB, GatewayState, Server, ClientId>
where
    CB: Callbacks + 'static,
{
    pub fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Result<Event<ClientId>>> {
        if let Poll::Ready(()) = self.role_state.poll(cx) {
            cx.waker().wake_by_ref();
        }

        match self.node.poll_event() {
            Some(snownet::Event::ConnectionFailed(id)) => {
                self.role_state.peers.remove(&id);
                cx.waker().wake_by_ref();
            }
            Some(snownet::Event::SignalIceCandidate {
                connection,
                candidate,
            }) => {
                return Poll::Ready(Ok(Event::SignalIceCandidate {
                    conn_id: connection,
                    candidate,
                }));
            }
            Some(_) => {
                cx.waker().wake_by_ref();
            }
            None => (),
        }

        if let Some(timeout) = self.node.poll_timeout() {
            self.io.reset_timeout(timeout);
        }

        ready!(self.io.sockets_ref().poll_send_ready(cx))?; // Ensure socket is ready before continuing

        match self.io.poll(cx, self.read_buf.as_mut())? {
            Poll::Ready(io::Input::Timeout(timeout)) => {
                self.node.handle_timeout(timeout);
                cx.waker().wake_by_ref();
            }
            Poll::Ready(io::Input::Device(packet)) => {
                let Some((peer_id, packet)) = self.role_state.encapsulate(packet) else {
                    cx.waker().wake_by_ref();
                    return Poll::Pending;
                };

                if let Some(transmit) =
                    self.node
                        .encapsulate(peer_id, packet.as_immutable().into(), Instant::now())?
                {
                    self.io.send_network(transmit)?;
                }

                cx.waker().wake_by_ref();
            }
            Poll::Ready(io::Input::Network(packets)) => {
                for received in packets {
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

                    let Some(peer) = self.role_state.peers.get_mut(&conn_id) else {
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

                    self.io.device_mut().write(packet.as_immutable())?;
                }
            }
            Poll::Pending => {}
        }

        if self.stats_timer.poll_tick(cx).is_ready() {
            let (node_stats, conn_stats) = self.node.stats();

            tracing::debug!(target: "connlib::stats", "{node_stats:?}");

            for (id, stats) in conn_stats {
                tracing::debug!(target: "connlib::stats", %id, "{stats:?}");
            }

            cx.waker().wake_by_ref();
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
        let io = Io::new()?;

        // TODO: Eventually, this should move into the `connlib-client-android` crate.
        #[cfg(target_os = "android")]
        {
            if let Some(ip4_socket) = io.sockets_ref().ip4_socket_fd() {
                callbacks.protect_file_descriptor(ip4_socket)?;
            }
            if let Some(ip6_socket) = io.sockets_ref().ip6_socket_fd() {
                callbacks.protect_file_descriptor(ip6_socket)?;
            }
        }

        Ok(Self {
            callbacks,
            role_state: Default::default(),
            node: Node::new(private_key),
            write_buf: Box::new([0u8; MAX_UDP_SIZE]),
            read_buf: Box::new([0u8; MAX_UDP_SIZE]),
            io,
            stats_timer: tokio::time::interval(Duration::from_secs(60)),
        })
    }

    pub fn callbacks(&self) -> &CallbackErrorFacade<CB> {
        &self.callbacks
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
}
