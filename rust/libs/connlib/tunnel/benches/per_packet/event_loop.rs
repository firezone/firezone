//! Per-packet work of a [`ClientTunnel`] / [`GatewayTunnel`] event loop, with real UDP sockets.
//!
//! The event loop runs on its own thread, kept busy by threads that stand in for the TUN device
//! and the peer. A busy event loop never parks, so the wall time per packet is the cost of the
//! event loop.

use std::collections::BTreeSet;
use std::future::poll_fn;
use std::net::{Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::task::{Context, Poll};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::ErrorExt as _;
use divan::Bencher;
use divan::counter::ItemsCount;
use ip_packet::{Ecn, IpPacket};
use snownet::TransmitBuffer;
use socket_factory::{DatagramOut, PerfUdpSocket, SocketFactory, TcpSocket, UdpSocket};
use tun::{MAX_BATCH_SIZE, PacketBatch};
use tunnel::{ClientState, ClientTunnel, GatewayState, GatewayTunnel, TunChannelClosed};

use crate::setup::{
    RESOURCES, Resource, SIZES, Tunnel, encapsulate_on_client, encapsulate_on_gateway,
};

/// How many packets each iteration sends through the tunnel.
const PACKETS: usize = 10_000;

/// How many packets go into the tunnel ahead of those that came out of it.
///
/// Bounded so no UDP receive buffer overflows.
const IN_FLIGHT: usize = 2_048;

/// How often the event loop may park per 1000 packets.
///
/// The event loop idles between iterations. Within one, it would park about once per batch of
/// packets if a stand-in thread could not keep up.
const MAX_PARKS_PER_1K_PACKETS: f64 = 1.0;

bufferpool::buffer_pool!(static DATAGRAMS: Vec<u8> = (u16::MAX as usize, "bench-datagrams"), batch: 2);

#[divan::bench(args = RESOURCES, consts = SIZES)]
fn client_outbound<const SIZE: usize>(bencher: Bencher, resource: Resource) {
    let (client, gateway, now) = connect(resource, SIZE);

    outbound(bencher, client, gateway, now);
}

#[divan::bench(args = RESOURCES, consts = SIZES)]
fn gateway_inbound<const SIZE: usize>(bencher: Bencher, resource: Resource) {
    let (client, gateway, now) = connect(resource, SIZE);

    inbound(bencher, gateway, client, now);
}

#[divan::bench(args = RESOURCES, consts = SIZES)]
fn gateway_outbound<const SIZE: usize>(bencher: Bencher, resource: Resource) {
    let (client, gateway, now) = connect(resource, SIZE);

    outbound(bencher, gateway, client, now);
}

#[divan::bench(args = RESOURCES, consts = SIZES)]
fn client_inbound<const SIZE: usize>(bencher: Bencher, resource: Resource) {
    let (client, gateway, now) = connect(resource, SIZE);

    inbound(bencher, client, gateway, now);
}

/// Feeds packets into the tunnel's TUN channel and counts the datagrams arriving at the peer.
fn outbound(bencher: Bencher, local: Side, peer: Side, now: Instant) {
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

    let inputs = || batches(&local.reads);
    measure(bencher, &event_loop, &arrivals, inputs, |batch| {
        let packets = batch.len();
        event_loop.tun_reads.blocking_send(batch).unwrap();

        packets
    });

    event_loop.stop();
}

/// Sends encrypted datagrams to the tunnel's UDP socket and counts the packets it writes to TUN.
fn inbound(bencher: Bencher, local: Side, mut peer: Side, now: Instant) {
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

    let inputs = || peer.state.encapsulate(&peer.reads, now, local.socket);
    measure(bencher, &event_loop, &arrivals, inputs, |datagram| {
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

/// Establishes a connection between a Client on 127.0.0.1 and a Gateway on 127.0.0.2.
fn connect(resource: Resource, size: usize) -> (Side, Side, Instant) {
    let client_socket = unused_socket(Ipv4Addr::new(127, 0, 0, 1));
    let gateway_socket = unused_socket(Ipv4Addr::new(127, 0, 0, 2));
    let mut tunnel = Tunnel::established(resource, client_socket, gateway_socket);
    let request = tunnel.request(size);
    let reply = tunnel.reply(size);

    let client = Side {
        state: State::Client(tunnel.client),
        socket: client_socket,
        reads: request,
    };
    let gateway = Side {
        state: State::Gateway(tunnel.gateway),
        socket: gateway_socket,
        reads: reply,
    };

    (client, gateway, tunnel.now)
}

impl State {
    /// Returns [`PACKETS`] copies of `packet` encrypted for `dst`, in as few GSO batches as fit.
    fn encapsulate(
        &mut self,
        packet: &IpPacket,
        now: Instant,
        dst: SocketAddr,
    ) -> Vec<DatagramOut> {
        let mut transmits = TransmitBuffer::default();
        let segments = (0..PACKETS)
            .map(|_| {
                let transmit = match self {
                    State::Client(client) => {
                        encapsulate_on_client(client, packet.clone(), now, &mut transmits)
                    }
                    State::Gateway(gateway) => {
                        encapsulate_on_gateway(gateway, packet.clone(), now, &mut transmits)
                    }
                };

                transmit.payload.to_vec()
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

/// Sends the inputs, at most [`IN_FLIGHT`] packets ahead of those that arrived, and asserts that
/// the event loop did not park while packets were in flight.
///
/// `send` returns how many packets an input holds.
fn measure<T>(
    bencher: Bencher,
    event_loop: &EventLoop,
    arrivals: &Arrivals,
    inputs: impl FnMut() -> Vec<T>,
    mut send: impl FnMut(T) -> usize,
) {
    let before = (event_loop.parks(), arrivals.count());
    bencher
        .counter(ItemsCount::new(PACKETS))
        .with_inputs(inputs)
        .bench_local_values(|inputs| {
            let start = arrivals.count();
            let mut sent = 0_usize;
            for input in inputs {
                arrivals.wait_for(start + sent.saturating_sub(IN_FLIGHT));
                sent += send(input);
            }
            arrivals.wait_for(start + PACKETS);
        });
    let parks =
        (event_loop.parks() - before.0) as f64 * 1000.0 / (arrivals.count() - before.1) as f64;

    assert!(
        parks <= MAX_PARKS_PER_1K_PACKETS,
        "Event loop parked {parks:.2} times per 1k packets: a stand-in thread is the bottleneck"
    );
}

/// Returns [`PACKETS`] copies of `packet` in full batches.
fn batches(packet: &IpPacket) -> Vec<PacketBatch> {
    (0..PACKETS / MAX_BATCH_SIZE)
        .map(|_| {
            let mut batch = PacketBatch::default();
            for _ in 0..MAX_BATCH_SIZE {
                batch.try_push(packet.clone()).unwrap();
            }

            batch
        })
        .collect()
}

fn unused_socket(ip: Ipv4Addr) -> SocketAddr {
    std::net::UdpSocket::bind((ip, 0))
        .unwrap()
        .local_addr()
        .unwrap()
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
