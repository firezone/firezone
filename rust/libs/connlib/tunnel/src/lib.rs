//! Connlib tunnel implementation.
//!
//! This is both the wireguard and ICE implementation that should work in tandem.
//! [Tunnel] is the main entry-point for this crate.
//!
//! The sans-IO core (the [`DeviceState`] state machine and all supporting,
//! side-effect-free logic) lives in the [`tunnel_proto`] crate and is
//! re-exported from here so that downstream consumers see a single, unchanged API.

#![cfg_attr(test, allow(clippy::unwrap_used))]
#![cfg_attr(test, allow(clippy::print_stdout))]
#![cfg_attr(test, allow(clippy::print_stderr))]

use anyhow::{Context as _, ErrorExt as _, Result};
use connlib_model::PublicKey;
use eventloop_budget::Budget;
use futures::{FutureExt, future::BoxFuture};
use io::Io;
use packet_counts::{TunPacketCounts, UdpPacketCounts};
use prefetch::IteratorExt as _;
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use std::{
    collections::BTreeSet,
    future, mem,
    net::{IpAddr, SocketAddr},
    sync::Arc,
    task::{Context, Poll},
    time::{Duration, Instant, SystemTime},
};
use tun::Tun;
use tunnel_proto::unroutable_packet::RoutingError;

mod io;
mod packet_counts;
mod sockets;
mod utils;

pub use tunnel_proto::*;

pub use io::{CryptoWorkersStopped, TunChannelClosed};
pub use sockets::UdpSocketThreadStopped;
pub use utils::turn;

/// How many times we will at most loop before force-yielding from [`DeviceTunnel::poll_next_event`].
///
/// It is obviously system-dependent, how long it takes for the event loop to exhaust these iterations.
/// It has been measured that on GitHub's standard Linux runners, 3000 iterations is roughly 1s during an iperf run.
/// With 5000, we could not reproduce the force-yielding to be needed.
/// Thus, it is chosen as a safe, upper boundary that is not meant to be hit (and thus doesn't affect performance), yet acts as a safe guard, just in case.
const MAX_EVENTLOOP_ITERS: u32 = 5000;

pub type DeviceTunnel = Tunnel<DeviceState>;
/// The device tunnel, under the names the two binaries used to build it by.
pub type ClientTunnel = DeviceTunnel;
pub type GatewayTunnel = DeviceTunnel;

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

/// [`Tunnel`] glues together connlib's [`Io`] component and the (pure) state of a device.
///
/// Most of connlib's functionality is implemented as a pure state machine in [`DeviceState`].
/// The only job of [`Tunnel`] is to take input from the TUN [`Device`](crate::io::Device), [`Sockets`](crate::sockets::Sockets) or time and pass it to the state.
pub struct Tunnel<TRoleState> {
    /// The (pure) state, [`DeviceState`].
    role_state: TRoleState,

    /// The I/O component of connlib.
    ///
    /// Handles all side-effects.
    io: Io,

    packet_counter: opentelemetry::metrics::Counter<u64>,
    dropped_packets: opentelemetry::metrics::Counter<u64>,

    /// Set when the last poll handled IO whose effects only `handle_timeout` completes.
    ///
    /// Not every component advertises a deadline for that work, so the tunnel says so itself:
    /// [`Tunnel::next_timeout`] reports `now` and the alarm rings straight away.
    needs_timeout: bool,
}

impl<TRoleState> Tunnel<TRoleState> {
    pub fn state_mut(&mut self) -> &mut TRoleState {
        &mut self.role_state
    }

    pub fn set_tun(&mut self, tun: Box<dyn Tun>) {
        self.io.set_tun(tun);
    }

    pub fn rebind_dns(&mut self, sockets: Vec<SocketAddr>) -> Result<(), TunnelError> {
        self.io.rebind_dns(sockets)?;

        Ok(())
    }
}

impl DeviceTunnel {
    pub fn new(
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
        nameservers: BTreeSet<IpAddr>,
        records: BTreeSet<DnsResourceRecord>,
        is_internet_resource_active: bool,
        now: Instant,
    ) -> Self {
        Self {
            io: Io::new(tcp_socket_factory, udp_socket_factory.clone(), nameservers),
            role_state: DeviceState::new(
                rand::random(),
                records,
                is_internet_resource_active,
                now,
                SystemTime::now()
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .expect("Should be able to compute UNIX timestamp"),
            ),
            packet_counter: otel_instruments::network_packets(),
            dropped_packets: otel_instruments::network_packet_dropped(),
            needs_timeout: false,
        }
    }

