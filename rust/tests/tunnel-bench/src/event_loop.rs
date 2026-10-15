//! Per-packet work of a [`ClientTunnel`] / [`GatewayTunnel`] event loop, with real UDP sockets.
//!
//! The event loop runs on its own thread, kept busy by threads that stand in for the TUN device
//! and the peer. A busy event loop never parks, so the wall time per packet is the cost of the
//! event loop. One iteration is one packet.

#![allow(clippy::unwrap_used, clippy::wildcard_enum_match_arm)]

use std::collections::BTreeSet;
use std::future::poll_fn;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::task::{Context, Poll};
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime};

use anyhow::ErrorExt as _;
use bytecodec::{DecodeExt as _, EncodeExt as _};
use connlib_model::{ClientId, GatewayId, RelayId, ResourceId, SiteId};
use criterion::measurement::WallTime;
use criterion::{BenchmarkGroup, Criterion, Throughput};
use dns_types::{Query, RecordType, Response};
use ip_packet::make::TcpFlags;
use ip_packet::{Ecn, IpPacket};
use snownet::{RelaySocket, Transmit, TransmitBuffer};
use socket_factory::{DatagramOut, PerfUdpSocket, SocketFactory, TcpSocket, UdpSocket};
use stun_codec::rfc5389::{Attribute, attributes::XorMappedAddress, methods::BINDING};
use stun_codec::{Message, MessageClass, MessageDecoder, MessageEncoder};
use tun::{MAX_BATCH_SIZE, PacketBatch};
use tunnel::{ClientState, ClientTunnel, GatewayState, GatewayTunnel, TunChannelClosed};
use tunnel_proto::messages::{IceCredentials, IngestToken, Interface, Key, SecretKey, gateway};
use tunnel_proto::{ClientEvent, GatewayEvent, IpConfig};

/// The size of the IP packets sent through the tunnel.
const SIZE: usize = 1280;

#[derive(Debug, Clone, Copy)]
enum Resource {
    Cidr,
    Dns,
}

const RESOURCES: [Resource; 2] = [Resource::Cidr, Resource::Dns];

#[derive(Debug, Clone, Copy)]
enum Protocol {
    Udp,
    Tcp,
}

const PROTOCOLS: [Protocol; 2] = [Protocol::Udp, Protocol::Tcp];

/// The most packets sent through the tunnel in one go, bounding the memory their inputs take.
const BURST: usize = 10_000;

/// How many packets go into the tunnel ahead of those that came out of it.
///
/// Bounded so no UDP receive buffer overflows.
const IN_FLIGHT: usize = 2_048;

/// How often the event loop may park per 1000 packets.
///
/// The event loop idles between bursts. Within one, it would park about once per batch of packets
/// if a stand-in thread could not keep up.
const MAX_PARKS_PER_1K_PACKETS: f64 = 1.0;

bufferpool::buffer_pool!(static DATAGRAMS: Vec<u8> = (u16::MAX as usize, "bench-datagrams"), batch: 2);

criterion::criterion_group! {
    name = benches;
    config = Criterion::default()
        .warm_up_time(Duration::from_millis(500))
        .measurement_time(Duration::from_millis(1500))
        .without_plots();
    targets = bench
}

fn bench(c: &mut Criterion) {
    let mut group = c.benchmark_group("event_loop");
    group.throughput(Throughput::Bits(SIZE as u64 * 8));

    for resource in RESOURCES {
        for protocol in PROTOCOLS {
            for flow_logs in [false, true] {
                let flow_logs_id = if flow_logs {
                    "flow_logs"
                } else {
                    "no_flow_logs"
                };
                let id = |name| format!("{name}/{resource}/{protocol}/{flow_logs_id}");
                let connect = || connect(resource, protocol, flow_logs);

                let (client, gateway, now) = connect();
                outbound(&mut group, id("client_outbound"), client, gateway, now);

                let (client, gateway, now) = connect();
                inbound(&mut group, id("gateway_inbound"), gateway, client, now);

                let (client, gateway, now) = connect();
                outbound(&mut group, id("gateway_outbound"), gateway, client, now);

                let (client, gateway, now) = connect();
                inbound(&mut group, id("client_inbound"), client, gateway, now);
            }
        }
    }
}

