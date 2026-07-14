//! Connlib tunnel implementation.
//!
//! This is both the wireguard and ICE implementation that should work in tandem.
//! [Tunnel] is the main entry-point for this crate.
//!
//! The sans-IO core (the [`ClientState`] / [`GatewayState`] state machines and all
//! supporting, side-effect-free logic) lives in the [`tunnel_proto`] crate and is
//! re-exported from here so that downstream consumers see a single, unchanged API.

#![cfg_attr(test, allow(clippy::unwrap_used))]
#![cfg_attr(test, allow(clippy::print_stdout))]
#![cfg_attr(test, allow(clippy::print_stderr))]

use anyhow::{Context as _, ErrorExt as _, Result};
use connlib_model::PublicKey;
use eventloop_budget::Budget;
use futures::{FutureExt, future::BoxFuture};
use gat_lending_iterator::LendingIterator;
use io::Io;
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use std::{
    collections::BTreeSet,
    future,
    net::{IpAddr, SocketAddr},
    sync::Arc,
    task::{Context, Poll, ready},
    time::{Duration, Instant, SystemTime},
};
use tun::Tun;
use tunnel_proto::unroutable_packet::RoutingError;

mod io;
mod sockets;
#[cfg(feature = "test-util")]
pub mod client {
    pub use tunnel_proto::{
        CidrResource, DNS_SENTINELS_V4, DNS_SENTINELS_V6, DnsResource, DynamicDevicePoolResource,
        IPV4_RESOURCES, IPV6_RESOURCES, InternetResource, Resource, StaticDevicePoolResource,
    };
}
#[cfg(feature = "test-util")]
pub mod filter_engine {
    pub use tunnel_proto::FilterEngine;
}
#[cfg(feature = "test-util")]
pub mod malicious_behaviour {
    pub use tunnel_proto::{MaliciousBehaviour, MaliciousBehaviourGuard as Guard};
}
mod utils;

pub use tunnel_proto::*;

pub use io::TunChannelClosed;
pub use sockets::UdpSocketThreadStopped;
pub use utils::turn;

/// How many times we will at most loop before force-yielding from [`ClientTunnel::poll_next_event`] & [`GatewayTunnel::poll_next_event`].
///
/// It is obviously system-dependent, how long it takes for the event loop to exhaust these iterations.
/// It has been measured that on GitHub's standard Linux runners, 3000 iterations is roughly 1s during an iperf run.
/// With 5000, we could not reproduce the force-yielding to be needed.
/// Thus, it is chosen as a safe, upper boundary that is not meant to be hit (and thus doesn't affect performance), yet acts as a safe guard, just in case.
const MAX_EVENTLOOP_ITERS: u32 = 5000;

pub type GatewayTunnel = Tunnel<GatewayState>;
pub type ClientTunnel = Tunnel<ClientState>;

/// [`Tunnel`] glues together connlib's [`Io`] component and the respective (pure) state of a client or gateway.
///
/// Most of connlib's functionality is implemented as a pure state machine in [`ClientState`] and [`GatewayState`].
/// The only job of [`Tunnel`] is to take input from the TUN [`Device`](crate::io::Device), [`Sockets`](crate::sockets::Sockets) or time and pass it to the respective state.
pub struct Tunnel<TRoleState> {
    /// (pure) state that differs per role, either [`ClientState`] or [`GatewayState`].
    role_state: TRoleState,

