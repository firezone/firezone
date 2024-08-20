//! Connlib tunnel implementation.
//!
//! This is both the wireguard and ICE implementation that should work in tandem.
//! [Tunnel] is the main entry-point for this crate.

use bimap::BiMap;
use boringtun::x25519::StaticSecret;
use chrono::Utc;
use connlib_shared::{
    callbacks,
    messages::{ClientId, GatewayId, Relay, RelayId, ResourceId, ReuseConnection},
    DomainName, PublicKey, DEFAULT_MTU,
};
use io::Io;
use ip_network::{Ipv4Network, Ipv6Network};
use rand::rngs::OsRng;
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use std::{
    collections::{BTreeMap, BTreeSet, HashSet},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::Arc,
    task::{Context, Poll},
    time::Instant,
};
use tun::Tun;
use utils::turn;

mod client;
mod device_channel;
mod dns;
mod gateway;
mod io;
mod peer;
mod peer_store;
#[cfg(all(test, feature = "proptest"))]
mod proptest;
mod sockets;
#[cfg(all(test, feature = "proptest"))]
mod tests;
mod utils;

const MAX_UDP_SIZE: usize = (1 << 16) - 1;
const REALM: &str = "firezone";

/// How many times we will at most loop before force-yielding from [`ClientTunnel::poll_next_event`] & [`GatewayTunnel::poll_next_event`].
///
/// It is obviously system-dependent, how long it takes for the event loop to exhaust these iterations.
/// It has been measured that on GitHub's standard Linux runners, 3000 iterations is roughly 1s during an iperf run.
/// With 5000, we could not reproduce the force-yielding to be needed.
/// Thus, it is chosen as a safe, upper boundary that is not meant to be hit (and thus doesn't affect performance), yet acts as a safe guard, just in case.
const MAX_EVENTLOOP_ITERS: u32 = 5000;

/// Wireguard has a 32-byte overhead (4b message type + 4b receiver idx + 8b packet counter + 16b AEAD tag)
const WG_OVERHEAD: usize = 32;
/// In order to do NAT46 without copying, we need 20 extra byte in the buffer (IPv6 packets are 20 byte bigger than IPv4).
const NAT46_OVERHEAD: usize = 20;

const BUF_SIZE: usize = DEFAULT_MTU + WG_OVERHEAD + NAT46_OVERHEAD;

pub type GatewayTunnel = Tunnel<GatewayState>;
pub type ClientTunnel = Tunnel<ClientState>;

pub use client::{ClientState, Request};
pub use gateway::{GatewayState, IPV4_PEERS, IPV6_PEERS};
pub use sockets::NoInterfaces;

/// [`Tunnel`] glues together connlib's [`Io`] component and the respective (pure) state of a client or gateway.
///
/// Most of connlib's functionality is implemented as a pure state machine in [`ClientState`] and [`GatewayState`].
/// The only job of [`Tunnel`] is to take input from the TUN [`Device`](crate::device_channel::Device), [`Sockets`](crate::sockets::Sockets) or time and pass it to the respective state.
pub struct Tunnel<TRoleState> {
    /// (pure) state that differs per role, either [`ClientState`] or [`GatewayState`].
    role_state: TRoleState,

    /// The I/O component of connlib.
    ///
    /// Handles all side-effects.
    io: Io,

    ip4_read_buf: Box<[u8; MAX_UDP_SIZE]>,
    ip6_read_buf: Box<[u8; MAX_UDP_SIZE]>,

    /// Buffer for processing a single IP packet.
    packet_buffer: Box<[u8; BUF_SIZE]>,
}

impl ClientTunnel {
    pub fn new(
        private_key: StaticSecret,
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
        known_hosts: BTreeMap<String, Vec<IpAddr>>,
    ) -> Result<Self, NoInterfaces> {
        Ok(Self {
            io: Io::new(tcp_socket_factory, udp_socket_factory)?,
            role_state: ClientState::new(private_key, known_hosts, rand::random()),
            packet_buffer: Box::new([0u8; BUF_SIZE]),
            ip4_read_buf: Box::new([0u8; MAX_UDP_SIZE]),
            ip6_read_buf: Box::new([0u8; MAX_UDP_SIZE]),
        })
    }

    pub fn reset(&mut self) -> Result<(), NoInterfaces> {
        self.role_state.reset();
        self.io.rebind_sockets()?;

        Ok(())
    }

    pub fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<std::io::Result<ClientEvent>> {
        for _ in 0..MAX_EVENTLOOP_ITERS {
            if let Some(e) = self.role_state.poll_event() {
                return Poll::Ready(Ok(e));
            }

            if let Some(packet) = self.role_state.poll_packets() {
                self.io.send_device(packet)?;
                continue;
            }

            if let Some(transmit) = self.role_state.poll_transmit() {
                self.io.send_network(transmit)?;
                continue;
            }

            if let Some(timeout) = self.role_state.poll_timeout() {
                self.io.reset_timeout(timeout);
            }

            match self.io.poll(
                cx,
                self.ip4_read_buf.as_mut(),
                self.ip6_read_buf.as_mut(),
                self.packet_buffer.as_mut(),
            )? {
                Poll::Ready(io::Input::Timeout(timeout)) => {
                    self.role_state.handle_timeout(timeout);
                    continue;
                }
                Poll::Ready(io::Input::Device(packet)) => {
                    let Some(transmit) = self.role_state.encapsulate(packet, Instant::now()) else {
                        continue;
                    };

                    self.io.send_network(transmit)?;

                    continue;
                }
                Poll::Ready(io::Input::Network(packets)) => {
                    for received in packets {
                        let Some(packet) = self.role_state.decapsulate(
                            received.local,
                            received.from,
                            received.packet,
                            std::time::Instant::now(),
                            self.packet_buffer.as_mut(),
                        ) else {
                            continue;
                        };

                        self.io.device_mut().write(packet)?;
                    }

                    continue;
                }
                Poll::Pending => {}
            }

            return Poll::Pending;
        }

        self.role_state.handle_timeout(Instant::now()); // Ensure time advances, even if we are busy handling packets.
        cx.waker().wake_by_ref(); // Schedule another wake-up with the runtime to avoid getting suspended forever.
        Poll::Pending
    }
}