/// Feeds packets into the tunnel's TUN channel and counts the datagrams arriving at the peer.
fn outbound(
    group: &mut BenchmarkGroup<'_, WallTime>,
    id: String,
    local: Side,
    peer: Side,
    now: Instant,
) {
    let (event_loop, _) = EventLoop::spawn(local.state, local.socket, now);
    let arrivals = Arc::new(Arrivals::default());
    let (peer, socket) = bind_peer(peer.socket);
    peer.spawn({
        let arrivals = arrivals.clone();

        async move {
            loop {
                arrivals.add(socket.recv_from().await.unwrap().len());
            }
        }
    });

    let inputs = |packets| batches(&local.reads, packets);
    measure(group, id, &event_loop, &arrivals, inputs, |batch| {
        let packets = batch.len();
        event_loop.tun_reads.blocking_send(batch).unwrap();

        packets
    });

    event_loop.stop();
}

/// Sends encrypted datagrams to the tunnel's UDP socket and counts the packets it writes to TUN.
fn inbound(
    group: &mut BenchmarkGroup<'_, WallTime>,
    id: String,
    local: Side,
    mut peer: Side,
    now: Instant,
) {
    let (event_loop, mut tun_writes) = EventLoop::spawn(local.state, local.socket, now);
    let arrivals = Arc::new(Arrivals::default());
    let tun_write = std::thread::Builder::new()
        .name("tun-write".to_owned())
        .spawn({
            let arrivals = arrivals.clone();

            move || {
                while let Some(batch) = tun_writes.blocking_recv() {
                    arrivals.add(batch.len());
                }
            }
        })
        .unwrap();
    let (runtime, socket) = bind_peer(peer.socket);

    let inputs = |packets| {
        peer.state
            .encapsulate(&peer.reads, packets, now, local.socket)
    };
    measure(group, id, &event_loop, &arrivals, inputs, |datagram| {
        let packets = datagram.packet.len() / datagram.segment_size;
        runtime.block_on(socket.send(datagram)).unwrap();

        packets
    });

    event_loop.stop();
    tun_write.join().unwrap();
}

/// One side of an established connection.
struct Side {
    state: State,
    socket: SocketAddr,
    /// What this side reads from its TUN device.
    reads: IpPacket,
}

enum State {
    Client(ClientState),
    Gateway(GatewayState),
}

fn connect(resource: Resource, protocol: Protocol, flow_logs: bool) -> (Side, Side, Instant) {
    let mut tunnel = Tunnel::established(resource, flow_logs);
    let request = tunnel.request(protocol);
    let reply = tunnel.reply(protocol);

    let client = Side {
        state: State::Client(tunnel.client),
        socket: CLIENT_SOCKET,
        reads: request,
    };
    let gateway = Side {
        state: State::Gateway(tunnel.gateway),
        socket: GATEWAY_SOCKET,
        reads: reply,
    };

    (client, gateway, tunnel.now)
}

impl State {
    /// Returns `count` copies of `packet` encrypted for `dst`, in as few GSO batches as fit.
    fn encapsulate(
        &mut self,
        packet: &IpPacket,
        count: usize,
        now: Instant,
        dst: SocketAddr,
    ) -> Vec<DatagramOut> {
        let mut transmits = TransmitBuffer::default();
        let segments = (0..count)
            .map(|_| {
                match self {
                    State::Client(client) => client
                        .handle_tun_input(packet.clone(), now, &mut transmits)
                        .unwrap(),
                    State::Gateway(gateway) => gateway
                        .handle_tun_input(packet.clone(), now, &mut transmits)
                        .unwrap(),
                }

                transmits.poll_transmit().unwrap().payload.to_vec()
            })
            .collect::<Vec<_>>();
        let segment_size = segments[0].len();

        segments
            .chunks(DatagramOut::max_len(dst, segment_size) / segment_size)
            .map(|segments| {
                let mut packet = DATAGRAMS.pull();
                packet.clear();
                for segment in segments {
                    packet.extend_from_slice(segment);
                }

                DatagramOut {
                    src: None,
                    dst,
                    packet,
                    segment_size,
                    ecn: Ecn::NonEct,
                }
            })
            .collect()
    }
}

