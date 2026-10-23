//! Per-packet work of a [`ClientTunnel`] / [`GatewayTunnel`] event loop, with real UDP sockets
//! and the real TUN worker threads over an in-memory device.
//!
//! The event loop runs on its own thread, kept busy by the TUN threads and a thread that stands in
//! for the peer. A busy event loop never parks, so the wall time per packet is the cost of the
//! event loop. One iteration is one packet.

#![allow(clippy::unwrap_used, clippy::wildcard_enum_match_arm)]

mod device;

use std::collections::{BTreeMap, BTreeSet};
use std::future::poll_fn;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::ops::RangeInclusive;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, LazyLock, Mutex};
use std::task::{Context, Poll};
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime};

use anyhow::ErrorExt as _;
use connlib_model::{ClientId, GatewayId, RelayId, ResourceId, SiteId};
use criterion::measurement::Measurement;
use criterion::{BenchmarkGroup, Criterion, Throughput};
use dns_types::{Query, RecordType, Response};
use ip_packet::{Ecn, IpPacket};
use rand::{SeedableRng as _, rngs::StdRng};
use relay_proto::auth::AccountId;
use relay_proto::{AllocationPort, ChannelData, ClientSocket, Command, PeerSocket};
use snownet::RelaySocket;
use socket_factory::{DatagramOut, PerfUdpSocket, SocketFactory, TcpSocket, UdpSocket};
use tunnel::{ClientState, ClientTunnel, GatewayState, GatewayTunnel, TunChannelClosed};
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
            client,
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
            gateway,
            now,
        ));
    }

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
    let event_loop = EventLoop::spawn(local.state, local.socket, now, &device);
    let arrivals = Arc::new(Arrivals::default());
    let (runtime, socket) = bind_peer(peer.socket);

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

