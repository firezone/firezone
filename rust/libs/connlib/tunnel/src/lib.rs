//! Connlib tunnel implementation.
//!
//! This is both the wireguard and ICE implementation that should work in tandem.
//! [Tunnel] is the main entry-point for this crate.

#![cfg_attr(test, allow(clippy::unwrap_used))]
#![cfg_attr(test, allow(clippy::print_stdout))]
#![cfg_attr(test, allow(clippy::print_stderr))]

use anyhow::{Context as _, ErrorExt as _, Result};
use chrono::Utc;
use connlib_model::{ClientId, GatewayId, IceCandidate, PublicKey, ResourceId, ResourceView};
use dns_types::DomainName;
use futures::{FutureExt, future::BoxFuture};
use gat_lending_iterator::LendingIterator;
use io::{Buffers, Io};
use ip_network::{Ipv4Network, Ipv6Network};
use logging::DisplayBTreeSet;
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use std::{
    collections::BTreeSet,
    future, mem,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::Arc,
    task::{Context, Poll, ready},
    time::{Duration, Instant, SystemTime},
};
use tun::Tun;

mod client;
mod device_channel;
mod dns;
mod expiring_map;
mod gateway;
mod io;
pub mod messages;
mod otel;
mod p2p_control;
mod packet_kind;
mod peer_store;
#[cfg(all(test, feature = "proptest"))]
mod proptest;
mod sockets;
#[cfg(all(test, feature = "proptest"))]
#[allow(clippy::unwrap_in_result)]
mod tests;
mod unique_packet_buffer;
mod utils;

const REALM: &str = "firezone";

/// How many times we will at most loop before force-yielding from [`ClientTunnel::poll_next_event`] & [`GatewayTunnel::poll_next_event`].
///
/// It is obviously system-dependent, how long it takes for the event loop to exhaust these iterations.
/// It has been measured that on GitHub's standard Linux runners, 3000 iterations is roughly 1s during an iperf run.
/// With 5000, we could not reproduce the force-yielding to be needed.
/// Thus, it is chosen as a safe, upper boundary that is not meant to be hit (and thus doesn't affect performance), yet acts as a safe guard, just in case.
const MAX_EVENTLOOP_ITERS: u32 = 5000;

pub const IPV4_TUNNEL: Ipv4Network = match Ipv4Network::new(Ipv4Addr::new(100, 64, 0, 0), 11) {
    Ok(n) => n,
    Err(_) => unreachable!(),
};
pub const IPV6_TUNNEL: Ipv6Network =
    match Ipv6Network::new(Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 0), 107) {
        Ok(n) => n,
        Err(_) => unreachable!(),
    };

pub type GatewayTunnel = Tunnel<GatewayState>;
pub type ClientTunnel = Tunnel<ClientState>;

pub use client::ClientState;
pub use client::dns_config::DnsMapping;
pub use dns::DnsResourceRecord;
pub use gateway::{DnsResourceNatEntry, GatewayState, ResolveDnsRequest, UnroutablePacket};
pub use sockets::UdpSocketThreadStopped;
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

    packet_counter: opentelemetry::metrics::Counter<u64>,
}

impl<TRoleState> Tunnel<TRoleState> {
    pub fn state_mut(&mut self) -> &mut TRoleState {
        &mut self.role_state
    }

    pub fn set_tun(&mut self, tun: Box<dyn Tun>) {
        self.io.set_tun(tun);
    }

    pub fn rebind_dns(&mut self, sockets: Vec<SocketAddr>) -> Result<(), TunnelError> {
        self.io.rebind_dns(sockets)
    }
}

impl ClientTunnel {
    pub fn new(
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
        records: BTreeSet<DnsResourceRecord>,
        is_internet_resource_active: bool,
    ) -> Self {
        Self {
            io: Io::new(
                tcp_socket_factory,
                udp_socket_factory.clone(),
                BTreeSet::default(),
            ),
            role_state: ClientState::new(
                rand::random(),
                records,
                is_internet_resource_active,
                Instant::now(),
                SystemTime::now()
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .expect("Should be able to compute UNIX timestamp"),
            ),
            buffers: Buffers::default(),
            packet_counter: opentelemetry::global::meter("connlib")
                .u64_counter("system.network.packets")
                .with_description("The number of packets processed.")
                .build(),
        }
    }

