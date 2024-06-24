//! Connlib tunnel implementation.
//!
//! This is both the wireguard and ICE implementation that should work in tandem.
//! [Tunnel] is the main entry-point for this crate.

use boringtun::x25519::StaticSecret;
use chrono::Utc;
use connlib_shared::{
    callbacks,
    messages::{ClientId, GatewayId, Relay, RelayId, ResourceId, ReuseConnection},
    Callbacks, DomainName, Result,
};
use io::Io;
use std::{
    collections::HashSet,
    net::{IpAddr, SocketAddr},
    task::{Context, Poll},
    time::Instant,
};

use bimap::BiMap;
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
const MTU: usize = 1280;

const REALM: &str = "firezone";

pub type GatewayTunnel<CB> = Tunnel<CB, GatewayState>;
pub type ClientTunnel<CB> = Tunnel<CB, ClientState>;

/// [`Tunnel`] glues together connlib's [`Io`] component and the respective (pure) state of a client or gateway.
///
/// Most of connlib's functionality is implemented as a pure state machine in [`ClientState`] and [`GatewayState`].
/// The only job of [`Tunnel`] is to take input from the TUN [`Device`](crate::device_channel::Device), [`Sockets`] or time and pass it to the respective state.
pub struct Tunnel<CB: Callbacks, TRoleState> {
    pub callbacks: CB,

    /// (pure) state that differs per role, either [`ClientState`] or [`GatewayState`].
    role_state: TRoleState,

    /// The I/O component of connlib.
    ///
    /// Handles all side-effects.
    io: Io,

    ip4_read_buf: Box<[u8; MAX_UDP_SIZE]>,
    ip6_read_buf: Box<[u8; MAX_UDP_SIZE]>,

    // We need an extra 16 bytes on top of the MTU for write_buf since boringtun copies the extra AEAD tag before decrypting it
    write_buf: Box<[u8; MTU + 16 + 20]>,
    // We have 20 extra bytes to be able to convert between ipv4 and ipv6
    device_read_buf: Box<[u8; MTU + 20]>,
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
            write_buf: Box::new([0u8; MTU + 16 + 20]),
            ip4_read_buf: Box::new([0u8; MAX_UDP_SIZE]),
            ip6_read_buf: Box::new([0u8; MAX_UDP_SIZE]),
            device_read_buf: Box::new([0u8; MTU + 20]),
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
                if let Err(e) = self.io.perform_dns_query(dns_query.clone()) {
                    self.role_state.on_dns_result(dns_query, Err(e))
                }
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
                Poll::Ready(io::Input::DnsResponse(query, response)) => {
                    self.role_state.on_dns_result(query, Ok(response));
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
            write_buf: Box::new([0u8; MTU + 20 + 16]),
            ip4_read_buf: Box::new([0u8; MAX_UDP_SIZE]),
            ip6_read_buf: Box::new([0u8; MAX_UDP_SIZE]),
            device_read_buf: Box::new([0u8; MTU + 20]),
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
                Poll::Ready(io::Input::DnsResponse(_, _)) => {
                    unreachable!("Gateway does not (yet) resolve DNS queries via `Io`")
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
    SendProxyIps {
        connections: Vec<ReuseConnection>,
    },
    /// The list of resources has changed and UI clients may have to be updated.
    ResourcesChanged {
        resources: Vec<callbacks::ResourceDescription>,
    },
    DnsServersChanged {
        /// The map of DNS servers that connlib will use.
        ///
        /// - The "left" values are the connlib-assigned, proxy (or "sentinel") IPs.
        /// - The "right" values are the effective DNS servers.
        ///   If upstream DNS servers are configured (in the portal), we will use those.
        ///   Otherwise, we will use the DNS servers configured on the system.
        dns_by_sentinel: BiMap<IpAddr, SocketAddr>,
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
    RefreshDns {
        name: DomainName,
        conn_id: ClientId,
        resource_id: ResourceId,
    },
}