/// Sends encrypted datagrams to the tunnel's UDP socket and counts the packets it writes to TUN.
fn inbound<M: Measurement + Copy>(
    group: &mut BenchmarkGroup<'_, M>,
    measurement: M,
    id: String,
    local: Side,
    mut peer: Side,
    now: Instant,
) -> Option<(String, Measures)> {
    let device = Device::new(&local.reads);
    let event_loop = EventLoop::spawn(local.state, local.socket, now, &device);
    let (runtime, socket) = bind_peer(peer.socket);

    #[cfg(target_os = "macos")]
    {
        device.grant(FLOW_SOCKET_PACKETS);

        let mut received = 0;
        while received < FLOW_SOCKET_PACKETS {
            received += runtime.block_on(socket.recv_from()).unwrap().len();
        }
    }

    let inputs = |packets| {
        peer.state
            .encapsulate(&peer.reads, packets, now, local.socket)
    };
    let measures = measure(
        group,
        measurement,
        id,
        &event_loop,
        device.writes(),
        inputs,
        |datagram| {
            let packets = datagram.packet.len() / datagram.segment_size;
            runtime.block_on(socket.send(datagram)).unwrap();

            packets
        },
    );

    event_loop.stop();

    measures
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

fn connect(resource: Resource, flow_logs: bool) -> (Side, Side, Instant) {
    let mut tunnel = Tunnel::established(resource, flow_logs);
    let request = tunnel.request();
    let reply = tunnel.reply();

    let client = Side {
        state: State::Client(tunnel.client),
        socket: *CLIENT_SOCKET,
        reads: request,
    };
    let gateway = Side {
        state: State::Gateway(tunnel.gateway),
        socket: *GATEWAY_SOCKET,
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

/// A tunnel's event loop, polled on its own thread until its TUN device closes.
struct EventLoop {
    thread: JoinHandle<()>,
    /// How often its thread has parked.
    parks: Arc<AtomicU64>,
    device: Device,
}

impl EventLoop {
    /// Spawns the event loop of a tunnel bound to `socket`, with its TUN workers on `device`.
    fn spawn(state: State, socket: SocketAddr, now: Instant, device: &Device) -> Self {
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
        let mut poll_next_event: Box<dyn FnMut(&mut Context<'_>) -> Poll<_> + Send> = {
            let _guard = runtime.enter();
            let tun = device.io(runtime.handle());

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

        let thread = std::thread::Builder::new()
            .name("event-loop".to_owned())
            .spawn(move || {
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

    let measures = Measures {
        packets,
        elapsed,
        parks: event_loop.parks() - before.0,
        cpu: cpu_by_thread()
            .into_iter()
            .map(|(name, after)| {
                let before = before.2.get(&name).copied().unwrap_or_default();

                (name, after.saturating_sub(before))
            })
            .collect(),
    };
    if measures.starved() {
        eprintln!(
            "Event loop thread parked {:.2} times per 1000 packets and may not have been the bottleneck",
            measures.parks_per_1k()
        );
    }

    Some((format!("{GROUP}/{id}"), measures))
}

/// What a benchmark measured besides criterion's wall time.
struct Measures {
    packets: usize,
    /// The wall time the packets took, over all of criterion's iterations.
    elapsed: Duration,
    parks: u64,
    /// The CPU time each thread spent during the benchmark.
    cpu: BTreeMap<String, Duration>,
}

impl Measures {
    /// Returns the throughput in bits per second and each stage's CPU time per packet in Bencher
    /// Metric Format.
    fn bmf(&self) -> serde_json::Value {
        let value = |value: f64| serde_json::json!({ "value": value });
        let mut bmf =
            serde_json::Map::from_iter([("throughput".to_owned(), value(self.bitrate()))]);
        for (slug, prefix) in self.active_stages() {
            bmf.insert(slug.to_owned(), value(self.cpu_ns_per_packet(prefix)));
        }

        bmf.into()
    }

    /// Whether a stand-in thread fell behind, leaving the event loop idle while packets were in
    /// flight.
    fn starved(&self) -> bool {
        self.parks_per_1k() > MAX_PARKS_PER_1K_PACKETS
    }

    fn parks_per_1k(&self) -> f64 {
        self.parks as f64 * 1000.0 / self.packets as f64
    }

    /// Returns the packets per second.
    fn throughput(&self) -> f64 {
        self.packets as f64 / self.elapsed.as_secs_f64()
    }

    /// Returns the bits per second.
    fn bitrate(&self) -> f64 {
        self.throughput() * (SIZE * 8) as f64
    }

    /// Returns the CPU nanoseconds per packet of all threads of the given stage together.
    fn cpu_ns_per_packet(&self, prefix: &str) -> f64 {
        let cpu = self
            .stage_threads(prefix)
            .map(|(_, cpu)| cpu)
            .sum::<Duration>();

        cpu.as_nanos() as f64 / self.packets as f64
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

/// Binds the peer's socket, on a runtime with a single worker thread.
fn bind_peer(socket: SocketAddr) -> (tokio::runtime::Runtime, PerfUdpSocket) {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .thread_name("peer")
        .on_thread_start(prioritize_stand_in)
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

static CLIENT_SOCKET: LazyLock<SocketAddr> = LazyLock::new(|| SocketAddr::new(local_ip(), 1111));
static GATEWAY_SOCKET: LazyLock<SocketAddr> = LazyLock::new(|| SocketAddr::new(local_ip(), 2222));

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
    relay: Relay,
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
        let relay = Relay::new(now);

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
        client.update_relays(BTreeSet::new(), relay.description("client"), now);

        let mut gateway = GatewayState::new([2; 32], now, unix_ts);
        gateway.set_flow_logs_enabled(flow_logs);
        gateway.update_tun_device(GATEWAY_TUN);
        gateway.update_relays(BTreeSet::new(), relay.description("gateway"), now);

        let dst = match resource {
            Resource::Cidr => CIDR_RESOURCE_IP.into(),
            Resource::Dns => resolve(&mut client, sentinel, now),
        };

        let mut tunnel = Self {
            client,
            gateway,
            relay,
            now,
            dst,
        };

        tunnel
            .client
            .handle_tun_input(&mut tunnel.request(), now)
            .unwrap();

        // Long enough for the TURN allocations' retransmits to be done.
        for _ in 0..600 {
            tunnel.step(resource);
        }

        tunnel
    }

    fn request(&self) -> IpPacket {
        packet(CLIENT_TUN_V4.into(), self.dst, 50000, 443)
    }

    /// Mirrors a request as the Gateway writes it to its TUN device.
    fn reply(&mut self) -> IpPacket {
        let mut request = self.request();
        let datagram = self
            .client
            .handle_tun_input(&mut request, self.now)
            .unwrap()
            .unwrap()
            .encrypt(&request)
            .unwrap();
        let decapsulation = self
            .gateway
            .handle_network_input(*GATEWAY_SOCKET, *CLIENT_SOCKET, &datagram.payload, self.now)
            .unwrap()
            .unwrap();
        let request = decapsulation
            .decrypt([&*datagram.payload])
            .map(|packet| {
                self.gateway
                    .handle_peer_input(*GATEWAY_SOCKET, *CLIENT_SOCKET, packet, self.now)
            })
            .next()
            .unwrap()
            .unwrap()
            .unwrap();
        let udp = request.as_udp().unwrap();
        let (sport, dport) = (udp.source_port(), udp.destination_port());

        packet(request.destination(), request.source(), dport, sport)
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
            self.deliver(*CLIENT_SOCKET, transmit.dst, &transmit.payload);
        }
        while let Some(transmit) = self.gateway.poll_transmit() {
            self.deliver(*GATEWAY_SOCKET, transmit.dst, &transmit.payload);
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

    fn deliver(&mut self, from: SocketAddr, to: SocketAddr, payload: &[u8]) {
        if self.relay.serves(to) {
            for (from, to, payload) in self.relay.handle(from, to, payload, self.now) {
                self.deliver(from, to, &payload);
            }

            return;
        }
        if to == *CLIENT_SOCKET
            && let Ok(Some(decapsulation)) = self
                .client
                .handle_network_input(to, from, payload, self.now)
        {
            for packet in decapsulation.decrypt([payload]) {
                let _ = self.client.handle_peer_input(to, from, packet, self.now);
            }
        }
        if to == *GATEWAY_SOCKET
            && let Ok(Some(decapsulation)) = self
                .gateway
                .handle_network_input(to, from, payload, self.now)
        {
            for packet in decapsulation.decrypt([payload]) {
                let _ = self.gateway.handle_peer_input(to, from, packet, self.now);
            }
        }
    }
}

/// Resolves the DNS resource through the Client's stub resolver and returns its proxy IP.
fn resolve(client: &mut ClientState, sentinel: IpAddr, now: Instant) -> IpAddr {
    let query = Query::new(DNS_RESOURCE_DOMAIN.parse().unwrap(), RecordType::A).into_bytes();
    let mut query = ip_packet::make::udp_packet(CLIENT_TUN_V4, sentinel, 5353, 53, &query).unwrap();

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