/// A tunnel's event loop, polled on its own thread until its TUN device closes.
struct EventLoop {
    thread: JoinHandle<()>,
    /// The `/proc` status file of its thread.
    status: PathBuf,
    /// The packets its TUN device reads.
    tun_reads: tun::InboundTx,
}

impl EventLoop {
    /// Spawns the event loop of a tunnel bound to `socket`.
    ///
    /// Returns the packets written to its TUN device alongside.
    fn spawn(state: State, socket: SocketAddr, now: Instant) -> (Self, tun::OutboundRx) {
        let (tun_reads, reads) = tun::inbound_channel();
        let (writes, tun_writes) = tun::outbound_channel();
        let tun = Box::new(FakeTun { reads, writes });
        let tcp: Arc<dyn SocketFactory<TcpSocket>> = Arc::new(socket_factory::tcp);
        let udp: Arc<dyn SocketFactory<UdpSocket>> = Arc::new(move |addr| match addr {
            SocketAddr::V4(_) => socket_factory::udp(socket),
            SocketAddr::V6(_) => Err(std::io::ErrorKind::Unsupported.into()),
        });

        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let mut poll_next_event: Box<dyn FnMut(&mut Context<'_>) -> Poll<_> + Send> = {
            let _guard = runtime.enter();

            match state {
                State::Client(client) => {
                    let mut tunnel = ClientTunnel::new(tcp, udp, BTreeSet::new(), false, now);
                    *tunnel.state_mut() = client;
                    tunnel.set_tun(tun);

                    Box::new(move |cx| tunnel.poll_next_event(cx, now).map_ok(drop))
                }
                State::Gateway(gateway) => {
                    let mut tunnel = GatewayTunnel::new(tcp, udp, BTreeSet::new(), now);
                    *tunnel.state_mut() = gateway;
                    tunnel.set_tun(tun);

                    Box::new(move |cx| tunnel.poll_next_event(cx, now).map_ok(drop))
                }
            }
        };

        let (status_tx, status_rx) = std::sync::mpsc::channel();
        let thread = std::thread::Builder::new()
            .name("event-loop".to_owned())
            .spawn(move || {
                let thread_self = std::fs::read_link("/proc/thread-self").unwrap();
                status_tx
                    .send(Path::new("/proc").join(thread_self).join("status"))
                    .unwrap();
                // Errors other than the TUN device closing, like the IPv6 socket failing to bind,
                // are irrelevant here: a lost packet fails the benchmark.
                runtime.block_on(poll_fn(|cx| {
                    loop {
                        match poll_next_event(cx) {
                            Poll::Ready(Ok(())) => {}
                            Poll::Ready(Err(mut errors)) => {
                                if errors.drain().any(|e| e.any_is::<TunChannelClosed>()) {
                                    return Poll::Ready(());
                                }
                            }
                            Poll::Pending => return Poll::Pending,
                        }
                    }
                }))
            })
            .unwrap();
        let status = status_rx.recv().unwrap();

        (
            Self {
                thread,
                status,
                tun_reads,
            },
            tun_writes,
        )
    }

    /// Returns how often the event loop's thread has parked.
    fn parks(&self) -> u64 {
        std::fs::read_to_string(&self.status)
            .unwrap()
            .lines()
            .find_map(|line| line.strip_prefix("voluntary_ctxt_switches:"))
            .unwrap()
            .trim()
            .parse()
            .unwrap()
    }

