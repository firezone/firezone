//! Connlib tunnel implementation.
//!
//! This is both the wireguard and ICE implementation that should work in tandem.
//! [Tunnel] is the main entry-point for this crate.
//!
//! The sans-IO core (the [`DeviceState`] state machine and all supporting,
//! side-effect-free logic) lives in the [`tunnel_proto`] crate and is
//! re-exported from here so that downstream consumers see a single API.

#![cfg_attr(test, allow(clippy::unwrap_used))]
#![cfg_attr(test, allow(clippy::print_stdout))]
#![cfg_attr(test, allow(clippy::print_stderr))]

use anyhow::{Context as _, Result};
use connlib_model::PublicKey;
use eventloop_budget::Budget;
use futures::{FutureExt, future::BoxFuture};
use io::{CryptoWorkers, Io};
use ip_packet::IpPacket;
use packet_counts::{DroppedTunPackets, TunPacketCounts, UdpPacketCounts};
use prefetch::IteratorExt as _;
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use sockets::Sockets;
use std::{
    collections::BTreeSet,
    future, mem,
    net::{IpAddr, SocketAddr},
    sync::Arc,
    task::{Context, Poll},
    time::{Duration, Instant, SystemTime},
};
use tun::Tun;

mod io;
mod packet_counts;
mod resolver;
mod sockets;
mod utils;

pub use tunnel_proto::*;

pub use io::TunChannelClosed;
pub use resolver::{ResolverControl, ResolverQuery, ResolverTaskEnds};
pub use sockets::{SocketThreadEnds, UdpSocketThreadStopped};
pub use utils::turn;

/// How many times we will at most loop before force-yielding from [`Tunnel::poll_next_event`].
///
/// It is obviously system-dependent, how long it takes for the event loop to exhaust these iterations.
/// It has been measured that on GitHub's standard Linux runners, 3000 iterations is roughly 1s during an iperf run.
/// With 5000, we could not reproduce the force-yielding to be needed.
/// Thus, it is chosen as a safe, upper boundary that is not meant to be hit (and thus doesn't affect performance), yet acts as a safe guard, just in case.
const MAX_EVENTLOOP_ITERS: u32 = 5000;

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
/// The only job of [`Tunnel`] is to take input from the TUN [`Device`](crate::io::Device), [`Sockets`] or time and pass it to the state.
pub struct Tunnel {
    /// The (pure) state of the device.
    role_state: DeviceState,

    /// The I/O component of connlib.
    ///
    /// Handles all side-effects.
    io: Io,

    packet_counter: opentelemetry::metrics::Counter<u64>,
    dropped_tun_packets: DroppedTunPackets,

    /// Set when the last poll handled IO whose effects only `handle_timeout` completes.
    ///
    /// Not every component advertises a deadline for that work, so the tunnel says so itself:
    /// [`Tunnel::next_timeout`] reports `now` and the alarm rings straight away.
    needs_timeout: bool,
}

impl Tunnel {
    /// Creates a tunnel around `role_state` that does all its work on the calling thread: the
    /// crypto jobs as they are submitted, the TUN device's, the IPv4 and IPv6 sockets' and the
    /// recursive DNS resolver's through the returned [`FakeTunnelEnds`].
    ///
    /// Nothing else can bind a socket.
    pub fn fake(role_state: DeviceState) -> (Self, FakeTunnelEnds) {
        let (sockets, socket_v4, socket_v6) = Sockets::fake();
        let (tun, tun_inbound, tun_outbound) = tun::fake(tun::CHANNEL_CAPACITY);
        let (resolver, dns) = resolver::channels();
        let tcp: Arc<dyn SocketFactory<TcpSocket>> =
            Arc::new(|_| Err(std::io::ErrorKind::Unsupported.into()));
        let udp: Arc<dyn SocketFactory<UdpSocket>> =
            Arc::new(|_| Err(std::io::ErrorKind::Unsupported.into()));
        let mut tunnel = Self {
            role_state,
            io: Io::new(
                sockets,
                CryptoWorkers::with_num_workers(0),
                resolver,
                tcp,
                udp,
            ),
            packet_counter: otel_instruments::network_packets(),
            dropped_tun_packets: DroppedTunPackets::new(),
            needs_timeout: false,
        };

        tunnel.set_tun(tun);

        let ends = FakeTunnelEnds {
            socket_v4,
            socket_v6,
            dns,
            tun_inbound,
            tun_outbound,
        };

        (tunnel, ends)
    }