    /// The I/O component of connlib.
    ///
    /// Handles all side-effects.
    io: Io,

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
        now: Instant,
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
                now,
                SystemTime::now()
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .expect("Should be able to compute UNIX timestamp"),
            ),
            packet_counter: otel_instruments::network_packets(),
        }
    }

    pub fn public_key(&self) -> PublicKey {
        self.role_state.public_key()
    }

    pub fn reset(&mut self, reason: &str, now: Instant) {
        if self
            .role_state
            .poll_timeout()
            .is_some_and(|(timeout, _)| timeout <= now)
        {
            self.role_state.handle_timeout(now);
        }

        self.role_state.reset(now, reason);
        self.io.reset();
    }

    pub fn update_system_resolvers(&mut self, resolvers: Vec<IpAddr>) -> Vec<IpAddr> {
        let resolvers = self.role_state.update_system_resolvers(resolvers);
        self.io.update_system_resolvers(resolvers.clone()); // IO needs the system resolvers to bootstrap DoH upstream.

        resolvers
    }

    /// Shut down the Client tunnel.
    pub fn shut_down(mut self, now: Instant) -> BoxFuture<'static, Result<()>> {
        // Initiate shutdown.
        self.role_state.shut_down(now);

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

    pub fn poll_next_event(&mut self, cx: &mut Context<'_>, now: Instant) -> Poll<ClientEvent> {
        let mut budget = Budget::new(cx.waker(), MAX_EVENTLOOP_ITERS, "client-tunnel");

        while let Some(mut tick) = budget.next() {
            if self
                .role_state
                .poll_timeout()
                .is_some_and(|(timeout, _)| timeout <= now)
            {
                self.role_state.handle_timeout(now);
                tick.want_continue();
            }

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
                self.io.queue_tun(packet);
                tick.want_continue();
            }

            self.io.flush_tun_batch();

            // Drain all buffered transmits.
            while let Some(trans) = self.role_state.poll_transmit() {
                self.io
                    .send_network(trans.src, trans.dst, &trans.payload, trans.ecn);
                tick.want_continue();
            }

            // Drain all scheduled DNS queries.
            while let Some(query) = self.role_state.poll_dns_queries() {
                self.io.send_dns_query(query, now);
                tick.want_continue();
            }

            // Process all IO sources that are ready.
            if let Poll::Ready(io::Input {
                timeout,
                dns_response,
                tcp_dns_queries: _,
                udp_dns_queries: _,
                device,
                network,
                mut error,
            }) = self.io.poll(cx)
            {
                if let Some(response) = dns_response {
                    self.role_state.handle_dns_response(response, now);
                    self.io.schedule_timeout();

                    tick.want_continue();
                }

                if timeout {
                    self.role_state.handle_timeout(now);
                    tick.want_continue();
                }

                if let Some(mut packets) = device {
                    for packet in packets.drain() {
                        match self
                            .role_state
                            .handle_tun_input(packet, now, self.io.gso_queue_mut())
                            .context("Failed to handle packet from TUN device")
                        {
                            Ok(()) => {}
                            Err(e) => error.push(e),
                        }
                    }

                    self.io.schedule_timeout();

                    // Eagerly flush GSO queue.
                    if let Poll::Ready(Err(e)) = self.io.flush_gso_queue(cx) {
                        error.push(e);
                    }

                    tick.want_continue();
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

                        match self
                            .role_state
                            .handle_network_input(
                                received.local,
                                received.from,
                                received.packet,
                                now,
                            )
                            .with_context(|| FailedToHandleNetworkPacket {
                                local: received.local,
                                from: received.from,
                            }) {
                            Ok(Some(packet)) => self
                                .io
                                .queue_tun(packet.with_ecn_from_transport(received.ecn)),
                            Ok(None) => self.io.schedule_timeout(),
                            Err(e) => error.push(e),
                        };
                    }

                    self.io.flush_tun_batch();

                    tick.want_continue();
                }

                if !error.is_empty() {
                    return Poll::Ready(ClientEvent::Error(error));
                }
            }
        }

        // Reset timer for time-based wakeup before we suspend.
        if let Some((timeout, reason)) = self.role_state.poll_timeout() {
            self.io
                .reset_timeout_after(timeout.saturating_duration_since(now), reason);
        }

        Poll::Pending
    }
}

impl GatewayTunnel {
    pub fn new(
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
        nameservers: BTreeSet<IpAddr>,
        now: Instant,
    ) -> Self {
        Self {
            io: Io::new(tcp_socket_factory, udp_socket_factory.clone(), nameservers),
            role_state: GatewayState::new(
                rand::random(),
                now,
                SystemTime::now()
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .expect("Should be able to compute UNIX timestamp"),
            ),
            packet_counter: otel_instruments::network_packets(),
        }
    }

    pub fn public_key(&self) -> PublicKey {
        self.role_state.public_key()
    }

    /// Shut down the Gateway tunnel.
    pub fn shut_down(mut self, now: Instant) -> BoxFuture<'static, Result<()>> {
        // Initiate shutdown.
        self.role_state.shut_down(now);

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