    fn stop(self) {
        drop(self.tun_reads);
        self.thread.join().unwrap();
    }
}

struct FakeTun {
    reads: tun::InboundRx,
    writes: tun::OutboundTx,
}

impl tun::Tun for FakeTun {
    fn sender(&self) -> &tun::OutboundTx {
        &self.writes
    }

    fn receiver(&mut self) -> &mut tun::InboundRx {
        &mut self.reads
    }

    fn name(&self) -> &str {
        "fake"
    }
}

/// Counts the packets arriving at the far end.
#[derive(Default)]
struct Arrivals {
    count: Mutex<usize>,
    changed: Condvar,
}

impl Arrivals {
    fn count(&self) -> usize {
        *self.count.lock().unwrap()
    }

    fn add(&self, packets: usize) {
        *self.count.lock().unwrap() += packets;
        self.changed.notify_one();
    }

    /// Waits until `target` packets have arrived, failing if they do not within a few seconds.
    fn wait_for(&self, target: usize) {
        let (count, timeout) = self
            .changed
            .wait_timeout_while(
                self.count.lock().unwrap(),
                Duration::from_secs(5),
                |count| *count < target,
            )
            .unwrap();

        assert!(!timeout.timed_out(), "{} packets got lost", target - *count);
    }
}

/// Measures sending packets through the tunnel in bursts, at most [`IN_FLIGHT`] packets ahead of
/// those that arrived, and asserts that the event loop did not park while packets were in flight.
///
/// `inputs` returns the inputs holding the given number of packets, `send` how many packets an
/// input holds.
fn measure<T>(
    group: &mut BenchmarkGroup<'_, WallTime>,
    id: String,
    event_loop: &EventLoop,
    arrivals: &Arrivals,
    mut inputs: impl FnMut(usize) -> Vec<T>,
    mut send: impl FnMut(T) -> usize,
) {
    let before = (event_loop.parks(), arrivals.count());
    group.bench_function(id, |b| {
        b.iter_custom(|iters| {
            let mut elapsed = Duration::ZERO;
            let mut remaining = usize::try_from(iters).unwrap();
            while remaining > 0 {
                let packets = remaining.min(BURST);
                remaining -= packets;
                let inputs = inputs(packets);

                let start = Instant::now();
                let arrived = arrivals.count();
                let mut sent = 0_usize;
                for input in inputs {
                    arrivals.wait_for(arrived + sent.saturating_sub(IN_FLIGHT));
                    sent += send(input);
                }
                arrivals.wait_for(arrived + packets);
                elapsed += start.elapsed();
            }

            elapsed
        })
    });
    let packets = arrivals.count() - before.1;
    let parks = (event_loop.parks() - before.0) as f64 * 1000.0 / packets as f64;

    // Skipped or test runs send too few packets to tell.
    assert!(
        packets < BURST || parks <= MAX_PARKS_PER_1K_PACKETS,
        "Event loop parked {parks:.2} times per 1k packets: a stand-in thread is the bottleneck"
    );
}

/// Returns `count` copies of `packet` in batches.
fn batches(packet: &IpPacket, count: usize) -> Vec<PacketBatch> {
    let mut batches = Vec::<PacketBatch>::new();
    for i in 0..count {
        if i % MAX_BATCH_SIZE == 0 {
            batches.push(PacketBatch::default());
        }
        batches
            .last_mut()
            .unwrap()
            .try_push(packet.clone())
            .unwrap();
    }

    batches
}

/// Binds the peer's socket, on a runtime with a single worker thread.
fn bind_peer(socket: SocketAddr) -> (tokio::runtime::Runtime, PerfUdpSocket) {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .thread_name("peer")
        .enable_all()
        .build()
        .unwrap();
    let _guard = runtime.enter();
    let mut socket = socket_factory::udp(socket).unwrap().into_perf().unwrap();
    socket.set_buffer_sizes(
        socket_factory::SEND_BUFFER_SIZE,
        socket_factory::RECV_BUFFER_SIZE,
    );

    (runtime, socket)
}

