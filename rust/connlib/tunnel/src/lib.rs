//! Connlib tunnel implementation.
//!
//! This is both the wireguard and ICE implementation that should work in tandem.
//! [Tunnel] is the main entry-point for this crate.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use bimap::BiMap;
use chrono::Utc;
use connlib_model::{ClientId, DomainName, GatewayId, PublicKey, ResourceId, ResourceView};
use gat_lending_iterator::LendingIterator;
use io::{Buffers, Io};
use ip_network::{Ipv4Network, Ipv6Network};
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use std::{
    collections::BTreeSet,
    fmt,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::Arc,
    task::{ready, Context, Poll},
    time::Instant,
};
use tun::Tun;

mod client;
mod device_channel;
mod dns;
mod gateway;
mod io;
pub mod messages;
mod p2p_control;
mod peer;
mod peer_store;
#[cfg(all(test, feature = "proptest"))]
mod proptest;
mod sockets;
#[cfg(all(test, feature = "proptest"))]
#[allow(clippy::unwrap_in_result)]
mod tests;
mod utils;

const REALM: &str = "firezone";

/// How many times we will at most loop before force-yielding from [`ClientTunnel::poll_next_event`] & [`GatewayTunnel::poll_next_event`].
///
/// It is obviously system-dependent, how long it takes for the event loop to exhaust these iterations.
/// It has been measured that on GitHub's standard Linux runners, 3000 iterations is roughly 1s during an iperf run.
/// With 5000, we could not reproduce the force-yielding to be needed.
/// Thus, it is chosen as a safe, upper boundary that is not meant to be hit (and thus doesn't affect performance), yet acts as a safe guard, just in case.
const MAX_EVENTLOOP_ITERS: u32 = 5000;

pub type GatewayTunnel = Tunnel<GatewayState>;
pub type ClientTunnel = Tunnel<ClientState>;

pub use client::ClientState;
pub use gateway::{DnsResourceNatEntry, GatewayState, ResolveDnsRequest, IPV4_PEERS, IPV6_PEERS};
pub use utils::turn;

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
    buffers: Buffers,
}

impl<TRoleState> Tunnel<TRoleState> {
    pub fn state_mut(&mut self) -> &mut TRoleState {
        &mut self.role_state
    }

    pub fn set_tun(&mut self, tun: Box<dyn Tun>) {
        self.io.set_tun(tun);
    }
}

impl ClientTunnel {
    pub fn new(
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
    ) -> Self {
        Self {
            io: Io::new(tcp_socket_factory, udp_socket_factory),
            role_state: ClientState::new(rand::random(), Instant::now()),
            buffers: Buffers::default(),
        }
    }

    pub fn public_key(&self) -> PublicKey {
        self.role_state.public_key()
    }

    pub fn reset(&mut self) {
        self.role_state.reset(Instant::now());
        self.io.reset();
    }