    pub fn public_key(&self) -> PublicKey {
        self.role_state.public_key()
    }

    /// The instant by which the event loop must poll again.
    ///
    /// Asks the state once, so call this right before suspending rather than on every wake-up.
    pub fn next_timeout(&mut self, now: Instant) -> Option<Instant> {
        if mem::take(&mut self.needs_timeout) {
            return Some(now);
        }

        self.role_state.poll_timeout().map(|(deadline, _)| deadline)
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
        // The DNS servers on our tunnel addresses answer the peers we serve from the same resolvers.
        self.io.set_nameservers(resolvers.iter().copied().collect());

        resolvers
    }

    /// Shut down the tunnel.
    pub fn shut_down(mut self, now: Instant) -> BoxFuture<'static, Result<()>> {
        // Initiate shutdown.
        self.role_state.shut_down(now);

        // Drain all UDP packets that need to be sent.
        while let Some(trans) = self.role_state.poll_transmit() {
            self.io.send_network(trans);
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

    pub fn poll_next_event(
        &mut self,
        cx: &mut Context<'_>,
        now: Instant,
    ) -> Poll<Result<ClientEvent, TunnelError>> {
        let mut budget = Budget::new(cx.waker(), MAX_EVENTLOOP_ITERS, "device-tunnel");

        while let Some(mut tick) = budget.next() {
            let mut udp_received = UdpPacketCounts::receive(&self.packet_counter);
            let mut tun_received = TunPacketCounts::receive(&self.packet_counter);
            let mut tun_transmitted = TunPacketCounts::transmit(&self.packet_counter);

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

                return Poll::Ready(Ok(event));
            }

            // Drain all buffered IP packets.
            while let Some(packet) = self.role_state.poll_packets() {
                tun_transmitted.record(&packet);
                self.io.queue_tun(packet);
                tick.want_continue();
            }

            self.io.flush_tun_batch();

            // Drain all buffered transmits.
            while let Some(trans) = self.role_state.poll_transmit() {
                self.io.send_network(trans);
                tick.want_continue();
            }

            // Drain all scheduled DNS queries.
            while let Some(query) = self.role_state.poll_dns_queries() {
                self.io.send_dns_query(query, now);
                tick.want_continue();
            }

            // Process all IO sources that are ready.
            if let Poll::Ready(io::Input {
                dns_responses,
                tcp_dns_queries,
                udp_dns_queries,
                mut device,
                network,
                decrypted,
                mut error,
            }) = self.io.poll(cx)
            {
                for response in dns_responses {
                    // A query the DNS server on our tunnel addresses forwarded
                    // for a peer we serve is answered on that server; anything
                    // else is a recursive query of the state's own resolver.
                    if self.io.is_tun_dns_server(response.local) {
                        if let Err(e) = send_tun_dns_response(&mut self.io, response) {
                            error.push(e);
                        }
                    } else {
                        self.role_state.handle_dns_response(response, now);
                        self.needs_timeout = true;
                    }

                    tick.want_continue();
                }

                if let Some(packets) = device.as_mut().map(|packets| packets.drain()) {
                    let mut batch = self.io.start_encrypt_batch(packets.len());

                    for mut packet in packets.prefetching().inspect(|p| tun_received.record(p)) {
                        match self.role_state.handle_tun_input(&mut packet, now) {
                            Ok(Some(encapsulation)) => batch.encrypt(encapsulation, packet),
                            Ok(None) => {}
                            Err(e) => {
                                let routing_error = e
                                    .any_downcast_ref::<UnroutablePacket>()
                                    .map(|e| e.reason())
                                    .unwrap_or(RoutingError::Other);

                                self.dropped_packets.add(
                                    1,
                                    &[
                                        otel::attr::error_type(routing_error),
                                        otel::attr::network_io_direction_receive(),
                                    ],
                                );

                                error.push(e.context("Failed to handle packet from TUN device"));
                            }
                        }
                    }

                    // Packets encrypted inline would go out after this batch, despite their lower counters.
                    #[cfg(debug_assertions)]
                    assert_eq!(
                        self.role_state.num_buffered_transmits(),
                        0,
                        "No packets must be encrypted inline while a batch is encrypted off the main thread"
                    );

                    self.needs_timeout = true;

                    tick.want_continue();
                }

                if let Some(mut datagrams) = network {
                    let mut decrypts = self.io.start_decrypt_batch(datagrams.len());

                    for datagram in datagrams.drain() {
                        let mut datagram = decrypts.add(datagram);

                        for segment in datagram.segments() {
                            let packet = &datagram[segment];

                            udp_received.record(packet);

                            match self
                                .role_state
                                .handle_network_input(
                                    datagram.local(),
                                    datagram.from(),
                                    packet,
                                    now,
                                )
                                .with_context(|| FailedToHandleNetworkPacket {
                                    local: datagram.local(),
                                    from: datagram.from(),
                                }) {
                                Ok(Some(decapsulation)) => datagram.decrypt(segment, decapsulation),
                                Ok(None) => self.needs_timeout = true,
                                Err(e) => error.push(e),
                            };
                        }
                    }

                    tick.want_continue();
                }

                if let Some(mut decrypted) = decrypted {
                    for received in decrypted.drain().prefetching() {
                        let result = self.role_state.handle_peer_input(
                            received.local,
                            received.from,
                            received.packet,
                            now,
                        );

                        match result {
                            Ok(Some(packet)) => {
                                let packet = packet.with_ecn_from_transport(received.ecn);

                                tun_transmitted.record(&packet);
                                self.io.queue_tun(packet);
                            }
                            Ok(None) => self.needs_timeout = true,
                            Err(e) => error.push(e.context(FailedToHandleNetworkPacket {
                                local: received.local,
                                from: received.from,
                            })),
                        };
                    }

                    self.io.flush_tun_batch();

                    tick.want_continue();
                }

                for query in udp_dns_queries {
                    forward_tun_dns_query(
                        &mut self.io,
                        query.local,
                        query.remote,
                        query.message,
                        dns::Transport::Udp,
                        now,
                        &mut error,
                    );

                    tick.want_continue();
                }

                for query in tcp_dns_queries {
                    forward_tun_dns_query(
                        &mut self.io,
                        query.local,
                        query.remote,
                        query.message,
                        dns::Transport::Tcp,
                        now,
                        &mut error,
                    );

                    tick.want_continue();
                }

                if !error.is_empty() {
                    return Poll::Ready(Err(error));
                }
            }
        }

        Poll::Pending
    }
}

