//! Connlib tunnel implementation.
//!
//! This is both the wireguard and ICE implementation that should work in tandem.
//! [Tunnel] is the main entry-point for this crate.

use boringtun::x25519::StaticSecret;
use connlib_shared::{
    messages::{ClientId, GatewayId, ResourceDescription, ReuseConnection},
    CallbackErrorFacade, Callbacks, Error, Result,
};
use device_channel::Device;
use futures_util::task::AtomicWaker;
use ip_network_table::IpNetworkTable;
use peer::{Peer, PeerStats};
use std::{
    collections::{HashMap, HashSet},
    net::IpAddr,
    sync::Arc,
    task::{ready, Context, Poll},
    time::Instant,
};

pub use client::ClientState;
pub use control_protocol::{gateway::ResolvedResourceDescriptionDns, Request};
pub use gateway::GatewayState;
use sockets::Sockets;

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

pub type GatewayTunnel<CB> = Tunnel<CB, GatewayState>;
pub type ClientTunnel<CB> = Tunnel<CB, ClientState>;

/// Tunnel is a wireguard state machine that uses webrtc's ICE channels instead of UDP sockets to communicate between peers.
pub struct Tunnel<CB: Callbacks, TRoleState> {
    callbacks: CallbackErrorFacade<CB>,

    /// State that differs per role, i.e. clients vs gateways.
    role_state: TRoleState,

    device: Option<Device>,
    no_device_waker: AtomicWaker,

    sockets: Sockets,

    write_buf: Box<[u8; MAX_UDP_SIZE]>,
    read_buf: Box<[u8; MAX_UDP_SIZE]>,
}

impl<CB> Tunnel<CB, ClientState>
where
    CB: Callbacks + 'static,
{
    pub fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Result<Event<GatewayId>>> {
        let Some(device) = self.device.as_mut() else {
            self.no_device_waker.register(cx.waker());
            return Poll::Pending;
        };

        if let Poll::Ready(event) = self.role_state.poll_next_event(cx) {
            return Poll::Ready(Ok(event));
        }

        ready!(self.sockets.poll_send_ready(cx))?; // Ensure socket is ready before we continue.

        if let Poll::Ready(received) = self.sockets.poll_recv_from(self.read_buf.as_mut(), cx) {
            for received in received {
                if let Some(packet) = self
                    .role_state
                    .decapsulate(received, self.write_buf.as_mut())
                {
                    device.write(packet)?;
                }
            }

            cx.waker().wake_by_ref();
        }

        match device.poll_read(self.read_buf.as_mut(), cx)? {
            Poll::Ready(Some(packet)) => {
                if let Some(transmit) = self.role_state.encapsulate(packet) {
                    self.sockets.send(&transmit);
                }

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

impl<CB> Tunnel<CB, GatewayState>
where
    CB: Callbacks + 'static,
{
    pub fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Result<Event<ClientId>>> {
        let Some(device) = self.device.as_mut() else {
            self.no_device_waker.register(cx.waker());
            return Poll::Pending;
        };

        let _ = self.role_state.poll(cx);

        ready!(self.sockets.poll_send_ready(cx))?; // Ensure socket is ready before we continue.

        if let Poll::Ready(received) = self.sockets.poll_recv_from(self.read_buf.as_mut(), cx) {
            for received in received {
                if let Some(packet) = self
                    .role_state
                    .decapsulate(received, self.write_buf.as_mut())
                {
                    device.write(packet)?;
                }
            }

            cx.waker().wake_by_ref();
        }

        match device.poll_read(self.read_buf.as_mut(), cx)? {
            Poll::Ready(Some(packet)) => {
                if let Some(transmit) = self.role_state.encapsulate(packet) {
                    self.sockets.send(&transmit);
                }

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

#[allow(dead_code)]
#[derive(Debug, Clone)]
pub struct TunnelStats<TId> {
    peer_connections: HashMap<TId, PeerStats<TId>>,
}

impl<CB> Tunnel<CB, ClientState>
where
    CB: Callbacks + 'static,
{
    #[tracing::instrument(level = "trace", skip(private_key, callbacks))]
    pub fn new(private_key: StaticSecret, callbacks: CB) -> Result<Self> {
        let callbacks = CallbackErrorFacade(callbacks);

        Ok(Self {
            device: Default::default(),
            sockets: new_sockets(&callbacks)?,
            callbacks,
            role_state: ClientState::new(private_key),
            no_device_waker: Default::default(),
            read_buf: Box::new([0u8; MAX_UDP_SIZE]),
            write_buf: Box::new([0u8; MAX_UDP_SIZE]),
        })
    }

    pub fn callbacks(&self) -> &CallbackErrorFacade<CB> {
        &self.callbacks
    }

    pub fn stats(&self) -> HashMap<GatewayId, PeerStats<GatewayId>> {
        self.role_state
            .peers_by_id
            .iter()
            .map(|(&id, p)| (id, p.stats()))
            .collect()
    }
}

impl<CB> Tunnel<CB, GatewayState>
where
    CB: Callbacks + 'static,
{
    #[tracing::instrument(level = "trace", skip(private_key, callbacks))]
    pub fn new(private_key: StaticSecret, callbacks: CB) -> Result<Self> {
        let callbacks = CallbackErrorFacade(callbacks);

        Ok(Self {
            device: Default::default(),
            sockets: new_sockets(&callbacks)?,
            callbacks,
            role_state: GatewayState::new(private_key),
            no_device_waker: Default::default(),
            read_buf: Box::new([0u8; MAX_UDP_SIZE]),
            write_buf: Box::new([0u8; MAX_UDP_SIZE]),
        })
    }

    pub fn callbacks(&self) -> &CallbackErrorFacade<CB> {
        &self.callbacks
    }

    pub fn stats(&self) -> HashMap<ClientId, PeerStats<ClientId>> {
        self.role_state
            .peers_by_id
            .iter()
            .map(|(&id, p)| (id, p.stats()))
            .collect()
    }
}

#[allow(unused_variables)]
fn new_sockets(callbacks: &impl Callbacks) -> Result<Sockets> {
    let sockets = Sockets::new()?;

    // TODO: Eventually, this should move into the `connlib-client-android` crate.
    #[cfg(target_os = "android")]
    {
        if let Some(ip4_socket) = sockets.ip4_socket_fd() {
            callbacks.protect_file_descriptor(ip4_socket)?;
        }
        if let Some(ip6_socket) = sockets.ip6_socket_fd() {
            callbacks.protect_file_descriptor(ip6_socket)?;
        }
    }

    Ok(sockets)
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
}

async fn sleep_until(deadline: Instant) -> Instant {
    tokio::time::sleep_until(deadline.into()).await;

    deadline
}