    pub fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<std::io::Result<ClientEvent>> {
        for _ in 0..MAX_EVENTLOOP_ITERS {
            ready!(self.io.poll_has_sockets(cx)); // Suspend everything if we don't have any sockets.

            if let Some(e) = self.role_state.poll_event() {
                return Poll::Ready(Ok(e));
            }

            if let Some(packet) = self.role_state.poll_packets() {
                self.io.send_tun(packet);
                continue;
            }

            if let Some(trans) = self.role_state.poll_transmit() {
                self.io.send_network(trans.src, trans.dst, &trans.payload);
                continue;
            }

            if let Some(query) = self.role_state.poll_dns_queries() {
                self.io.send_dns_query(query);
                continue;
            }

            if let Some(timeout) = self.role_state.poll_timeout() {
                self.io.reset_timeout(timeout);
            }

            match self.io.poll(cx, &mut self.buffers)? {
                Poll::Ready(io::Input::Timeout(timeout)) => {
                    self.role_state.handle_timeout(timeout);
                    continue;
                }
                Poll::Ready(io::Input::Device(packets)) => {
                    let now = Instant::now();

                    for packet in packets {
                        let Some(packet) = self.role_state.handle_tun_input(packet, now) else {
                            self.role_state.handle_timeout(now);
                            continue;
                        };

                        self.io
                            .send_network(packet.src(), packet.dst(), packet.payload());
                    }

                    continue;
                }
                Poll::Ready(io::Input::Network(mut packets)) => {
                    let now = Instant::now();

                    while let Some(received) = packets.next() {
                        let Some(packet) = self.role_state.handle_network_input(
                            received.local,
                            received.from,
                            received.packet,
                            now,
                        ) else {
                            self.role_state.handle_timeout(now);
                            continue;
                        };

                        self.io.send_tun(packet);
                    }

                    continue;
                }
                Poll::Ready(io::Input::DnsResponse(packet)) => {
                    self.role_state.handle_dns_response(packet);
                    self.role_state.handle_timeout(Instant::now());
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
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
    ) -> Self {
        Self {
            io: Io::new(tcp_socket_factory, udp_socket_factory),
            role_state: GatewayState::new(rand::random(), Instant::now()),
            buffers: Buffers::default(),
        }
    }

    pub fn public_key(&self) -> PublicKey {
        self.role_state.public_key()
    }

    pub fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<std::io::Result<GatewayEvent>> {
        for _ in 0..MAX_EVENTLOOP_ITERS {
            ready!(self.io.poll_has_sockets(cx)); // Suspend everything if we don't have any sockets.

            if let Some(other) = self.role_state.poll_event() {
                return Poll::Ready(Ok(other));
            }

            if let Some(trans) = self.role_state.poll_transmit() {
                self.io.send_network(trans.src, trans.dst, &trans.payload);
                continue;
            }

            if let Some(timeout) = self.role_state.poll_timeout() {
                self.io.reset_timeout(timeout);
            }

            match self.io.poll(cx, &mut self.buffers)? {
                Poll::Ready(io::Input::DnsResponse(_)) => {
                    unreachable!("Gateway doesn't use user-space DNS resolution")
                }
                Poll::Ready(io::Input::Timeout(timeout)) => {
                    self.role_state.handle_timeout(timeout, Utc::now());
                    continue;
                }
                Poll::Ready(io::Input::Device(packets)) => {
                    let now = Instant::now();

                    for packet in packets {
                        let Some(packet) = self
                            .role_state
                            .handle_tun_input(packet, now)
                            .map_err(std::io::Error::other)?
                        else {
                            self.role_state.handle_timeout(now, Utc::now());
                            continue;
                        };

                        self.io
                            .send_network(packet.src(), packet.dst(), packet.payload());
                    }

                    continue;
                }
                Poll::Ready(io::Input::Network(mut packets)) => {
                    let now = Instant::now();
                    let utc_now = Utc::now();

                    while let Some(received) = packets.next() {
                        let Some(packet) = self
                            .role_state
                            .handle_network_input(
                                received.local,
                                received.from,
                                received.packet,
                                now,
                            )
                            .map_err(std::io::Error::other)?
                        else {
                            self.role_state.handle_timeout(now, utc_now);
                            continue;
                        };

                        self.io.send_tun(packet);
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

#[derive(Clone, Debug)]
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
        connected_gateway_ids: BTreeSet<GatewayId>,
    },
    /// The list of resources has changed and UI clients may have to be updated.
    ResourcesChanged {
        resources: Vec<ResourceView>,
    },
    TunInterfaceUpdated(TunConfig),
}

#[derive(Clone, derive_more::Debug, PartialEq, Eq)]
pub struct TunConfig {
    pub ip4: Ipv4Addr,
    pub ip6: Ipv6Addr,
    /// The map of DNS servers that connlib will use.
    ///
    /// - The "left" values are the connlib-assigned, proxy (or "sentinel") IPs.
    /// - The "right" values are the effective DNS servers.
    ///   If upstream DNS servers are configured (in the portal), we will use those.
    ///   Otherwise, we will use the DNS servers configured on the system.
    pub dns_by_sentinel: BiMap<IpAddr, SocketAddr>,

    #[debug("{}", DisplaySet(ipv4_routes))]
    pub ipv4_routes: BTreeSet<Ipv4Network>,
    #[debug("{}", DisplaySet(ipv6_routes))]
    pub ipv6_routes: BTreeSet<Ipv6Network>,
}

#[derive(Debug)]
pub enum GatewayEvent {
    AddedIceCandidates {
        conn_id: ClientId,
        candidates: BTreeSet<String>,
    },
    RemovedIceCandidates {
        conn_id: ClientId,
        candidates: BTreeSet<String>,
    },
    ResolveDns(ResolveDnsRequest),
}

/// Adapter-struct to [`fmt::Display`] a [`BTreeSet`].
#[expect(dead_code, reason = "It is used in the `Debug` impl of `TunConfig`")]
struct DisplaySet<'a, T>(&'a BTreeSet<T>);

impl<T> fmt::Display for DisplaySet<'_, T>
where
    T: fmt::Display,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut list = f.debug_list();

        for entry in self.0 {
            list.entry(&format_args!("{entry}"));
        }

        list.finish()
    }
}