/// Forwards a query received on the DNS server on our tunnel addresses to the fastest nameserver.
///
/// That server answers the queries of peers we serve DNS resources to.
fn forward_tun_dns_query(
    io: &mut Io,
    local: SocketAddr,
    remote: SocketAddr,
    message: dns_types::Query,
    transport: dns::Transport,
    now: Instant,
    error: &mut TunnelError,
) {
    let Some(nameserver) = io.fastest_nameserver() else {
        tracing::warn!(query = ?message, "No nameserver available to handle {transport} DNS query");

        let servfail = dns_types::Response::servfail(&message);
        let result = match transport {
            dns::Transport::Udp => io.send_udp_dns_response(remote, local, servfail),
            dns::Transport::Tcp => io.send_tcp_dns_response(remote, local, servfail),
        };
        if let Err(e) = result {
            error.push(e);
        }

        return;
    };

    io.send_dns_query(
        dns::RecursiveQuery {
            server: dns::Upstream::Do53 {
                server: SocketAddr::new(nameserver, dns::DNS_PORT),
            },
            local,
            remote,
            message,
            transport,
        },
        now,
    );
}

/// Answers a query of the DNS server on our tunnel addresses.
fn send_tun_dns_response(io: &mut Io, response: dns::RecursiveResponse) -> std::io::Result<()> {
    let message = response.message.unwrap_or_else(|e| {
        tracing::debug!("DNS query failed: {e}");

        dns_types::Response::servfail(&response.query)
    });

    match response.transport {
        dns::Transport::Udp => io.send_udp_dns_response(response.remote, response.local, message),
        dns::Transport::Tcp => io.send_tcp_dns_response(response.remote, response.local, message),
    }
}

#[derive(Debug, thiserror::Error)]
#[error("Failed to handle packet from network (src {from} dst {local})")]
pub struct FailedToHandleNetworkPacket {
    local: SocketAddr,
    from: SocketAddr,
}
