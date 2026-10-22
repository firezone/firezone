//! Per-packet work of a [`ClientTunnel`] / [`GatewayTunnel`] event loop, with real UDP sockets
//! and the real TUN worker threads over an in-memory device.
//!
//! The event loop runs on its own thread, kept busy by the TUN threads and a thread that stands in
//! for the peer. A busy event loop never parks, so the wall time per packet is the cost of the
//! event loop. One iteration is one packet.
//!
//! The `gateway_many_clients` benchmarks connect many Clients to one Gateway instead, and either
//! spread the packets over all of them or leave the Gateway to maintain the idle connections.

#![allow(clippy::unwrap_used, clippy::wildcard_enum_match_arm)]

mod device;

use std::collections::{BTreeMap, BTreeSet};
use std::future::{Future as _, poll_fn};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::ops::RangeInclusive;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{RecvTimeoutError, Sender};
use std::sync::{Arc, Condvar, LazyLock, Mutex};
use std::task::{Context, Poll};
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime};

use anyhow::ErrorExt as _;
use connlib_model::{ClientId, GatewayId, RelayId, ResourceId, SiteId};
use criterion::measurement::Measurement;
use criterion::{BenchmarkGroup, Criterion, SamplingMode, Throughput};
use dns_types::{Query, RecordType, Response};
use ip_packet::{Ecn, IpPacket};
use rand::{SeedableRng as _, rngs::StdRng};
use relay_proto::auth::AccountId;
use relay_proto::{AllocationPort, ChannelData, ClientSocket, Command, PeerSocket};
use snownet::RelaySocket;
use socket_factory::{DatagramOut, PerfUdpSocket, SocketFactory, TcpSocket, UdpSocket};
use tunnel::{
    ClientState, ClientTunnel, GatewayState, GatewayTunnel, TunChannelClosed, TunnelError,
};
use tunnel_proto::messages::{IceCredentials, IngestToken, Interface, Key, SecretKey, gateway};
use tunnel_proto::{ClientEvent, GatewayEvent, IpConfig};
use uuid::Uuid;

use crate::measure::Stage;
use crate::thread_cpu::thread_cpu_times;
use device::Device;

/// The size of the IP packets sent through the tunnel.
const SIZE: usize = 1280;

const GROUP: &str = "event_loop";

/// The file to write the measures of all benchmarks to in Bencher Metric Format, if set.
///
/// An environment variable because criterion parses the whole command line itself.
const BENCHER_JSON_ENV: &str = "TUNNEL_BENCH_JSON";

#[derive(Debug, Clone, Copy)]
enum Resource {
    Cidr,
    Dns,
}

const RESOURCES: [Resource; 2] = [Resource::Cidr, Resource::Dns];

/// How a Client and the Gateway find each other's socket.
#[derive(Debug, Clone, Copy)]
enum Connectivity {
    Ice,
    Iceless,
}

const CONNECTIVITIES: [Connectivity; 2] = [Connectivity::Ice, Connectivity::Iceless];

/// How many Clients the `gateway_many_clients` benchmarks connect to one Gateway.
///
/// On macOS, where they share an address (see [`client_socket`]), few enough that the Gateway never
/// rate-limits their handshakes.
const CLIENTS: usize = cfg_select! {
    target_os = "macos" => { 20 }
    _ => { 1000 }
};

/// How long criterion watches an idle event loop.
const IDLE_TIME: Duration = Duration::from_secs(10);

/// How often the in-process handshake lets time pass, which is also the round-trip time.
const STEP: Duration = Duration::from_millis(100);

/// How often an idle connection sends a keepalive.
const KEEPALIVE: Duration = Duration::from_secs(25);

/// The most packets sent through the tunnel in one go, bounding the memory their inputs take.
const BURST: usize = 10_000;

/// How many packets go into the tunnel ahead of those that came out of it.
///
/// Deep enough that the event loop never drains the pipeline while a stand-in thread wakes up,
/// shallow enough that no UDP receive buffer overflows: macOS caps a socket buffer at 8 MiB
/// (`kern.ipc.maxsockbuf`), which holds about 4096 datagrams of [`SIZE`] bytes. The crypto workers
/// make the pipeline deeper than that on many-core machines, so Linux, whose benchmark container
/// raises `rmem_max` to 16 MiB, keeps twice as many in flight.
const IN_FLIGHT: usize = cfg_select! {
    target_os = "macos" => { 4_096 }
    _ => { 8_192 }
};

/// How many packets the receiving side sends to its peer before a benchmark.
///
/// That is one transmit above socket-factory's promotion threshold, so the receiver's socket pool
/// connects a flow socket to the peer as either side of a real tunnel does within its first
/// transmits. On macOS, a connected socket receives much more cheaply than the catch-all socket:
/// too cheaply for an unconnected receiver to keep up with the event loop over loopback.
#[cfg(target_os = "macos")]
const FLOW_SOCKET_PACKETS: usize = 16;

/// How often the event loop may park per 1000 packets before a benchmark's measures are discarded.
///
/// The event loop idles between bursts. Within one, it would park about once per batch of packets
/// if a TUN or stand-in thread could not keep up.
const MAX_PARKS_PER_1K_PACKETS: f64 = 1.0;