    pub fn public_key(&self) -> PublicKey {
        self.role_state.public_key()
    }

    pub fn reset(&mut self, reason: &str) {
        self.role_state.reset(Instant::now(), reason);
        self.io.reset();
    }

    pub fn update_system_resolvers(&mut self, resolvers: Vec<IpAddr>) -> Vec<IpAddr> {
        let resolvers = self.role_state.update_system_resolvers(resolvers);
        self.io.update_system_resolvers(resolvers.clone()); // IO needs the system resolvers to bootstrap DoH upstream.

        resolvers
    }

    /// Shut down the Client tunnel.
    pub fn shut_down(mut self) -> BoxFuture<'static, Result<()>> {
        // Initiate shutdown.
        self.role_state.shut_down(Instant::now());

        // Drain all UDP packets that need to be sent.
        while let Some(trans) = self.role_state.poll_transmit() {
            self.io
                .send_network(trans.src, trans.dst, &trans.payload, trans.ecn);
        }

        // Return a future that "owns" our IO, polling it until all packets have been flushed.
        async move {
            tokio::time::timeout(
                Duration::from_secs(1),
                future::poll_fn(move |cx| self.io.flush(cx)),
            )
            .await
            .context("Failed to flush within 1s")??;

            Ok(())
        }
        .boxed()
    }

    pub fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<ClientEvent> {
        for _ in 0..MAX_EVENTLOOP_ITERS {
            let mut ready = false;

            ready!(self.io.poll_has_sockets(cx)); // Suspend everything if we don't have any sockets.

            // Pass up existing events.
            if let Some(event) = self.role_state.poll_event() {
                if let ClientEvent::TunInterfaceUpdated(config) = &event {
                    for url in &config.dns_by_sentinel.upstream_servers() {
                        let dns::Upstream::DoH { server } = url else {
                            continue;
                        };

                        self.io.bootstrap_doh_client(server.clone());
                    }
                }

                return Poll::Ready(event);
            }

            // Drain all buffered IP packets.
            while let Some(packet) = self.role_state.poll_packets() {
                self.io.send_tun(packet);
                ready = true;
            }

            // Drain all buffered transmits.
            while let Some(trans) = self.role_state.poll_transmit() {
                self.io
                    .send_network(trans.src, trans.dst, &trans.payload, trans.ecn);
                ready = true;
            }

            // Drain all scheduled DNS queries.
            while let Some(query) = self.role_state.poll_dns_queries() {
                self.io.send_dns_query(query);
                ready = true;
            }

            // Process all IO sources that are ready.
            if let Poll::Ready(io::Input {
                now,
                now_utc: _,
                timeout,
                dns_response,
                tcp_dns_queries: _,
                udp_dns_queries: _,
                device,
                network,
                error,
            }) = self.io.poll(cx, &mut self.buffers)
            {
                if let Some(response) = dns_response {
                    self.role_state.handle_dns_response(response, now);
                    self.role_state.handle_timeout(now);

                    ready = true;
                }

                if timeout {
                    self.role_state.handle_timeout(now);
                    ready = true;
                }

                if let Some(packets) = device {
                    for packet in packets {
                        match self.role_state.handle_tun_input(packet, now) {
                            Some(transmit) => {
                                self.io.send_network(
                                    transmit.src,
                                    transmit.dst,
                                    &transmit.payload,
                                    transmit.ecn,
                                );
                            }
                            None => {
                                self.role_state.handle_timeout(now);
                            }
                        }
                    }

                    ready = true;
                }

                if let Some(mut packets) = network {
                    while let Some(received) = packets.next() {
                        self.packet_counter.add(
                            1,
                            &[
                                otel::attr::network_protocol_name(received.packet),
                                otel::attr::network_transport_udp(),
                                otel::attr::network_io_direction_receive(),
                            ],
                        );

                        match self.role_state.handle_network_input(
                            received.local,
                            received.from,
                            received.packet,
                            now,
                        ) {
                            Some(packet) => self
                                .io
                                .send_tun(packet.with_ecn_from_transport(received.ecn)),
                            None => self.role_state.handle_timeout(now),
                        };
                    }

                    ready = true;
                }

                // Reset timer for time-based wakeup.
                if let Some((timeout, reason)) = self.role_state.poll_timeout() {
                    self.io.reset_timeout(timeout, reason);
                }

                if !error.is_empty() {
                    return Poll::Ready(ClientEvent::Error(error));
                }
            }

            if ready {
                continue;
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
        nameservers: BTreeSet<IpAddr>,
    ) -> Self {
        Self {
            io: Io::new(tcp_socket_factory, udp_socket_factory.clone(), nameservers),
            role_state: GatewayState::new(
                rand::random(),
                Instant::now(),
                SystemTime::now()
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .expect("Should be able to compute UNIX timestamp"),
            ),
            buffers: Buffers::default(),
            packet_counter: opentelemetry::global::meter("connlib")
                .u64_counter("system.network.packets")
                .with_description("The number of packets processed.")
                .build(),
        }
    }

    pub fn public_key(&self) -> PublicKey {
        self.role_state.public_key()
    }

    /// Shut down the Gateway tunnel.
    pub fn shut_down(mut self) -> BoxFuture<'static, Result<()>> {
        // Initiate shutdown.
        self.role_state.shut_down(Instant::now());

        // Drain all UDP packets that need to be sent.
        while let Some(trans) = self.role_state.poll_transmit() {
            self.io
                .send_network(trans.src, trans.dst, &trans.payload, trans.ecn);
        }

        // Return a future that "owns" our IO, polling it until all packets have been flushed.
        async move {
            tokio::time::timeout(
                Duration::from_secs(1),
                future::poll_fn(move |cx| self.io.flush(cx)),
            )
            .await
            .context("Failed to flush within 1s")??;

            Ok(())
        }
        .boxed()
    }

    pub fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<GatewayEvent> {
        for _ in 0..MAX_EVENTLOOP_ITERS {
            let mut ready = false;

            ready!(self.io.poll_has_sockets(cx)); // Suspend everything if we don't have any sockets.

            // Pass up existing events.
            if let Some(other) = self.role_state.poll_event() {
                return Poll::Ready(other);
            }

            // Drain all buffered transmits.
            while let Some(trans) = self.role_state.poll_transmit() {
                self.io
                    .send_network(trans.src, trans.dst, &trans.payload, trans.ecn);

                ready = true;
            }

            // Process all IO sources that are ready.
            if let Poll::Ready(io::Input {
                now,
                now_utc,
                timeout,
                dns_response,
                tcp_dns_queries,
                udp_dns_queries,
                device,
                network,
                mut error,
            }) = self.io.poll(cx, &mut self.buffers)
            {
                if let Some(response) = dns_response {
                    let message = response.message.unwrap_or_else(|e| {
                        tracing::debug!("DNS query failed: {e}");

                        dns_types::Response::servfail(&response.query)
                    });

                    match response.transport {
                        dns::Transport::Udp => {
                            if let Err(e) = self.io.send_udp_dns_response(
                                response.remote,
                                response.local,
                                message,
                            ) {
                                error.push(e);
                            }
                        }
                        dns::Transport::Tcp => {
                            if let Err(e) = self.io.send_tcp_dns_response(
                                response.remote,
                                response.local,
                                message,
                            ) {
                                error.push(e);
                            }
                        }
                    }

                    ready = true;
                }

                if timeout {
                    self.role_state.handle_timeout(now, now_utc);
                    ready = true;
                }

                if let Some(packets) = device {
                    for packet in packets {
                        match self.role_state.handle_tun_input(packet, now) {
                            Ok(Some(transmit)) => {
                                self.io.send_network(
                                    transmit.src,
                                    transmit.dst,
                                    &transmit.payload,
                                    transmit.ecn,
                                );
                            }
                            Ok(None) => {
                                self.role_state.handle_timeout(now, Utc::now());
                            }
                            Err(e) => {
                                let routing_error = e
                                    .any_downcast_ref::<gateway::UnroutablePacket>()
                                    .map(|e| e.reason())
                                    .unwrap_or(gateway::RoutingError::Other);

                                // TODO: Include more attributes here like IPv4/IPv6?
                                self.io.inc_dropped_packet(&[
                                    otel::attr::error_type(routing_error),
                                    otel::attr::network_io_direction_receive(),
                                ]);

                                error.push(e);
                            }
                        }
                    }

                    ready = true;
                }

                if let Some(mut packets) = network {
                    while let Some(received) = packets.next() {
                        self.packet_counter.add(
                            1,
                            &[
                                otel::attr::network_protocol_name(received.packet),
                                otel::attr::network_transport_udp(),
                                otel::attr::network_io_direction_receive(),
                            ],
                        );

                        match self.role_state.handle_network_input(
                            received.local,
                            received.from,
                            received.packet,
                            now,
                        ) {
                            Ok(Some(packet)) => self
                                .io
                                .send_tun(packet.with_ecn_from_transport(received.ecn)),
                            Ok(None) => self.role_state.handle_timeout(now, now_utc),
                            Err(e) => error.push(e),
                        };
                    }

                    ready = true;
                }

                for query in udp_dns_queries {
                    if let Some(nameserver) = self.io.fastest_nameserver() {
                        self.io.send_dns_query(dns::RecursiveQuery {
                            server: dns::Upstream::LocalDo53 {
                                server: SocketAddr::new(nameserver, dns::DNS_PORT),
                            },
                            local: query.local,
                            remote: query.remote,
                            message: query.message,
                            transport: dns::Transport::Udp,
                        });
                    } else {
                        tracing::warn!(query = ?query.message, "No nameserver available to handle UDP DNS query");

                        if let Err(e) = self.io.send_udp_dns_response(
                            query.remote,
                            query.local,
                            dns_types::Response::servfail(&query.message),
                        ) {
                            error.push(e);
                        }
                    }

                    ready = true;
                }

                for query in tcp_dns_queries {
                    if let Some(nameserver) = self.io.fastest_nameserver() {
                        self.io.send_dns_query(dns::RecursiveQuery {
                            server: dns::Upstream::LocalDo53 {
                                server: SocketAddr::new(nameserver, dns::DNS_PORT),
                            },
                            local: query.local,
                            remote: query.remote,
                            message: query.message,
                            transport: dns::Transport::Tcp,
                        });
                    } else {
                        tracing::warn!(query = ?query.message, "No nameserver available to handle TCP DNS query");

                        if let Err(e) = self.io.send_tcp_dns_response(
                            query.remote,
                            query.local,
                            dns_types::Response::servfail(&query.message),
                        ) {
                            error.push(e);
                        }
                    }

                    ready = true;
                }

                // Reset timer for time-based wakeup.
                if let Some((timeout, reason)) = self.role_state.poll_timeout() {
                    self.io.reset_timeout(timeout, reason);
                }

                if !error.is_empty() {
                    return Poll::Ready(GatewayEvent::Error(error));
                }
            }

            if ready {
                continue;
            }

            return Poll::Pending;
        }

        self.role_state.handle_timeout(Instant::now(), Utc::now()); // Ensure time advances, even if we are busy handling packets.
        cx.waker().wake_by_ref(); // Schedule another wake-up with the runtime to avoid getting suspended forever.
        Poll::Pending
    }
}