    pub fn state(&self) -> &DeviceState {
        &self.role_state
    }

    pub fn state_mut(&mut self) -> &mut DeviceState {
        &mut self.role_state
    }

    pub fn into_state(self) -> DeviceState {
        self.role_state
    }

    pub fn set_tun(&mut self, tun: Box<dyn Tun>) {
        self.io.set_tun(tun);
    }

    pub fn rebind_dns(&mut self, sockets: Vec<SocketAddr>) -> Result<(), TunnelError> {
        self.io.rebind_dns(sockets)?;

        Ok(())
    }
}

impl Tunnel {
    /// The instant by which the event loop must poll again.
    ///
    /// Asks the state once, so call this right before suspending rather than on every wake-up.
    pub fn next_timeout(&mut self, now: Instant) -> Option<Instant> {
        if mem::take(&mut self.needs_timeout) {
            return Some(now);
        }

        self.role_state.poll_timeout()
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.role_state.handle_timeout(now);
    }
}

impl Tunnel {
    /// Creates the tunnel of a device.
    ///
    /// `nameservers` resolve the DNS queries of the peers the device serves until
    /// [`Tunnel::update_system_resolvers`] replaces them.
    pub fn new(
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
        listen_port: u16,
        records: BTreeSet<DnsResourceRecord>,
        is_internet_resource_active: bool,
        nameservers: BTreeSet<IpAddr>,
        now: Instant,
    ) -> std::io::Result<Self> {
        Ok(Self {
            io: Io::new(
                Sockets::new(udp_socket_factory.clone(), listen_port),
                CryptoWorkers::default(),
                resolver::spawn(
                    tcp_socket_factory.clone(),
                    udp_socket_factory.clone(),
                    nameservers,
                )?,
                tcp_socket_factory,
                udp_socket_factory,
            ),
            role_state: DeviceState::new(
                rand::random(),
                records,
                is_internet_resource_active,
                now,
                SystemTime::now()
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .map_err(std::io::Error::other)?,
            ),
            packet_counter: otel_instruments::network_packets(),
            dropped_tun_packets: DroppedTunPackets::new(),
            needs_timeout: false,
        })
    }

    pub fn public_key(&self) -> PublicKey {
        self.role_state.public_key()
    }

    pub fn reset(&mut self, reason: &str, now: Instant) {
        if self
            .role_state
            .poll_timeout()
            .is_some_and(|timeout| timeout <= now)
        {
            self.role_state.handle_timeout(now);
        }

        self.role_state.reset(now, reason);
        self.io.reset();
    }

    /// Advertises the given local IPs as additional host candidates on our UDP port.
    pub fn set_additional_host_candidates(&mut self, ips: Vec<IpAddr>, now: Instant) {
        self.role_state
            .set_additional_host_candidates(listen_sockets(ips, self.io.listen_port()), now);
    }

    /// Drops every datagram sent directly to a peer while `enabled`, forcing connections through a relay.
    /// Forwards the traffic of the resources this device serves through host sockets.
    ///
    /// For platforms whose kernel cannot route and masquerade that traffic itself.
    pub fn enable_userspace_forwarding(&mut self, now: Instant) {
        self.io.enable_userspace_forwarding(now);
    }

    pub fn set_force_relayed_connections(&self, enabled: bool) {
        self.io.set_force_relayed_connections(enabled);
    }