const CLIENT_SOCKET: SocketAddr =
    SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(127, 0, 0, 1), 1111));
const GATEWAY_SOCKET: SocketAddr =
    SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(127, 0, 0, 2), 2222));
const RELAY_SOCKET: SocketAddrV4 = SocketAddrV4::new(Ipv4Addr::new(10, 0, 0, 3), 3478);

const CLIENT_TUN_V4: Ipv4Addr = Ipv4Addr::new(100, 64, 0, 1);
const CLIENT_TUN_V6: Ipv6Addr = Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 1);
const GATEWAY_TUN: IpConfig = IpConfig {
    v4: Ipv4Addr::new(100, 64, 0, 2),
    v6: Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 2),
};

const CID: ClientId = ClientId::from_u128(1);
const GID: GatewayId = GatewayId::from_u128(2);
const SITE: SiteId = SiteId::from_u128(3);
const CIDR_RESOURCE: ResourceId = ResourceId::from_u128(4);
const DNS_RESOURCE: ResourceId = ResourceId::from_u128(5);

const CIDR_RESOURCE_IP: Ipv4Addr = Ipv4Addr::new(172, 16, 0, 1);
const DNS_RESOURCE_DOMAIN: &str = "app.example.com";
const DNS_RESOURCE_IP: Ipv4Addr = Ipv4Addr::new(172, 16, 1, 1);

impl std::fmt::Display for Resource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Resource::Cidr => f.write_str("cidr"),
            Resource::Dns => f.write_str("dns"),
        }
    }
}

impl std::fmt::Display for Protocol {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Protocol::Udp => f.write_str("udp"),
            Protocol::Tcp => f.write_str("tcp"),
        }
    }
}

impl Resource {
    fn id(self) -> ResourceId {
        match self {
            Resource::Cidr => CIDR_RESOURCE,
            Resource::Dns => DNS_RESOURCE,
        }
    }

    /// Returns the resource as the portal describes it to both the Client and the Gateway.
    fn description(self) -> serde_json::Value {
        let (kind, address) = match self {
            Resource::Cidr => ("cidr", "172.16.0.0/24"),
            Resource::Dns => ("dns", DNS_RESOURCE_DOMAIN),
        };

        serde_json::json!({
            "type": kind,
            "id": self.id(),
            "address": address,
            "name": kind,
            "filters": [],
            "sites": [{ "id": SITE, "name": "site" }],
        })
    }
}

/// A Client and a Gateway with an established connection through which the Client may reach the
/// given resource.
struct Tunnel {
    client: ClientState,
    gateway: GatewayState,
    now: Instant,
    /// Where the Client sends packets for the resource: its address or the DNS proxy IP.
    dst: IpAddr,
}

impl Tunnel {
    fn established(resource: Resource, flow_logs: bool) -> Self {
        let now = Instant::now();
        let unix_ts = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap();

        let mut client = ClientState::new([1; 32], BTreeSet::new(), false, now, unix_ts);
        client.set_flow_logs_enabled(flow_logs);
        client.update_interface_config(Interface {
            ipv4: CLIENT_TUN_V4,
            ipv6: CLIENT_TUN_V6,
            upstream_dns: Vec::new(),
            upstream_do53: Vec::new(),
            upstream_doh: Vec::new(),
            search_domain: None,
        });
        client.update_system_resolvers(vec![IpAddr::from([1, 1, 1, 1])]);
        let sentinel = std::iter::from_fn(|| client.poll_event())
            .find_map(|event| {
                let ClientEvent::TunInterfaceUpdated(config) = event else {
                    return None;
                };

                config.dns_by_sentinel.sentinel_ips().first().copied()
            })
            .unwrap();
        client.set_resources(
            vec![serde_json::from_value(resource.description()).unwrap()],
            now,
        );
        client.update_relays(BTreeSet::new(), relays(), now);

        let mut gateway = GatewayState::new([2; 32], now, unix_ts);
        gateway.set_flow_logs_enabled(flow_logs);
        gateway.update_tun_device(GATEWAY_TUN);
        gateway.update_relays(BTreeSet::new(), relays(), now);

        let dst = match resource {
            Resource::Cidr => CIDR_RESOURCE_IP.into(),
            Resource::Dns => resolve(&mut client, sentinel, now),
        };

        let mut tunnel = Self {
            client,
            gateway,
            now,
            dst,
        };

        tunnel
            .client
            .handle_tun_input(
                tunnel.request(Protocol::Udp),
                now,
                &mut TransmitBuffer::default(),
            )
            .unwrap();

        for _ in 0..200 {
            tunnel.step(resource);
        }

        tunnel
    }