/// Runs every benchmark under `measurement`, in a criterion group named after it.
pub fn bench<M: Measurement + Copy>(c: &mut Criterion<M>, measurement: M, group_name: &str) {
    prioritize_stand_in();
    let mut group = c.benchmark_group(group_name);
    group.throughput(Throughput::Bits(SIZE as u64 * 8));
    let mut report = BTreeMap::new();

    for resource in RESOURCES {
        let id = |name| format!("{name}/{resource}");
        let connect = || connect(resource, true);

        let (client, gateway, now) = connect();
        report.extend(outbound(
            &mut group,
            measurement,
            id("client_outbound"),
            client,
            gateway,
            now,
        ));

        let (client, gateway, now) = connect();
        report.extend(inbound(
            &mut group,
            measurement,
            id("gateway_inbound"),
            gateway,
            vec![client],
            now,
        ));

        let (client, gateway, now) = connect();
        report.extend(outbound(
            &mut group,
            measurement,
            id("gateway_outbound"),
            gateway,
            client,
            now,
        ));

        let (client, gateway, now) = connect();
        report.extend(inbound(
            &mut group,
            measurement,
            id("client_inbound"),
            client,
            vec![gateway],
            now,
        ));
    }

    for connectivity in CONNECTIVITIES {
        let sides = connect_many(connectivity);
        report.extend(inbound(
            &mut group,
            measurement,
            format!("gateway_many_clients/{connectivity}/traffic"),
            sides.gateway,
            sides.clients,
            sides.now,
        ));
    }
    group.finish();

    // A group of their own, as the idle benchmarks have no throughput.
    let mut group = c.benchmark_group(group_name);
    group
        .sampling_mode(SamplingMode::Flat)
        .measurement_time(IDLE_TIME);
    for connectivity in CONNECTIVITIES {
        report.extend(idle(
            &mut group,
            measurement,
            format!("gateway_many_clients/{connectivity}/idle"),
            connect_many(connectivity),
        ));
    }
    group.finish();

    if let Some(path) = std::env::var_os(BENCHER_JSON_ENV) {
        let json = report
            .iter()
            .map(|(name, measures)| (name.clone(), measures.bmf()))
            .collect::<serde_json::Map<_, _>>();
        std::fs::write(path, serde_json::to_vec_pretty(&json).unwrap()).unwrap();
    }
}

/// Lets the tunnel read packets from its TUN device and counts the datagrams arriving at the peer.
fn outbound<M: Measurement + Copy>(
    group: &mut BenchmarkGroup<'_, M>,
    measurement: M,
    id: String,
    local: Side,
    peer: Side,
    now: Instant,
) -> Option<(String, Measures)> {
    let device = Device::new(&local.reads);
    let event_loop = EventLoop::spawn(local.state, local.socket, Clock::Frozen(now), &device);
    let arrivals = Arc::new(Arrivals::default());
    let runtime = peer_runtime();
    let socket = bind_peer(&runtime, peer.socket);

    #[cfg(target_os = "macos")]
    {
        let mut peer = peer;
        let datagrams = peer
            .state
            .encapsulate(&peer.reads, FLOW_SOCKET_PACKETS, now, local.socket);
        for datagram in datagrams {
            runtime.block_on(socket.send(datagram)).unwrap();
        }

        assert_eq!(socket.flow_socket_count(), 1);
    }

    runtime.spawn({
        let arrivals = arrivals.clone();

        async move {
            loop {
                arrivals.add(socket.recv_from().await.unwrap().len());
            }
        }
    });

    let inputs = |packets| device.grants(packets);
    let measures = measure(
        group,
        measurement,
        id,
        &event_loop,
        &arrivals,
        inputs,
        |packets| {
            device.grant(packets);

            packets
        },
    );

    event_loop.stop();

    measures
}

/// Sends encrypted datagrams from the peers to the tunnel's UDP socket and counts the packets it
/// writes to TUN.
///
/// Several peers take turns packet by packet, so only a lone peer batches segments into a datagram.
fn inbound<M: Measurement + Copy>(
    group: &mut BenchmarkGroup<'_, M>,
    measurement: M,
    id: String,
    local: Side,
    mut peers: Vec<Side>,
    now: Instant,
) -> Option<(String, Measures)> {
    let device = Device::new(&local.reads);
    let event_loop = EventLoop::spawn(local.state, local.socket, Clock::Frozen(now), &device);
    let runtime = peer_runtime();
    let sockets = peers
        .iter()
        .map(|peer| bind_peer(&runtime, peer.socket))
        .collect::<Vec<_>>();

    #[cfg(target_os = "macos")]
    {
        device.grant(FLOW_SOCKET_PACKETS);

        let mut received = 0;
        while received < FLOW_SOCKET_PACKETS {
            received += runtime.block_on(sockets[0].recv_from()).unwrap().len();
        }
    }

    let turn = if peers.len() == 1 { BURST } else { 1 };
    let inputs = |packets: usize| {
        (0..packets)
            .step_by(turn)
            .flat_map(|first| {
                let index = (first / turn) % peers.len();
                let peer = &mut peers[index];

                peer.state
                    .encapsulate(&peer.reads, turn.min(packets - first), now, local.socket)
                    .into_iter()
                    .map(move |datagram| (index, datagram))
            })
            .collect()
    };
    let measures = measure(
        group,
        measurement,
        id,
        &event_loop,
        device.writes(),
        inputs,
        |(index, datagram)| {
            let packets = datagram.packet.len() / datagram.segment_size;
            runtime.block_on(sockets[index].send(datagram)).unwrap();

            packets
        },
    );

    event_loop.stop();

    measures
}

