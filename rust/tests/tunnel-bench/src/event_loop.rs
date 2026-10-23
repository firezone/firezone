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
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::task::{Context, Poll};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::ErrorExt as _;
use criterion::measurement::Measurement;
use criterion::{BenchmarkGroup, Criterion, Throughput};
use socket_factory::{PerfUdpSocket, SocketFactory, TcpSocket, UdpSocket};
use tunnel::{ClientTunnel, GatewayTunnel, TunChannelClosed};
use tunnel_bench::fixture::{RESOURCES, SIZE, Side, State, connect};

use crate::measure::Stage;
use crate::thread_cpu::thread_cpu_times;
use device::Device;

const GROUP: &str = "event_loop";

/// The file to write the measures of all benchmarks to in Bencher Metric Format, if set.
///
/// An environment variable because criterion parses the whole command line itself.
const BENCHER_JSON_ENV: &str = "TUNNEL_BENCH_JSON";

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