    fn request(&self, protocol: Protocol) -> IpPacket {
        packet(protocol, CLIENT_TUN_V4.into(), self.dst, 50000, 443)
    }

    /// Mirrors a request as the Gateway writes it to its TUN device.
    fn reply(&mut self, protocol: Protocol) -> IpPacket {
        let mut transmits = TransmitBuffer::default();
        self.client
            .handle_tun_input(self.request(protocol), self.now, &mut transmits)
            .unwrap();
        let datagram = transmits.poll_transmit().unwrap();
        let request = self
            .gateway
            .handle_network_input(GATEWAY_SOCKET, CLIENT_SOCKET, &datagram.payload, self.now)
            .unwrap()
            .unwrap();
        let (sport, dport) = match protocol {
            Protocol::Udp => {
                let udp = request.as_udp().unwrap();
                (udp.source_port(), udp.destination_port())
            }
            Protocol::Tcp => {
                let tcp = request.as_tcp().unwrap();
                (tcp.source_port(), tcp.destination_port())
            }
        };

        packet(
            protocol,
            request.destination(),
            request.source(),
            dport,
            sport,
        )
    }

    fn step(&mut self, resource: Resource) {
        self.now += Duration::from_millis(10);
        let now = self.now;

        if self.client.poll_timeout().is_some_and(|(t, _)| t <= now) {
            self.client.handle_timeout(now);
        }
        if self.gateway.poll_timeout().is_some_and(|(t, _)| t <= now) {
            self.gateway.handle_timeout(now);
        }

        while let Some(event) = self.client.poll_event() {
            match event {
                ClientEvent::RequestAccess { .. } => self.authorize(resource),
                ClientEvent::AddedIceCandidates { candidates, .. } => {
                    for candidate in candidates {
                        self.gateway.add_ice_candidate(CID, candidate, now);
                    }
                }
                _ => {}
            }
        }
        while let Some(event) = self.gateway.poll_event() {
            match event {
                GatewayEvent::AddedIceCandidates { candidates, .. } => {
                    for candidate in candidates {
                        self.client.add_ice_candidate(GID, candidate, now);
                    }
                }
                GatewayEvent::ResolveDns(request) => {
                    self.gateway
                        .handle_domain_resolved(request, Ok(vec![DNS_RESOURCE_IP.into()]), now)
                        .unwrap();
                }
                _ => {}
            }
        }

        while let Some(transmit) = self.client.poll_transmit() {
            self.route(CLIENT_SOCKET, transmit);
        }
        while let Some(transmit) = self.gateway.poll_transmit() {
            self.route(GATEWAY_SOCKET, transmit);
        }
        for _ in std::iter::from_fn(|| self.client.poll_packets()) {}
    }