/// Leaves the Gateway to maintain its connections to the Clients, which answer it from a thread of
/// their own on a running clock, and measures the event loop per connection-second.
///
/// Returns nothing for skipped or test runs, which watch too briefly to tell.
fn idle<M: Measurement + Copy>(
    group: &mut BenchmarkGroup<'_, M>,
    measurement: M,
    id: String,
    sides: Sides,
) -> Option<(String, Measures)> {
    let device = Device::new(&sides.gateway.reads);
    let clock = Clock::running(sides.now);
    let event_loop = EventLoop::spawn(sides.gateway.state, sides.gateway.socket, clock, &device);
    let connections = sides.clients.len();
    let clients = sides
        .clients
        .into_iter()
        .map(|side| match side.state {
            State::Client(client) => (side.socket, client),
            State::Gateway(_) => unreachable!(),
        })
        .collect();
    let peers = Peers::serve(clients, sides.relay, clock);

    let before = cpu_by_thread();
    let mut elapsed = Duration::ZERO;
    group.bench_function(&id, |b| {
        b.iter_custom(|iters| {
            let window = Duration::from_secs(iters) / u32::try_from(connections).unwrap();
            let measuring = measurement.start();
            std::thread::sleep(window);
            elapsed += window;

            measurement.end(measuring)
        })
    });

    let work = Work::ConnectionSeconds(elapsed.as_secs_f64() * connections as f64);
    let measures = Measures::since(before, work);
    peers.stop();
    event_loop.stop();

    (elapsed >= Duration::from_secs(1)).then(|| (format!("{GROUP}/{id}"), measures))
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

/// The Clients and the Gateway of an established [`Tunnel`], and the relay they allocated on.
struct Sides {
    clients: Vec<Side>,
    gateway: Side,
    relay: Relay,
    now: Instant,
}

fn connect(resource: Resource, flow_logs: bool) -> (Side, Side, Instant) {
    let mut sides = Tunnel::established(1, Connectivity::Ice, resource, flow_logs).into_sides();

    (sides.clients.remove(0), sides.gateway, sides.now)
}

fn connect_many(connectivity: Connectivity) -> Sides {
    Tunnel::established(CLIENTS, connectivity, Resource::Cidr, true).into_sides()
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
        let segments = (0..count)
            .map(|_| {
                let mut packet = packet.clone();
                let encapsulation = match self {
                    State::Client(client) => client.handle_tun_input(&mut packet, now),
                    State::Gateway(gateway) => gateway.handle_tun_input(&mut packet, now),
                };

                encapsulation
                    .unwrap()
                    .unwrap()
                    .encrypt(&packet)
                    .unwrap()
                    .payload
                    .to_vec()
            })
            .collect::<Vec<_>>();
        let segment_size = segments[0].len();

        segments
            .chunks(DatagramOut::max_len(dst, segment_size) / segment_size)
            .map(|segments| {
                let mut packet = bufferpool::Bytes::fitting(64 * 1024);
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

/// The time an event loop and its peers run on, counted from where the fixture's handshake ended.
#[derive(Clone, Copy)]
enum Clock {
    /// Stands still, so no timer ever fires.
    Frozen(Instant),
    /// Advances in real time since `started`.
    Running { base: Instant, started: Instant },
}

impl Clock {
    fn running(base: Instant) -> Self {
        Self::Running {
            base,
            started: Instant::now(),
        }
    }

    fn now(self) -> Instant {
        match self {
            Clock::Frozen(now) => now,
            Clock::Running { base, started } => base + started.elapsed(),
        }
    }
}

/// A tunnel's event loop, polled on its own thread until its TUN device closes.
struct EventLoop {
    thread: JoinHandle<()>,
    /// How often its thread has parked.
    parks: Arc<AtomicU64>,
    device: Device,
}

impl EventLoop {
    /// Spawns the event loop of a tunnel bound to `socket`, with its TUN workers on `device`.
    fn spawn(state: State, socket: SocketAddr, clock: Clock, device: &Device) -> Self {
        let tcp: Arc<dyn SocketFactory<TcpSocket>> = Arc::new(socket_factory::tcp);
        let udp: Arc<dyn SocketFactory<UdpSocket>> = Arc::new(move |addr| match addr {
            SocketAddr::V4(_) => socket_factory::udp(socket),
            SocketAddr::V6(_) => Err(std::io::ErrorKind::Unsupported.into()),
        });

        let parks = Arc::new(AtomicU64::new(0));
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .on_thread_park({
                let parks = parks.clone();

                move || {
                    parks.fetch_add(1, Ordering::Relaxed);
                }
            })
            .build()
            .unwrap();
        let mut tunnel = {
            let _guard = runtime.enter();
            let tun = device.io(runtime.handle());
            let now = clock.now();

            match state {
                State::Client(client) => {
                    let mut tunnel = ClientTunnel::new(tcp, udp, BTreeSet::new(), false, now);
                    *tunnel.state_mut() = client;
                    tunnel.set_tun(tun);

                    AnyTunnel::Client(tunnel)
                }
                State::Gateway(gateway) => {
                    let mut tunnel = GatewayTunnel::new(tcp, udp, BTreeSet::new(), now);
                    *tunnel.state_mut() = gateway;
                    tunnel.set_tun(tun);

                    AnyTunnel::Gateway(tunnel)
                }
            }
        };

        let thread = std::thread::Builder::new()
            .name("event-loop".to_owned())
            .spawn(move || {
                let mut timer = {
                    let _guard = runtime.enter();

                    Box::pin(tokio::time::sleep(Duration::ZERO))
                };

                // Errors other than the TUN device closing, like the IPv6 socket failing to bind,
                // are irrelevant here: a lost packet fails the benchmark.
                runtime.block_on(poll_fn(|cx| {
                    loop {
                        let now = clock.now();
                        match tunnel.poll_next_event(cx, now) {
                            Poll::Ready(Ok(())) => continue,
                            Poll::Ready(Err(mut errors)) => {
                                if errors.drain().any(|e| e.any_is::<TunChannelClosed>()) {
                                    return Poll::Ready(());
                                }

                                continue;
                            }
                            Poll::Pending => {}
                        }

                        let Clock::Running { base, started } = clock else {
                            return Poll::Pending;
                        };
                        let Some(deadline) = tunnel.next_timeout(now) else {
                            return Poll::Pending;
                        };
                        if deadline <= now {
                            tunnel.handle_timeout(now);
                            continue;
                        }

                        let wake = started + deadline.duration_since(base);
                        timer.as_mut().reset(tokio::time::Instant::from_std(wake));
                        if timer.as_mut().poll(cx).is_pending() {
                            return Poll::Pending;
                        }
                    }
                }))
            })
            .unwrap();

        Self {
            thread,
            parks,
            device: device.clone(),
        }
    }

    /// Returns how often the event loop's thread has parked.
    fn parks(&self) -> u64 {
        self.parks.load(Ordering::Relaxed)
    }

    /// Closes the TUN device, which stops its workers and thereby the event loop.
    fn stop(self) {
        self.device.stop();
        self.thread.join().unwrap();
    }
}

enum AnyTunnel {
    Client(ClientTunnel),
    Gateway(GatewayTunnel),
}

impl AnyTunnel {
    fn poll_next_event(
        &mut self,
        cx: &mut Context<'_>,
        now: Instant,
    ) -> Poll<Result<(), TunnelError>> {
        match self {
            AnyTunnel::Client(tunnel) => tunnel.poll_next_event(cx, now).map_ok(drop),
            AnyTunnel::Gateway(tunnel) => tunnel.poll_next_event(cx, now).map_ok(drop),
        }
    }

    fn next_timeout(&mut self, now: Instant) -> Option<Instant> {
        match self {
            AnyTunnel::Client(tunnel) => tunnel.next_timeout(now),
            AnyTunnel::Gateway(tunnel) => tunnel.next_timeout(now),
        }
    }

    fn handle_timeout(&mut self, now: Instant) {
        match self {
            AnyTunnel::Client(tunnel) => tunnel.state_mut().handle_timeout(now),
            AnyTunnel::Gateway(tunnel) => tunnel.state_mut().handle_timeout(now),
        }
    }
}

/// Datagrams as the local socket they arrived on, their source and their payload.
type Received = (SocketAddr, SocketAddr, Vec<u8>);

/// The Clients of an idle Gateway and their relay, answering it from a thread of their own.
struct Peers {
    thread: JoinHandle<()>,
    /// Stops the thread when sent `None`.
    stop: Sender<Option<Received>>,
    /// Receives on the sockets.
    runtime: tokio::runtime::Runtime,
}

impl Peers {
    fn serve(mut clients: Vec<(SocketAddr, ClientState)>, mut relay: Relay, clock: Clock) -> Self {
        let runtime = peer_runtime();
        let (tx, rx) = std::sync::mpsc::channel();
        let mut sockets = Sockets {
            runtime: runtime.handle().clone(),
            received: tx.clone(),
            bound: BTreeMap::new(),
        };
        for (socket, _) in &clients {
            sockets.bind(*socket);
        }
        sockets.bind(*RELAY_SOCKET);
        sockets.bind_allocations(&relay);

        let thread = std::thread::Builder::new()
            .name("peers".to_owned())
            .spawn(move || {
                loop {
                    let deadline = clients
                        .iter_mut()
                        .filter_map(|(_, client)| Some(client.poll_timeout()?.0))
                        .min();
                    let received = match deadline {
                        Some(deadline) => {
                            rx.recv_timeout(deadline.saturating_duration_since(clock.now()))
                        }
                        None => rx.recv().map_err(|_| RecvTimeoutError::Disconnected),
                    };
                    let first = match received {
                        Ok(received) => Some(received),
                        Err(RecvTimeoutError::Timeout) => None,
                        Err(RecvTimeoutError::Disconnected) => return,
                    };
                    for received in first.into_iter().chain(rx.try_iter()) {
                        let Some((local, from, payload)) = received else {
                            return;
                        };
                        let now = clock.now();
                        if relay.serves(local) {
                            for (from, to, payload) in relay.handle(from, local, &payload, now) {
                                sockets.send(from, to, &payload);
                            }
                            sockets.bind_allocations(&relay);
                        } else {
                            let (_, client) = &mut clients[client_index(local).unwrap()];
                            receive(client, local, from, &payload, now);
                        }
                    }

                    let now = clock.now();
                    for (socket, client) in &mut clients {
                        if client.poll_timeout().is_some_and(|(t, _)| t <= now) {
                            client.handle_timeout(now);
                        }
                        while let Some(transmit) = client.poll_transmit() {
                            sockets.send(*socket, transmit.dst, &transmit.payload);
                        }
                        for _ in std::iter::from_fn(|| client.poll_event()) {}
                        for _ in std::iter::from_fn(|| client.poll_packets()) {}
                    }
                }
            })
            .unwrap();

        Self {
            thread,
            stop: tx,
            runtime,
        }
    }

    fn stop(self) {
        self.stop.send(None).unwrap();
        self.thread.join().unwrap();
        drop(self.runtime);
    }
}

/// The sockets of the peers and the relay, by their address.
struct Sockets {
    runtime: tokio::runtime::Handle,
    received: Sender<Option<Received>>,
    bound: BTreeMap<SocketAddr, std::net::UdpSocket>,
}

impl Sockets {
    /// Binds `addr` and passes on what arrives there.
    fn bind(&mut self, addr: SocketAddr) {
        let socket = std::net::UdpSocket::bind(addr).unwrap();
        socket.set_nonblocking(true).unwrap();
        let reader = {
            let _guard = self.runtime.enter();

            tokio::net::UdpSocket::from_std(socket.try_clone().unwrap()).unwrap()
        };
        let received = self.received.clone();
        self.runtime.spawn(async move {
            let mut buf = vec![0; u16::MAX as usize];
            while let Ok((len, from)) = reader.recv_from(&mut buf).await {
                if received
                    .send(Some((addr, from, buf[..len].to_vec())))
                    .is_err()
                {
                    return;
                }
            }
        });

        self.bound.insert(addr, socket);
    }

    fn bind_allocations(&mut self, relay: &Relay) {
        for port in &relay.allocations {
            let addr = SocketAddr::new(RELAY_SOCKET.ip(), *port);
            if !self.bound.contains_key(&addr) {
                self.bind(addr);
            }
        }
    }

    fn send(&self, from: SocketAddr, to: SocketAddr, payload: &[u8]) {
        self.bound[&from].send_to(payload, to).unwrap();
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
/// those that arrived.
///
/// `inputs` returns the inputs holding the given number of packets, `send` how many packets an
/// input holds. Returns the measures under the benchmark's name as criterion reports it, or
/// nothing for skipped or test runs, which send too few packets to tell.
#[allow(clippy::print_stdout, clippy::print_stderr)]
fn measure<M: Measurement + Copy, T>(
    group: &mut BenchmarkGroup<'_, M>,
    measurement: M,
    id: String,
    event_loop: &EventLoop,
    arrivals: &Arrivals,
    mut inputs: impl FnMut(usize) -> Vec<T>,
    mut send: impl FnMut(T) -> usize,
) -> Option<(String, Measures)> {
    let before = (event_loop.parks(), arrivals.count(), cpu_by_thread());
    let mut elapsed = Duration::ZERO;
    group.bench_function(&id, |b| {
        b.iter_custom(|iters| {
            let mut measured = measurement.zero();
            let mut remaining = usize::try_from(iters).unwrap();
            while remaining > 0 {
                let packets = remaining.min(BURST);
                remaining -= packets;
                let inputs = inputs(packets);

                let start = Instant::now();
                let measuring = measurement.start();
                let arrived = arrivals.count();
                let mut sent = 0_usize;
                for input in inputs {
                    arrivals.wait_for(arrived + sent.saturating_sub(IN_FLIGHT));
                    sent += send(input);
                }
                arrivals.wait_for(arrived + packets);
                measured = measurement.add(&measured, &measurement.end(measuring));
                elapsed += start.elapsed();
            }

            measured
        })
    });
    let packets = arrivals.count() - before.1;
    if packets < BURST {
        return None;
    }

    let parks_per_1k = (event_loop.parks() - before.0) as f64 * 1000.0 / packets as f64;
    if parks_per_1k > MAX_PARKS_PER_1K_PACKETS {
        eprintln!(
            "Event loop thread parked {parks_per_1k:.2} times per 1000 packets and may not have been the bottleneck",
        );
    }
    let measures = Measures::since(before.2, Work::Packets { packets, elapsed });

    Some((format!("{GROUP}/{id}"), measures))
}

/// What a benchmark measured besides criterion's wall time.
struct Measures {
    work: Work,
    /// The CPU time each thread spent during the benchmark.
    cpu: BTreeMap<String, Duration>,
}

/// What a benchmark's CPU time is spent on.
enum Work {
    Packets {
        packets: usize,
        /// The wall time the packets took, over all of criterion's iterations.
        elapsed: Duration,
    },
    /// Maintaining idle connections, as the sum of each one's seconds.
    ConnectionSeconds(f64),
}

impl Measures {
    /// Takes the CPU time each thread spent since `before`.
    fn since(before: BTreeMap<String, Duration>, work: Work) -> Self {
        let cpu = cpu_by_thread()
            .into_iter()
            .map(|(name, after)| {
                let before = before.get(&name).copied().unwrap_or_default();

                (name, after.saturating_sub(before))
            })
            .collect();

        Self { work, cpu }
    }

    /// Returns the measures in Bencher Metric Format: for packets, the throughput in bits per
    /// second and each stage's CPU time per packet; for idle connections, the event loop's CPU
    /// time per connection-second.
    fn bmf(&self) -> serde_json::Value {
        let value = |value: f64| serde_json::json!({ "value": value });
        let mut bmf = serde_json::Map::new();
        match self.work {
            Work::Packets { packets, elapsed } => {
                let bitrate = packets as f64 / elapsed.as_secs_f64() * (SIZE * 8) as f64;
                bmf.insert("throughput".to_owned(), value(bitrate));
                for (slug, prefix) in self.active_stages() {
                    bmf.insert(slug.to_owned(), value(self.cpu_ns_per_unit(prefix)));
                }
            }
            Work::ConnectionSeconds(_) => {
                let cpu = self.cpu_ns_per_unit(Stage::EventLoop.thread_prefix());
                bmf.insert("event-loop-idle".to_owned(), value(cpu));
            }
        }

        bmf.into()
    }

    /// Returns the CPU nanoseconds per packet or connection-second of all threads of the given
    /// stage together.
    fn cpu_ns_per_unit(&self, prefix: &str) -> f64 {
        let units = match self.work {
            Work::Packets { packets, .. } => packets as f64,
            Work::ConnectionSeconds(seconds) => seconds,
        };
        let cpu = self
            .stage_threads(prefix)
            .map(|(_, cpu)| cpu)
            .sum::<Duration>();

        cpu.as_nanos() as f64 / units
    }

    /// The stages that had a thread during the benchmark; a benchmark without a TUN device has
    /// no TUN threads.
    fn active_stages(&self) -> impl Iterator<Item = (&'static str, &'static str)> {
        Stage::ALL
            .into_iter()
            .map(|stage| (stage.name(), stage.thread_prefix()))
            .filter(|(_, prefix)| self.stage_threads(prefix).next().is_some())
    }

    fn stage_threads(&self, prefix: &str) -> impl Iterator<Item = (&String, &Duration)> {
        self.cpu
            .iter()
            .filter(move |(name, _)| name.starts_with(prefix))
    }
}

/// Returns the CPU time of every thread of this process so far, by name.
fn cpu_by_thread() -> BTreeMap<String, Duration> {
    thread_cpu_times()
        .into_iter()
        .fold(BTreeMap::new(), |mut threads, (name, cpu)| {
            *threads.entry(name).or_default() += cpu;

            threads
        })
}

/// Raises the scheduling priority of the calling thread on macOS.
///
/// The stand-in thread takes the place of a remote peer, which is not subject to macOS'
/// quality-of-service scheduling. At the default QoS class, its wake-ups are delayed enough to
/// starve the event loop between hand-offs.
fn prioritize_stand_in() {
    #[cfg(target_os = "macos")]
    unsafe {
        libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0);
    }
}

/// Returns a runtime with a single worker thread for the peers' sockets.
fn peer_runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .thread_name("peer")
        .on_thread_start(prioritize_stand_in)
        .enable_all()
        .build()
        .unwrap()
}

fn bind_peer(runtime: &tokio::runtime::Runtime, socket: SocketAddr) -> PerfUdpSocket {
    let _guard = runtime.enter();
    let mut socket = socket_factory::udp(socket).unwrap().into_perf().unwrap();
    socket.set_buffer_sizes(
        socket_factory::SEND_BUFFER_SIZE,
        socket_factory::RECV_BUFFER_SIZE,
    );

    socket
}

/// The port of the first Client's socket; each further Client takes the next one.
const CLIENT_PORT: u16 = 1111;
static GATEWAY_SOCKET: LazyLock<SocketAddr> = LazyLock::new(|| SocketAddr::new(local_ip(), 2222));

/// Returns the socket of the Client with the given index.
///
/// Under load, the Gateway rate-limits handshakes per source address, so each Client gets its own
/// where the loopback interface has a whole range of them; macOS only has 127.0.0.1.
fn client_socket(index: usize) -> SocketAddr {
    let ip = cfg_select! {
        target_os = "macos" => { local_ip() }
        _ => { Ipv4Addr::from(u32::from(Ipv4Addr::LOCALHOST) + u32::try_from(index).unwrap()).into() }
    };

    SocketAddr::new(ip, CLIENT_PORT + u16::try_from(index).unwrap())
}

/// Returns the index of the Client bound to `socket`, if any.
fn client_index(socket: SocketAddr) -> Option<usize> {
    socket.port().checked_sub(CLIENT_PORT).map(usize::from)
}

/// Returns the IP address to bind the Client's and Gateway's sockets to.
///
/// On macOS, that is the host's primary non-loopback address, falling back to loopback without
/// one. Packets to any local address travel over the loopback interface either way, but NECP
/// decides by address: a loopback address takes a bypass that looks up an entitlement on every
/// datagram, which no real interface pays for, and which hides the policy evaluation they do pay.
fn local_ip() -> IpAddr {
    #[cfg(target_os = "macos")]
    {
        // Connecting a UDP socket sends nothing but makes the kernel pick the source address.
        let probe = std::net::UdpSocket::bind("0.0.0.0:0").unwrap();
        if probe.connect("192.0.2.1:9").is_ok()
            && let Ok(addr) = probe.local_addr()
            && !addr.ip().is_loopback()
            && !addr.ip().is_unspecified()
        {
            return addr.ip();
        }
    }

    Ipv4Addr::LOCALHOST.into()
}
static RELAY_SOCKET: LazyLock<SocketAddr> = LazyLock::new(|| SocketAddr::new(local_ip(), 3478));

/// The ports the relay allocates from, clear of the Clients' and the Gateway's sockets and of
/// the ephemeral ports.
const ALLOCATION_PORTS: RangeInclusive<u16> = 10_000..=19_999;

/// The first Client's TUN addresses; each further Client takes the next ones.
const CLIENT_TUN: IpConfig = IpConfig {
    v4: Ipv4Addr::new(100, 64, 0, 1),
    v6: Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 1),
};
const GATEWAY_TUN: IpConfig = IpConfig {
    v4: Ipv4Addr::new(100, 64, 255, 254),
    v6: Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 0xffff),
};

fn client_id(index: usize) -> ClientId {
    ClientId::from_u128(0x1000 + index as u128)
}

fn client_tun(index: usize) -> IpConfig {
    IpConfig {
        v4: Ipv4Addr::from(u32::from(CLIENT_TUN.v4) + u32::try_from(index).unwrap()),
        v6: Ipv6Addr::from(u128::from(CLIENT_TUN.v6) + index as u128),
    }
}

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

impl std::fmt::Display for Connectivity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Connectivity::Ice => f.write_str("ice"),
            Connectivity::Iceless => f.write_str("iceless"),
        }
    }
}