impl GatewayTunnel {
    pub fn new(
        private_key: StaticSecret,
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
    ) -> Result<Self, NoInterfaces> {
        Ok(Self {
            io: Io::new(tcp_socket_factory, udp_socket_factory)?,
            role_state: GatewayState::new(private_key, rand::random()),
            packet_buffer: Box::new([0u8; BUF_SIZE]),
            ip4_read_buf: Box::new([0u8; MAX_UDP_SIZE]),
            ip6_read_buf: Box::new([0u8; MAX_UDP_SIZE]),
        })
    }

    pub fn update_relays(&mut self, to_remove: BTreeSet<RelayId>, to_add: Vec<Relay>) {
        self.role_state
            .update_relays(to_remove, turn(&to_add), Instant::now())
    }

    pub fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<std::io::Result<GatewayEvent>> {
        for _ in 0..MAX_EVENTLOOP_ITERS {
            if let Some(other) = self.role_state.poll_event() {
                return Poll::Ready(Ok(other));
            }

            if let Some(transmit) = self.role_state.poll_transmit() {
                self.io.send_network(transmit)?;
                continue;
            }

            if let Some(timeout) = self.role_state.poll_timeout() {
                self.io.reset_timeout(timeout);
            }

            match self.io.poll(
                cx,
                self.ip4_read_buf.as_mut(),
                self.ip6_read_buf.as_mut(),
                self.packet_buffer.as_mut(),
            )? {
                Poll::Ready(io::Input::Timeout(timeout)) => {
                    self.role_state.handle_timeout(timeout, Utc::now());
                    continue;
                }
                Poll::Ready(io::Input::Device(packet)) => {
                    let Some(transmit) = self
                        .role_state
                        .encapsulate(packet, std::time::Instant::now())
                    else {
                        continue;
                    };

                    self.io.send_network(transmit)?;

                    continue;
                }
                Poll::Ready(io::Input::Network(packets)) => {
                    for received in packets {
                        let Some(packet) = self.role_state.decapsulate(
                            received.local,
                            received.from,
                            received.packet,
                            std::time::Instant::now(),
                            self.packet_buffer.as_mut(),
                        ) else {
                            continue;
                        };

                        self.io.device_mut().write(packet)?;
                    }

                    continue;
                }
                Poll::Pending => {}
            }

            return Poll::Pending;
        }

        self.role_state.handle_timeout(Instant::now(), Utc::now()); // Ensure time advances, even if we are busy handling packets.
        cx.waker().wake_by_ref(); // Schedule another wake-up with the runtime to avoid getting suspended forever.
        Poll::Pending
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ClientEvent {
    AddedIceCandidates {
        conn_id: GatewayId,
        candidates: BTreeSet<String>,
    },
    RemovedIceCandidates {
        conn_id: GatewayId,
        candidates: BTreeSet<String>,
    },
    ConnectionIntent {
        resource: ResourceId,
        connected_gateway_ids: HashSet<GatewayId>,
    },
    SendProxyIps {
        connections: Vec<ReuseConnection>,
    },
    /// The list of resources has changed and UI clients may have to be updated.
    ResourcesChanged {
        resources: Vec<callbacks::ResourceDescription>,
    },
    // TODO: Make this more fine-granular.
    TunInterfaceUpdated {
        ip4: Ipv4Addr,
        ip6: Ipv6Addr,
        /// The map of DNS servers that connlib will use.
        ///
        /// - The "left" values are the connlib-assigned, proxy (or "sentinel") IPs.
        /// - The "right" values are the effective DNS servers.
        ///   If upstream DNS servers are configured (in the portal), we will use those.
        ///   Otherwise, we will use the DNS servers configured on the system.
        dns_by_sentinel: BiMap<IpAddr, SocketAddr>,
    },
    TunRoutesUpdated {
        ip4: Vec<Ipv4Network>,
        ip6: Vec<Ipv6Network>,
    },
}

#[derive(Debug, Clone)]
pub enum GatewayEvent {
    AddedIceCandidates {
        conn_id: ClientId,
        candidates: BTreeSet<String>,
    },
    RemovedIceCandidates {
        conn_id: ClientId,
        candidates: BTreeSet<String>,
    },
    RefreshDns {
        name: DomainName,
        conn_id: ClientId,
        resource_id: ResourceId,
    },
}

pub fn keypair() -> (StaticSecret, PublicKey) {
    let private_key = StaticSecret::random_from_rng(OsRng);
    let public_key = PublicKey::from(&private_key);

    (private_key, public_key)
}