#[derive(Debug)]
pub enum ClientEvent {
    AddedIceCandidates {
        conn_id: GatewayId,
        candidates: BTreeSet<IceCandidate>,
    },
    RemovedIceCandidates {
        conn_id: GatewayId,
        candidates: BTreeSet<IceCandidate>,
    },
    ConnectionIntent {
        resource: ResourceId,
        preferred_gateways: Vec<GatewayId>,
    },
    /// The list of resources has changed and UI clients may have to be updated.
    ResourcesChanged {
        resources: Vec<ResourceView>,
    },
    DnsRecordsChanged {
        records: BTreeSet<DnsResourceRecord>,
    },
    TunInterfaceUpdated(TunConfig),
    Error(TunnelError),
}

#[derive(Clone, derive_more::Debug, PartialEq, Eq, Hash)]
pub struct TunConfig {
    pub ip: IpConfig,
    /// The map of DNS servers that connlib will use.
    ///
    /// - The "left" values are the connlib-assigned, proxy (or "sentinel") IPs.
    /// - The "right" values are the effective DNS servers.
    ///   If upstream DNS servers are configured (in the portal), we will use those.
    ///   Otherwise, we will use the DNS servers configured on the system.
    pub dns_by_sentinel: DnsMapping,
    pub search_domain: Option<DomainName>,