    pub fn poll_next_event(&mut self, cx: &mut Context<'_>, now: Instant) -> Poll<GatewayEvent> {
        let mut budget = Budget::new(cx.waker(), MAX_EVENTLOOP_ITERS, "gateway-tunnel");

        while let Some(mut tick) = budget.next() {
            if self
                .role_state
                .poll_timeout()
                .is_some_and(|(timeout, _)| timeout <= now)
            {
                self.role_state.handle_timeout(now);
                tick.want_continue();
            }

            ready!(self.io.poll_has_sockets(cx)); // Suspend everything if we don't have any sockets.

            // Pass up existing events.
            if let Some(other) = self.role_state.poll_event() {
                return Poll::Ready(other);
            }

            // Drain all buffered transmits.
            while let Some(trans) = self.role_state.poll_transmit() {
                self.io
                    .send_network(trans.src, trans.dst, &trans.payload, trans.ecn);

                tick.want_continue();
            }

            // Process all IO sources that are ready.
            if let Poll::Ready(io::Input {
                timeout,
                dns_response,
                tcp_dns_queries,
                udp_dns_queries,
                device,
                network,
                mut error,
            }) = self.io.poll(cx)
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

                    tick.want_continue();
                }

                if timeout {
                    self.role_state.handle_timeout(now);
                    tick.want_continue();
                }

                if let Some(mut packets) = device {
                    for packet in packets.drain() {
                        match self
                            .role_state
                            .handle_tun_input(packet, now, self.io.gso_queue_mut())
                            .context("Failed to handle packet from TUN device")
                        {
                            Ok(()) => {}
                            Err(e) => {
                                let routing_error = e
                                    .any_downcast_ref::<UnroutablePacket>()
                                    .map(|e| e.reason())
                                    .unwrap_or(RoutingError::Other);

                                // TODO: Include more attributes here like IPv4/IPv6?
                                self.io.inc_dropped_packet(&[
                                    otel::attr::error_type(routing_error),
                                    otel::attr::network_io_direction_receive(),
                                ]);

                                error.push(e);
                            }
                        }
                    }

                    self.io.schedule_timeout();

                    // Eagerly flush GSO queue.
                    if let Poll::Ready(Err(e)) = self.io.flush_gso_queue(cx) {
                        error.push(e);
                    }

                    tick.want_continue();
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

                        match self
                            .role_state
                            .handle_network_input(
                                received.local,
                                received.from,
                                received.packet,
                                now,
                            )
                            .with_context(|| FailedToHandleNetworkPacket {
                                local: received.local,
                                from: received.from,
                            }) {
                            Ok(Some(packet)) => self
                                .io
                                .queue_tun(packet.with_ecn_from_transport(received.ecn)),
                            Ok(None) => self.io.schedule_timeout(),
                            Err(e) => error.push(e),
                        };
                    }

                    self.io.flush_tun_batch();

                    tick.want_continue();
                }

                for query in udp_dns_queries {
                    if let Some(nameserver) = self.io.fastest_nameserver() {
                        self.io.send_dns_query(
                            dns::RecursiveQuery {
                                server: dns::Upstream::Do53 {
                                    server: SocketAddr::new(nameserver, dns::DNS_PORT),
                                },
                                local: query.local,
                                remote: query.remote,
                                message: query.message,
                                transport: dns::Transport::Udp,
                            },
                            now,
                        );
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

                    tick.want_continue();
                }

                for query in tcp_dns_queries {
                    if let Some(nameserver) = self.io.fastest_nameserver() {
                        self.io.send_dns_query(
                            dns::RecursiveQuery {
                                server: dns::Upstream::Do53 {
                                    server: SocketAddr::new(nameserver, dns::DNS_PORT),
                                },
                                local: query.local,
                                remote: query.remote,
                                message: query.message,
                                transport: dns::Transport::Tcp,
                            },
                            now,
                        );
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

                    tick.want_continue();
                }

                if !error.is_empty() {
                    return Poll::Ready(GatewayEvent::Error(error));
                }
            }
        }

        // Reset timer for time-based wakeup before we suspend.
        if let Some((timeout, reason)) = self.role_state.poll_timeout() {
            self.io
                .reset_timeout_after(timeout.saturating_duration_since(now), reason);
        }

        Poll::Pending
    }
}

#[derive(Debug, thiserror::Error)]
#[error("Failed to handle packet from network (src {from} dst {local})")]
pub struct FailedToHandleNetworkPacket {
    local: SocketAddr,
    from: SocketAddr,
}