    pub fn update_system_resolvers(&mut self, resolvers: Vec<IpAddr>) -> Vec<IpAddr> {
        let resolvers = self.role_state.update_system_resolvers(resolvers);
        self.io
            .send_resolver_control(ResolverControl::SystemResolvers(resolvers.clone()));

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
    ) -> Poll<Result<DeviceEvent, TunnelError>> {
        let mut budget = Budget::new(cx.waker(), MAX_EVENTLOOP_ITERS, "tunnel");

        while let Some(mut tick) = budget.next() {
            let mut udp_received = UdpPacketCounts::receive(&self.packet_counter);
            let mut tun_received = TunPacketCounts::receive(&self.packet_counter);
            let mut tun_transmitted = TunPacketCounts::transmit(&self.packet_counter);

            // Pass up existing events.
            if let Some(event) = self.role_state.poll_event() {
                if let DeviceEvent::TunInterfaceUpdated(config) = &event {
                    self.io.send_resolver_control(ResolverControl::Upstreams(
                        config.dns_by_sentinel.upstream_servers(),
                    ));
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
                self.io.send_dns_query(ResolverQuery::new(query, now));
                tick.want_continue();
            }

            // Process all IO sources that are ready.
            if let Poll::Ready(io::Input {
                dns_responses,
                dns_queries,
                mut device,
                forwarded,
                network,
                decrypted,
                mut error,
            }) = self.io.poll(cx)
            {
                for response in dns_responses {
                    if is_site_dns_response(&response) {
                        if let Err(e) = send_site_dns_response(&mut self.io, response) {
                            error.push(e);
                        }
                    } else {
                        self.role_state.handle_dns_response(response, now);
                        self.needs_timeout = true;
                    }

                    tick.want_continue();
                }

                if let Some(packets) = device.as_mut().map(|packets| packets.drain()) {
                    encapsulate_tun_packets(
                        &mut self.role_state,
                        &mut self.io.new_encrypt_jobs(),
                        &self.dropped_tun_packets,
                        packets.prefetching().inspect(|p| tun_received.record(p)),
                        &mut error,
                        now,
                    );

                    self.needs_timeout = true;

                    tick.want_continue();
                }

                // The forwarder's replies to the peers we serve take the same way as replies the
                // kernel routes into the TUN device.
                if !forwarded.is_empty() {
                    encapsulate_tun_packets(
                        &mut self.role_state,
                        &mut self.io.new_encrypt_jobs(),
                        &self.dropped_tun_packets,
                        forwarded.into_iter(),
                        &mut error,
                        now,
                    );

                    self.needs_timeout = true;

                    tick.want_continue();
                }

                if let Some(received) = network {
                    let mut jobs = self.io.new_decrypt_jobs(received);
                    let (mut batches, segments) = jobs.split();
                    let mut segments = segments
                        .inspect(|segment| udp_received.record(segment))
                        .peekable();

                    while let Some(segment) = segments.next() {
                        let (local, from) = (segment.local(), segment.from());

                        let mut batch = match self
                            .role_state
                            .handle_network_input(local, from, &segment, now)
                            .with_context(|| FailedToHandleNetworkPacket { local, from })
                        {
                            Ok(Some(batch)) => batch,
                            Ok(None) => {
                                self.needs_timeout = true;
                                continue;
                            }
                            Err(e) => {
                                error.push(e);
                                continue;
                            }
                        };

                        while segments
                            .next_if(|next| next.may_join(&segment) && batch.push(next, now))
                            .is_some()
                        {}

                        batches.add(batch.finish(), &segment);
                    }

                    tick.want_continue();
                }

                if let Some(mut decrypted) = decrypted {
                    for io::DecryptedBatch {
                        local,
                        from,
                        ecn,
                        packets,
                    } in decrypted.drain()
                    {
                        let local_tun = self.role_state.tunnel_ip_config();
                        let batch = match self
                            .role_state
                            .handle_peer_batch(packets, local, from, now)
                        {
                            Ok(batch) => batch,
                            Err(e) => {
                                error.push(e.context(FailedToHandleNetworkPacket { local, from }));
                                continue;
                            }
                        };

                        for result in batch {
                            match result {
                                Ok(Some(packet)) => {
                                    let packet = packet.with_ecn_from_transport(ecn);

                                    let Some(packet) =
                                        forward_served(&mut self.io, local_tun, packet, now)
                                    else {
                                        continue;
                                    };

                                    tun_transmitted.record(&packet);
                                    self.io.queue_tun(packet);
                                }
                                Ok(None) => self.needs_timeout = true,
                                Err(e) => error
                                    .push(e.context(FailedToHandleNetworkPacket { local, from })),
                            };
                        }
                    }

                    self.io.flush_tun_batch();

                    tick.want_continue();
                }

                for io::DnsQuery {
                    local,
                    remote,
                    message,
                    transport,
                } in dns_queries
                {
                    match self
                        .role_state
                        .handle_site_dns_query(local, remote, message, transport)
                    {
                        Ok(query) => self.io.send_dns_query(ResolverQuery::new_site(query, now)),
                        Err(response) => {
                            if let Err(e) =
                                send_dns_response(&mut self.io, transport, remote, local, response)
                            {
                                error.push(e);
                            }
                        }
                    }

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

/// Hands a packet a peer sent to a resource we serve to the userspace forwarder, if there is one.
///
/// Every other packet from a peer is for our own tunnel address. Returns the packet when it
/// goes to the TUN device.
fn forward_served(
    io: &mut Io,
    local_tun: Option<IpConfig>,
    packet: IpPacket,
    now: Instant,
) -> Option<IpPacket> {
    if local_tun.is_none_or(|tun| tun.is_ip(packet.destination())) {
        return Some(packet);
    }

    io.forward(packet, now)
}

/// Routes the packets read from the TUN device, or replies from the forwarder, to their peers.
///
/// Consecutive packets of one flow share the routing decision of the first.
fn encapsulate_tun_packets(
    role_state: &mut DeviceState,
    jobs: &mut io::EncryptJobs<'_>,
    dropped_tun_packets: &DroppedTunPackets,
    packets: impl Iterator<Item = IpPacket>,
    error: &mut TunnelError,
    now: Instant,
) {
    let mut packets = packets.peekable();

    while let Some(packet) = packets.next() {
        let mut tun_batch = match role_state.handle_tun_input(packet, now) {
            Ok(Some(tun_batch)) => tun_batch,
            Ok(None) => continue,
            Err(e) => {
                dropped_tun_packets.record(&e, 1);
                error.push(e.context("Failed to handle packet from TUN device"));
                continue;
            }
        };

        while let Some(packet) = packets.next_if(|p| tun_batch.accepts(p)) {
            tun_batch.push(packet);
        }

        let num_packets = tun_batch.num_packets();

        match tun_batch.finish() {
            Ok((encapsulation, packets)) => jobs.add(encapsulation, packets),
            Err(e) => {
                dropped_tun_packets.record(&e, num_packets);
                error.push(e.context("Failed to handle packet from TUN device"));
            }
        }
    }
}

/// Answers a peer we serve through the DNS server we run on our tunnel addresses.
fn send_site_dns_response(io: &mut Io, response: dns::RecursiveResponse) -> std::io::Result<()> {
    let message = response.message.unwrap_or_else(|e| {
        tracing::debug!("DNS query failed: {e}");

        dns_types::Response::servfail(&response.query)
    });

    send_dns_response(
        io,
        response.transport,
        response.remote,
        response.local,
        message,
    )
}

fn send_dns_response(
    io: &mut Io,
    transport: dns::Transport,
    remote: SocketAddr,
    local: SocketAddr,
    message: dns_types::Response,
) -> std::io::Result<()> {
    match transport {
        dns::Transport::Udp => io.send_udp_dns_response(remote, local, message),
        dns::Transport::Tcp => io.send_tcp_dns_response(remote, local, message),
    }
}

/// Whether a response answers a query a peer we serve sent to the DNS server on our tunnel addresses.
///
/// Our own queries arrive on the DNS sentinels; a served peer's on [`TUN_DNS_PORT`].
fn is_site_dns_response(response: &dns::RecursiveResponse) -> bool {
    response.local.port() == TUN_DNS_PORT
}

/// The far ends of a [`Tunnel::fake`]'s channels.
pub struct FakeTunnelEnds {
    pub socket_v4: SocketThreadEnds,
    pub socket_v6: SocketThreadEnds,
    pub dns: ResolverTaskEnds,
    /// Packets sent here are read from the TUN device.
    pub tun_inbound: tun::InboundTx,
    /// Receives the packets written to the TUN device.
    pub tun_outbound: tun::OutboundRx,
}

#[derive(Debug, thiserror::Error)]
#[error("Failed to handle packet from network (src {from} dst {local})")]
pub struct FailedToHandleNetworkPacket {
    local: SocketAddr,
    from: SocketAddr,
}

fn listen_sockets(ips: Vec<IpAddr>, port: u16) -> Vec<SocketAddr> {
    ips.into_iter()
        .map(|ip| SocketAddr::new(ip, port))
        .collect()
}