    fn authorize(&mut self, resource: Resource) {
        let preshared_key = || SecretKey::init_with(|| Key([3; 32]));
        let client_ice = IceCredentials {
            username: "client".to_owned(),
            password: "client-password".to_owned(),
        };
        let gateway_ice = IceCredentials {
            username: "gateway".to_owned(),
            password: "gateway-password".to_owned(),
        };

        self.gateway.create_authorization(
            gateway::Client {
                id: CID,
                public_key: self.client.public_key().into(),
                preshared_key: preshared_key(),
                ipv4: CLIENT_TUN_V4,
                ipv6: CLIENT_TUN_V6,
            },
            client_ice.clone(),
            gateway_ice.clone(),
            None,
            serde_json::from_value(resource.description()).unwrap(),
            false,
            self.now,
            ingest_token(),
        );
        self.client
            .handle_resource_access_authorized(
                resource.id(),
                GID,
                self.gateway.public_key(),
                GATEWAY_TUN,
                SITE,
                preshared_key(),
                client_ice,
                gateway_ice,
                false,
                ingest_token(),
                self.now,
            )
            .unwrap();
    }

    /// Delivers a datagram, standing in for a relay that only answers STUN binding requests.
    ///
    /// That is enough for both sides to learn their host candidates and connect directly.
    fn route(&mut self, from: SocketAddr, transmit: Transmit) {
        let relay = SocketAddr::V4(RELAY_SOCKET);

        if transmit.dst != relay {
            self.deliver(from, transmit.dst, &transmit.payload);
            return;
        }

        let Some(response) = binding_response(&transmit.payload, from) else {
            return;
        };
        self.deliver(relay, from, &response);
    }

    fn deliver(&mut self, from: SocketAddr, to: SocketAddr, payload: &[u8]) {
        if to == CLIENT_SOCKET {
            let _ = self
                .client
                .handle_network_input(to, from, payload, self.now);
        }
        if to == GATEWAY_SOCKET {
            let _ = self
                .gateway
                .handle_network_input(to, from, payload, self.now);
        }
    }
}

/// Resolves the DNS resource through the Client's stub resolver and returns its proxy IP.
fn resolve(client: &mut ClientState, sentinel: IpAddr, now: Instant) -> IpAddr {
    let query = Query::new(DNS_RESOURCE_DOMAIN.parse().unwrap(), RecordType::A).into_bytes();
    let query = ip_packet::make::udp_packet(CLIENT_TUN_V4, sentinel, 5353, 53, &query).unwrap();

    client
        .handle_tun_input(query, now, &mut TransmitBuffer::default())
        .unwrap();
    let response = client.poll_packets().unwrap();
    let response = Response::parse(response.as_udp().unwrap().payload()).unwrap();

    response
        .records()
        .find_map(dns_types::records::extract_ip)
        .unwrap()
}

/// Returns a packet of [`SIZE`] bytes, a data segment of an established connection for TCP.
fn packet(protocol: Protocol, src: IpAddr, dst: IpAddr, sport: u16, dport: u16) -> IpPacket {
    match protocol {
        Protocol::Udp => {
            ip_packet::make::udp_packet(src, dst, sport, dport, &[0; SIZE - 28]).unwrap()
        }
        Protocol::Tcp => {
            let ack = TcpFlags {
                syn: false,
                ack: true,
                rst: false,
            };

            ip_packet::make::tcp_packet(src, dst, sport, dport, ack, &[0; SIZE - 40]).unwrap()
        }
    }
}

fn binding_response(request: &[u8], from: SocketAddr) -> Option<Vec<u8>> {
    let request = MessageDecoder::<Attribute>::new()
        .decode_from_bytes(request)
        .ok()?
        .ok()?;
    if request.method() != BINDING {
        return None;
    }

    let mut response = Message::<Attribute>::new(
        MessageClass::SuccessResponse,
        BINDING,
        request.transaction_id(),
    );
    response.add_attribute(XorMappedAddress::new(from));

    MessageEncoder::new().encode_into_bytes(response).ok()
}

fn relays() -> BTreeSet<(RelayId, RelaySocket, String, String, String)> {
    BTreeSet::from([(
        RelayId::from_u128(6),
        RelaySocket::V4(RELAY_SOCKET),
        "username".to_owned(),
        "password".to_owned(),
        "firezone".to_owned(),
    )])
}

fn ingest_token() -> IngestToken {
    serde_json::from_value(serde_json::json!(flow_tracker::TEST_INGEST_TOKEN)).unwrap()
}