impl Connectivity {
    fn iceless(self) -> bool {
        match self {
            Connectivity::Ice => false,
            Connectivity::Iceless => true,
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

/// Clients and a Gateway with an established connection each, through which the Clients may
/// reach the given resource.
struct Tunnel {
    clients: Vec<Client>,
    gateway: GatewayState,
    relay: Relay,
    now: Instant,
}

struct Client {
    index: usize,
    state: ClientState,
    /// Where it sends packets for the resource: its address or the DNS proxy IP.
    dst: IpAddr,
}

impl Tunnel {
    fn established(
        clients: usize,
        connectivity: Connectivity,
        resource: Resource,
        flow_logs: bool,
    ) -> Self {
        let now = Instant::now();
        let unix_ts = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap();
        let relay = Relay::new(now);

        let mut gateway = GatewayState::new([2; 32], now, unix_ts);
        gateway.set_flow_logs_enabled(flow_logs);
        gateway.update_tun_device(GATEWAY_TUN);
        gateway.update_relays(BTreeSet::new(), relay.description("gateway"), now);

        let clients = (0..clients)
            .map(|index| Client::new(index, resource, flow_logs, &relay, now, unix_ts))
            .collect();

        let mut tunnel = Self {
            clients,
            gateway,
            relay,
            now,
        };

        // A Gateway only signals candidates for a connection once it has a relay allocation.
        tunnel.run_until(now + Duration::from_secs(1), connectivity, resource);

        // Spread over a keepalive interval, so the connections' timers do not all fire at once.
        let start = tunnel.now;
        let count = u32::try_from(tunnel.clients.len()).unwrap();
        for index in 0..tunnel.clients.len() {
            let at = start + KEEPALIVE * u32::try_from(index).unwrap() / count;
            tunnel.run_until(at, connectivity, resource);

            let client = &mut tunnel.clients[index];
            client
                .state
                .handle_tun_input(&mut client.request(), tunnel.now)
                .unwrap();
        }

        // Until the TURN allocations' retransmits and the connections' initial probing are done.
        tunnel.run_until(tunnel.now + Duration::from_secs(20), connectivity, resource);

        tunnel
    }

    /// Splits the tunnel into its sides, each reading what it sends through the tunnel from its
    /// TUN device.
    fn into_sides(mut self) -> Sides {
        let reply = self.reply();
        let clients = self
            .clients
            .into_iter()
            .map(|client| Side {
                socket: client_socket(client.index),
                reads: client.request(),
                state: State::Client(client.state),
            })
            .collect();
        let gateway = Side {
            state: State::Gateway(self.gateway),
            socket: *GATEWAY_SOCKET,
            reads: reply,
        };

        Sides {
            clients,
            gateway,
            relay: self.relay,
            now: self.now,
        }
    }

    /// Mirrors the first Client's request as the Gateway writes it to its TUN device.
    fn reply(&mut self) -> IpPacket {
        let client = &mut self.clients[0];
        let socket = client_socket(client.index);
        let mut request = client.request();
        let datagram = client
            .state
            .handle_tun_input(&mut request, self.now)
            .unwrap()
            .unwrap()
            .encrypt(&request)
            .unwrap();
        let decapsulation = self
            .gateway
            .handle_network_input(*GATEWAY_SOCKET, socket, &datagram.payload, self.now)
            .unwrap()
            .unwrap();
        let request = self
            .gateway
            .handle_peer_input(
                *GATEWAY_SOCKET,
                socket,
                decapsulation.decrypt(&datagram.payload),
                self.now,
            )
            .unwrap()
            .unwrap();
        let udp = request.as_udp().unwrap();
        let (sport, dport) = (udp.source_port(), udp.destination_port());

        packet(request.destination(), request.source(), dport, sport)
    }

    fn run_until(&mut self, until: Instant, connectivity: Connectivity, resource: Resource) {
        while self.now < until {
            self.step(connectivity, resource);
        }
    }

    /// Advances the time by [`STEP`], delivering what the Clients and the Gateway sent meanwhile.
    fn step(&mut self, connectivity: Connectivity, resource: Resource) {
        self.now += STEP;
        let now = self.now;

        for client in &mut self.clients {
            if client.state.poll_timeout().is_some_and(|(t, _)| t <= now) {
                client.state.handle_timeout(now);
            }
        }
        if self.gateway.poll_timeout().is_some_and(|(t, _)| t <= now) {
            self.gateway.handle_timeout(now);
        }

        for index in 0..self.clients.len() {
            while let Some(event) = self.clients[index].state.poll_event() {
                match event {
                    ClientEvent::RequestAccess { .. } => {
                        self.authorize(index, connectivity, resource)
                    }
                    ClientEvent::AddedIceCandidates { candidates, .. } => {
                        for candidate in candidates {
                            self.gateway
                                .add_ice_candidate(client_id(index), candidate, now);
                        }
                    }
                    _ => {}
                }
            }
        }
        while let Some(event) = self.gateway.poll_event() {
            match event {
                GatewayEvent::AddedIceCandidates {
                    conn_id,
                    candidates,
                } => {
                    let client = self
                        .clients
                        .iter_mut()
                        .find(|client| client_id(client.index) == conn_id)
                        .unwrap();
                    for candidate in candidates {
                        client.state.add_ice_candidate(GID, candidate, now);
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

        for index in 0..self.clients.len() {
            while let Some(transmit) = self.clients[index].state.poll_transmit() {
                self.deliver(client_socket(index), transmit.dst, &transmit.payload);
            }
        }
        while let Some(transmit) = self.gateway.poll_transmit() {
            self.deliver(*GATEWAY_SOCKET, transmit.dst, &transmit.payload);
        }
        for client in &mut self.clients {
            for _ in std::iter::from_fn(|| client.state.poll_packets()) {}
        }
    }

    fn authorize(&mut self, index: usize, connectivity: Connectivity, resource: Resource) {
        let client = &mut self.clients[index];
        let tun = client_tun(index);
        let preshared_key = || SecretKey::init_with(|| Key([3; 32]));
        let client_ice = IceCredentials {
            username: format!("client-{index}"),
            password: format!("client-password-{index}"),
        };
        let gateway_ice = IceCredentials {
            username: format!("gateway-{index}"),
            password: format!("gateway-password-{index}"),
        };

        self.gateway.create_authorization(
            gateway::Client {
                id: client_id(index),
                public_key: client.state.public_key().into(),
                preshared_key: preshared_key(),
                ipv4: tun.v4,
                ipv6: tun.v6,
            },
            client_ice.clone(),
            gateway_ice.clone(),
            None,
            serde_json::from_value(resource.description()).unwrap(),
            connectivity.iceless(),
            self.now,
            ingest_token(),
        );
        client
            .state
            .handle_resource_access_authorized(
                resource.id(),
                GID,
                self.gateway.public_key(),
                GATEWAY_TUN,
                SITE,
                preshared_key(),
                client_ice,
                gateway_ice,
                connectivity.iceless(),
                ingest_token(),
                self.now,
            )
            .unwrap();
    }

    fn deliver(&mut self, from: SocketAddr, to: SocketAddr, payload: &[u8]) {
        if self.relay.serves(to) {
            for (from, to, payload) in self.relay.handle(from, to, payload, self.now) {
                self.deliver(from, to, &payload);
            }

            return;
        }

        if to == *GATEWAY_SOCKET {
            if let Ok(Some(decapsulation)) = self
                .gateway
                .handle_network_input(to, from, payload, self.now)
            {
                let _ = self.gateway.handle_peer_input(
                    to,
                    from,
                    decapsulation.decrypt(payload),
                    self.now,
                );
            }

            return;
        }

        if let Some(client) = client_index(to).and_then(|index| self.clients.get_mut(index)) {
            receive(&mut client.state, to, from, payload, self.now);
        }
    }
}

/// Lets a Client handle a datagram that arrived on its socket `local`.
fn receive(
    client: &mut ClientState,
    local: SocketAddr,
    from: SocketAddr,
    payload: &[u8],
    now: Instant,
) {
    if let Ok(Some(decapsulation)) = client.handle_network_input(local, from, payload, now) {
        let _ = client.handle_peer_input(local, from, decapsulation.decrypt(payload), now);
    }
}

impl Client {
    fn new(
        index: usize,
        resource: Resource,
        flow_logs: bool,
        relay: &Relay,
        now: Instant,
        unix_ts: Duration,
    ) -> Self {
        let tun = client_tun(index);
        let mut key = [1; 32];
        key[..8].copy_from_slice(&(index as u64).to_be_bytes());

        let mut state = ClientState::new(key, BTreeSet::new(), false, now, unix_ts);
        state.set_flow_logs_enabled(flow_logs);
        state.update_interface_config(Interface {
            ipv4: tun.v4,
            ipv6: tun.v6,
            upstream_dns: Vec::new(),
            upstream_do53: Vec::new(),
            upstream_doh: Vec::new(),
            search_domain: None,
        });
        state.update_system_resolvers(vec![IpAddr::from([1, 1, 1, 1])]);
        let sentinel = std::iter::from_fn(|| state.poll_event())
            .find_map(|event| {
                let ClientEvent::TunInterfaceUpdated(config) = event else {
                    return None;
                };

                config.dns_by_sentinel.sentinel_ips().first().copied()
            })
            .unwrap();
        state.set_resources(
            vec![serde_json::from_value(resource.description()).unwrap()],
            now,
        );
        state.update_relays(
            BTreeSet::new(),
            relay.description(&format!("client-{index}")),
            now,
        );

        let dst = match resource {
            Resource::Cidr => CIDR_RESOURCE_IP.into(),
            Resource::Dns => resolve(&mut state, tun.v4, sentinel, now),
        };

        Self { index, state, dst }
    }

    fn request(&self) -> IpPacket {
        packet(client_tun(self.index).v4.into(), self.dst, 50000, 443)
    }
}

/// Resolves the DNS resource through the Client's stub resolver and returns its proxy IP.
fn resolve(client: &mut ClientState, tun: Ipv4Addr, sentinel: IpAddr, now: Instant) -> IpAddr {
    let query = Query::new(DNS_RESOURCE_DOMAIN.parse().unwrap(), RecordType::A).into_bytes();
    let mut query = ip_packet::make::udp_packet(tun, sentinel, 5353, 53, &query).unwrap();

    client.handle_tun_input(&mut query, now).unwrap();
    let response = client.poll_packets().unwrap();
    let response = Response::parse(response.as_udp().unwrap().payload()).unwrap();

    response
        .records()
        .find_map(dns_types::records::extract_ip)
        .unwrap()
}

/// Returns a UDP packet of [`SIZE`] bytes.
fn packet(src: IpAddr, dst: IpAddr, sport: u16, dport: u16) -> IpPacket {
    ip_packet::make::udp_packet(src, dst, sport, dport, &[0; SIZE - 28]).unwrap()
}

/// A TURN relay on [`RELAY_SOCKET`], run by the relay's own sans-IO state.
struct Relay {
    server: relay_proto::Server<StdRng>,
    /// The ports of its allocations.
    allocations: BTreeSet<u16>,
    /// When it started, by the simulated and the system clock.
    started: (Instant, SystemTime),
}

impl Relay {
    fn new(now: Instant) -> Self {
        let mut server = relay_proto::Server::new(
            RELAY_SOCKET.ip(),
            StdRng::seed_from_u64(0),
            RELAY_SOCKET.port(),
            ALLOCATION_PORTS,
        );
        server.set_accounts([AccountId::from(Uuid::nil())]);

        Self {
            server,
            allocations: BTreeSet::new(),
            started: (now, SystemTime::now()),
        }
    }

    /// Returns the relay as the portal describes it to a Client or Gateway, with credentials for
    /// `user`: the relay keeps one allocation per username.
    fn description(&self, user: &str) -> BTreeSet<(RelayId, RelaySocket, String, String, String)> {
        let expiry = self.started.1 + Duration::from_secs(24 * 60 * 60);
        let username = format!(
            "{}:{}:{user}",
            expiry
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_secs(),
            relay_proto::auth::hash_account_id(&AccountId::from(Uuid::nil()))
        );
        let password = relay_proto::auth::generate_password(self.server.auth_secret(), &username);
        let socket = match *RELAY_SOCKET {
            SocketAddr::V4(socket) => RelaySocket::V4(socket),
            SocketAddr::V6(socket) => RelaySocket::V6(socket),
        };

        BTreeSet::from([(
            RelayId::from_u128(6),
            socket,
            username,
            password,
            "firezone".to_owned(),
        )])
    }

    /// Whether `socket` is the relay's own or one of its allocations.
    fn serves(&self, socket: SocketAddr) -> bool {
        socket == *RELAY_SOCKET
            || socket.ip() == RELAY_SOCKET.ip() && self.allocations.contains(&socket.port())
    }

    /// Handles a datagram to one of its sockets and returns the datagrams it sends in turn, as
    /// source, destination and payload.
    fn handle(
        &mut self,
        from: SocketAddr,
        to: SocketAddr,
        payload: &[u8],
        now: Instant,
    ) -> Vec<(SocketAddr, SocketAddr, Vec<u8>)> {
        let now_utc = self.started.1 + now.duration_since(self.started.0);
        let mut datagrams = Vec::new();

        if to == *RELAY_SOCKET {
            if let Some((port, peer)) =
                self.server
                    .handle_client_input(payload, ClientSocket::new(from), now, now_utc)
            {
                let from = SocketAddr::new(to.ip(), port.value());
                datagrams.push((from, peer.into_socket(), payload[4..].to_vec()));
            }
        } else if let Some((client, channel)) = self.server.handle_peer_traffic(
            payload,
            PeerSocket::new(from),
            AllocationPort::new(to.port()),
        ) {
            let mut message = vec![0; 4];
            let len = u16::try_from(payload.len()).unwrap();
            ChannelData::encode_header_to_slice(channel, len, &mut message);
            message.extend_from_slice(payload);
            datagrams.push((*RELAY_SOCKET, client.into_socket(), message));
        }

        while let Some(command) = self.server.next_command() {
            match command {
                Command::SendMessage { payload, recipient } => {
                    datagrams.push((*RELAY_SOCKET, recipient.into_socket(), payload));
                }
                Command::CreateAllocation { port, .. } => {
                    self.allocations.insert(port.value());
                }
                Command::FreeAllocation { port, .. } => {
                    self.allocations.remove(&port.value());
                }
                _ => {}
            }
        }

        datagrams
    }
}

fn ingest_token() -> IngestToken {
    serde_json::from_value(serde_json::json!(flow_tracker::TEST_INGEST_TOKEN)).unwrap()
}
