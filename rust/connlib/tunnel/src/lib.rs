//! Connlib tunnel implementation.
//!
//! This is both the wireguard and ICE implementation that should work in tandem.
//! [Tunnel] is the main entry-point for this crate.

use boringtun::x25519::StaticSecret;
use chrono::Utc;
use connlib_shared::{
    callbacks,
    messages::{ClientId, GatewayId, Relay, RelayId, ResourceId, ReuseConnection},
    Callbacks, Result,
};
use io::Io;
use std::{
    collections::{HashMap, HashSet},
    net::{IpAddr, SocketAddr},
    task::{Context, Poll},
    time::Instant,
};

pub use client::{ClientState, Request};
pub use gateway::GatewayState;
pub use sockets::Sockets;
use utils::turn;

mod client;
mod device_channel;
mod dns;
mod gateway;
mod io;
mod peer;
mod peer_store;
mod sockets;
mod utils;

#[cfg(all(test, feature = "proptest"))]
mod tests;

const MAX_UDP_SIZE: usize = (1 << 16) - 1;

const REALM: &str = "firezone";

#[cfg(target_os = "linux")]
const FIREZONE_MARK: u32 = 0xfd002021;

pub type GatewayTunnel<CB> = Tunnel<CB, GatewayState>;
pub type ClientTunnel<CB> = Tunnel<CB, ClientState>;

/// Tunnel is a wireguard state machine that uses webrtc's ICE channels instead of UDP sockets to communicate between peers.
pub struct Tunnel<CB: Callbacks, TRoleState> {
    pub callbacks: CB,

    /// State that differs per role, i.e. clients vs gateways.
    role_state: TRoleState,

    io: Io,

    write_buf: Box<[u8; MAX_UDP_SIZE]>,
    ip4_read_buf: Box<[u8; MAX_UDP_SIZE]>,
    ip6_read_buf: Box<[u8; MAX_UDP_SIZE]>,
    device_read_buf: Box<[u8; MAX_UDP_SIZE]>,
}

impl<CB> ClientTunnel<CB>
where
    CB: Callbacks + 'static,
{
    pub fn new(
        private_key: StaticSecret,
        sockets: Sockets,
        callbacks: CB,
    ) -> std::io::Result<Self> {
        Ok(Self {
            io: Io::new(sockets)?,
            callbacks,
            role_state: ClientState::new(private_key),
            write_buf: Box::new([0u8; MAX_UDP_SIZE]),
            ip4_read_buf: Box::new([0u8; MAX_UDP_SIZE]),
            ip6_read_buf: Box::new([0u8; MAX_UDP_SIZE]),
            device_read_buf: Box::new([0u8; MAX_UDP_SIZE]),
        })
    }

    pub fn reconnect(&mut self) -> std::io::Result<()> {
        self.role_state.reconnect(Instant::now());
        self.io.sockets_mut().rebind()?;

        Ok(())
    }

    pub fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Result<ClientEvent>> {
        loop {
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

            if let Some(dns_query) = self.role_state.poll_dns_queries() {
                self.io.perform_dns_query(dns_query);
                continue;
            }

            if let Some(timeout) = self.role_state.poll_timeout() {
                self.io.reset_timeout(timeout);
            }

            match self.io.poll(
                cx,
                self.ip4_read_buf.as_mut(),
                self.ip6_read_buf.as_mut(),
                self.device_read_buf.as_mut(),
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
                            self.write_buf.as_mut(),
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
    }
}

impl<CB> GatewayTunnel<CB>
where
    CB: Callbacks + 'static,
{
    pub fn new(
        private_key: StaticSecret,
        sockets: Sockets,
        callbacks: CB,
    ) -> std::io::Result<Self> {
        Ok(Self {
            io: Io::new(sockets)?,
            callbacks,
            role_state: GatewayState::new(private_key),
            write_buf: Box::new([0u8; MAX_UDP_SIZE]),
            ip4_read_buf: Box::new([0u8; MAX_UDP_SIZE]),
            ip6_read_buf: Box::new([0u8; MAX_UDP_SIZE]),
            device_read_buf: Box::new([0u8; MAX_UDP_SIZE]),
        })
    }

    pub fn update_relays(&mut self, to_remove: HashSet<RelayId>, to_add: Vec<Relay>) {
        self.role_state
            .update_relays(to_remove, turn(&to_add), Instant::now())
    }

    pub fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Result<GatewayEvent>> {
        loop {
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
                self.device_read_buf.as_mut(),
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
                            self.write_buf.as_mut(),
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
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ClientEvent {
    NewIceCandidate {
        conn_id: GatewayId,
        candidate: String,
    },
    InvalidatedIceCandidate {
        conn_id: GatewayId,
        candidate: String,
    },
    ConnectionIntent {
        resource: ResourceId,
        connected_gateway_ids: HashSet<GatewayId>,
    },
    RefreshResources {
        connections: Vec<ReuseConnection>,
    },
    /// The list of resources has changed and UI clients may have to be updated.
    ResourcesChanged {
        resources: Vec<callbacks::ResourceDescription>,
    },
    DnsServersChanged {
        /// The map of DNS servers that connlib will use, indexed by the proxy (or "sentinel") IP assigned by connlib.
        ///
        /// If upstream DNS servers are configured (in the portal), we will use those.
        /// Otherwise, we will use the DNS servers configured on the system.
        dns_by_sentinel: HashMap<IpAddr, SocketAddr>,
    },
}

#[derive(Debug, Clone)]
pub enum GatewayEvent {
    NewIceCandidate {
        conn_id: ClientId,
        candidate: String,
    },
    InvalidIceCandidate {
        conn_id: ClientId,
        candidate: String,
    },
}