    #[debug("{}", DisplayBTreeSet(ipv4_routes))]
    pub ipv4_routes: BTreeSet<Ipv4Network>,
    #[debug("{}", DisplayBTreeSet(ipv6_routes))]
    pub ipv6_routes: BTreeSet<Ipv6Network>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct IpConfig {
    pub v4: Ipv4Addr,
    pub v6: Ipv6Addr,
}

impl IpConfig {
    pub fn is_ip(&self, ip: IpAddr) -> bool {
        match ip {
            IpAddr::V4(v4) => v4 == self.v4,
            IpAddr::V6(v6) => v6 == self.v6,
        }
    }
}

#[derive(Debug)]
pub enum GatewayEvent {
    AddedIceCandidates {
        conn_id: ClientId,
        candidates: BTreeSet<IceCandidate>,
    },
    RemovedIceCandidates {
        conn_id: ClientId,
        candidates: BTreeSet<IceCandidate>,
    },
    ResolveDns(ResolveDnsRequest),
    Error(TunnelError),
}

/// A collection of errors that occurred during a single event-loop tick.
///
/// This type purposely doesn't provide a `From` implementation for any errors.
/// We want compile-time safety inside the event-loop that we don't abort processing in the middle of a packet batch.
#[derive(Debug, Default)]
pub struct TunnelError {
    errors: Vec<anyhow::Error>,
}

impl TunnelError {
    pub fn single(e: impl Into<anyhow::Error>) -> Self {
        Self {
            errors: vec![e.into()],
        }
    }

    pub fn push(&mut self, e: impl Into<anyhow::Error>) {
        self.errors.push(e.into());
    }

    pub fn is_empty(&self) -> bool {
        self.errors.is_empty()
    }

    pub fn drain(&mut self) -> impl Iterator<Item = anyhow::Error> {
        mem::take(&mut self.errors).into_iter()
    }
}

impl Drop for TunnelError {
    fn drop(&mut self) {
        debug_assert!(
            self.errors.is_empty(),
            "should never drop `TunnelError` without consuming errors"
        );

        if !self.errors.is_empty() {
            tracing::error!("should never drop `TunnelError` without consuming errors")
        }
    }
}

#[derive(Debug, thiserror::Error)]
#[error("Not a client IP: {0}")]
pub(crate) struct NotClientIp(IpAddr);

#[derive(Debug, thiserror::Error)]
#[error("Traffic to/from this resource IP is not allowed: {0}")]
pub(crate) struct NotAllowedResource(IpAddr);

#[derive(Debug, thiserror::Error)]
#[error("Failed to decapsulate '{0}' packet")]
pub(crate) struct FailedToDecapsulate(packet_kind::Kind);

pub fn is_peer(dst: IpAddr) -> bool {
    match dst {
        IpAddr::V4(v4) => IPV4_TUNNEL.contains(v4),
        IpAddr::V6(v6) => IPV6_TUNNEL.contains(v6),
    }
}

#[cfg(test)]
mod unittests {
    use super::*;

    #[test]
    fn mldv2_routers_are_not_peers() {
        assert!(!is_peer("ff02::16".parse().unwrap()))
    }
}
