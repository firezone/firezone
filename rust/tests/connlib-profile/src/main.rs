//! Measures connlib's per-packet main-thread work in memory.
//!
//! A Client and a Gateway are connected through a simulated relay (ICE settles on the direct
//! path), then a fixed load is pumped through their sans-IO states in TUN-sized batches while each
//! step of the data path is timed separately.
//!
//! By default everything runs inline on one thread. `--threaded` moves the work that connlib does
//! off its main thread onto other threads, so the main thread sees cross-core buffers and the real
//! channels: a TUN reader and writer (`tun`'s channels), the crypto workers (`tunnel`'s `Crypto`),
//! and a UDP thread that copies each datagram into a fresh receive buffer, as `recvmmsg` would.
#![allow(clippy::unwrap_used, clippy::print_stdout, clippy::print_stderr)]

use std::{
    collections::{BTreeSet, VecDeque},
    hint::black_box,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4},
    ops::ControlFlow,
    task::{Context, Poll, Waker},
    time::{Duration, Instant, SystemTime},
};

use bufferpool::{Buffer, BufferPool};
use clap::{Parser, ValueEnum};
use connlib_model::{ClientId, ClientOrGatewayId, GatewayId, RelayId, ResourceId, SiteId};
use ip_packet::{Ecn, IpPacket, make::TcpFlags};
use rand::{SeedableRng as _, rngs::StdRng};
use relay_proto::{AllocationPort, ChannelData, ClientSocket, IpStack, PeerSocket};
use secrecy::SecretBox;
use snownet::{DecryptedPacket, EncryptedPacket, RelaySocket, Transmit, TransmitBuffer};
use tokio::sync::mpsc;
use tun::PacketBatch;
use tunnel::{
    ClientEvent, ClientState, GatewayEvent, GatewayState, IpConfig,
    messages::{IceCredentials, Interface, Key, gateway},
    profiling::{Crypto, PendingDatagram, Received, UdpGsoQueue},
};

const CLIENT_SOCKET: SocketAddr = sock(10, 0, 0, 1, 50000);
const GATEWAY_SOCKET: SocketAddr = sock(10, 0, 0, 2, 50001);
const RELAY_IP: Ipv4Addr = Ipv4Addr::new(10, 0, 0, 3);
const RELAY_PORT: u16 = 3478;

const CLIENT_TUN_V4: Ipv4Addr = Ipv4Addr::new(100, 64, 0, 1);
const CLIENT_TUN_V6: Ipv6Addr = Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 1);
const GATEWAY_TUN_V4: Ipv4Addr = Ipv4Addr::new(100, 64, 0, 2);
const GATEWAY_TUN_V6: Ipv6Addr = Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 2);

const RESOURCE_HOST: Ipv4Addr = Ipv4Addr::new(172, 20, 0, 10);
const CLIENT_PORT: u16 = 40000;
const RESOURCE_PORT: u16 = 5201;

const CLIENT_ID: ClientId = ClientId::from_u128(1);
const GATEWAY_ID: GatewayId = GatewayId::from_u128(2);
const RESOURCE_ID: ResourceId = ResourceId::from_u128(3);
const SITE_ID: SiteId = SiteId::from_u128(4);
const RELAY_ID: RelayId = RelayId::from_u128(5);

const fn sock(a: u8, b: u8, c: u8, d: u8, port: u16) -> SocketAddr {
    SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(a, b, c, d), port))
}

#[derive(Parser)]
struct Cli {
    /// Number of TUN batches to pump per direction.
    #[arg(long, default_value_t = 20_000)]
    batches: usize,

    /// Packets per TUN batch.
    #[arg(long, default_value_t = 100)]
    batch_size: usize,

    /// Total IP packet length (connlib's tunnel MTU is 1280).
    #[arg(long, default_value_t = 1280)]
    packet_len: usize,

    #[arg(long, value_enum, default_value_t = Proto::Udp)]
    proto: Proto,

    /// Which direction(s) to pump.
    #[arg(long, value_enum, default_value_t = Direction::Both)]
    direction: Direction,

    /// Enables flow logs on both sides.
    #[arg(long)]
    flow_logs: bool,

    /// Installs a `fmt` subscriber with this filter, writing to a sink.
    #[arg(long)]
    tracing: Option<String>,

    /// Runs TUN, UDP and crypto work on other threads, as connlib does.
    #[arg(long)]
    threaded: bool,
}

#[derive(Clone, Copy, ValueEnum, PartialEq, Eq)]
enum Proto {
    Udp,
    Tcp,
}

#[derive(Clone, Copy, ValueEnum, PartialEq, Eq)]
enum Direction {
    Both,
    /// Client TUN -> Gateway TUN.
    Up,
    /// Gateway TUN -> Client TUN.
    Down,
}

fn main() {
    let cli = Cli::parse();

    let _guard = cli.tracing.as_ref().map(|filter| {
        use tracing_subscriber::{
            EnvFilter, Layer as _, layer::SubscriberExt as _, util::SubscriberInitExt as _,
        };

        tracing_subscriber::registry()
            .with(
                tracing_subscriber::fmt::layer()
                    .with_writer(std::io::sink)
                    .with_filter(EnvFilter::new(filter)),
            )
            .set_default()
    });

    let mut sim = Sim::new();
    sim.client.set_flow_logs_enabled(cli.flow_logs);
    sim.gateway.set_flow_logs_enabled(cli.flow_logs);
    sim.establish(cli.proto);

    println!(
        "connection path: {:?}",
        sim.client
            .connection_path(ClientOrGatewayId::Gateway(GATEWAY_ID))
            .unwrap()
    );

    println!(
        "sizes: EncryptedPacket {} B, DecryptedPacket {} B, SealJob {} B, IpPacket {} B",
        size_of::<EncryptedPacket<ClientId>>(),
        size_of::<DecryptedPacket<ClientId>>(),
        size_of::<snownet::SealJob>(),
        size_of::<IpPacket>(),
    );

    let up = cli.direction != Direction::Down;
    let down = cli.direction != Direction::Up;

    let mut up_pipe = Pipe::new(
        Template::new(cli.proto, cli.packet_len, true),
        cli.batch_size,
        CLIENT_SOCKET,
        cli.threaded,
    );
    let mut down_pipe = Pipe::new(
        Template::new(cli.proto, cli.packet_len, false),
        cli.batch_size,
        GATEWAY_SOCKET,
        cli.threaded,
    );

    // Only now: threads spawned so far, including the crypto workers, must not inherit the pinning.
    if cli.threaded {
        pin_to_cpu(0);
    }

    // Warm up buffer pools and caches.
    for _ in 0..200 {
        if up {
            up_pipe.pump(&mut sim.client, &mut sim.gateway, sim.now, &mut Stats::default());
            sim.drain_control();
        }
        if down {
            down_pipe.pump(&mut sim.gateway, &mut sim.client, sim.now, &mut Stats::default());
            sim.drain_control();
        }
    }

    let mut stats_up = Stats::default();
    let mut stats_down = Stats::default();

    let started = Instant::now();
    for _ in 0..cli.batches {
        if up {
            let now = sim.tick();
            up_pipe.pump(&mut sim.client, &mut sim.gateway, now, &mut stats_up);
            sim.drain_control();
        }
        if down {
            let now = sim.tick();
            down_pipe.pump(&mut sim.gateway, &mut sim.client, now, &mut stats_down);
            sim.drain_control();
        }
    }
    let elapsed = started.elapsed();

    if up {
        stats_up.print("UP (client TUN -> gateway TUN)", "client", "gateway");
    }
    if down {
        stats_down.print("DOWN (gateway TUN -> client TUN)", "gateway", "client");
    }
    println!("wall: {elapsed:?}");
}

/// The sans-IO entry points of one side, so the pump can be shared by both directions.
trait Peer {
    type Id: Send + 'static;

    fn tun_input(&mut self, packet: IpPacket, now: Instant, queue: &mut UdpGsoQueue);
    fn network_input(
        &mut self,
        local: SocketAddr,
        from: SocketAddr,
        packet: &[u8],
        now: Instant,
    ) -> Option<EncryptedPacket<Self::Id>>;
    fn decrypted_input(
        &mut self,
        local: SocketAddr,
        from: SocketAddr,
        packet: DecryptedPacket<Self::Id>,
        now: Instant,
    ) -> Option<IpPacket>;
    fn poll_and_handle_timeout(&mut self, now: Instant);
}

impl Peer for ClientState {
    type Id = ClientOrGatewayId;

    fn tun_input(&mut self, packet: IpPacket, now: Instant, queue: &mut UdpGsoQueue) {
        self.handle_tun_input(packet, now, queue).unwrap();
    }

    fn network_input(
        &mut self,
        local: SocketAddr,
        from: SocketAddr,
        packet: &[u8],
        now: Instant,
    ) -> Option<EncryptedPacket<Self::Id>> {
        self.handle_network_input(local, from, packet, now).unwrap()
    }

    fn decrypted_input(
        &mut self,
        local: SocketAddr,
        from: SocketAddr,
        packet: DecryptedPacket<Self::Id>,
        now: Instant,
    ) -> Option<IpPacket> {
        self.handle_decrypted_network_input(local, from, packet, now)
            .unwrap()
    }

    fn poll_and_handle_timeout(&mut self, now: Instant) {
        black_box(self.poll_timeout());
        self.handle_timeout(now);
    }
}

impl Peer for GatewayState {
    type Id = ClientId;

    fn tun_input(&mut self, packet: IpPacket, now: Instant, queue: &mut UdpGsoQueue) {
        self.handle_tun_input(packet, now, queue).unwrap();
    }

    fn network_input(
        &mut self,
        local: SocketAddr,
        from: SocketAddr,
        packet: &[u8],
        now: Instant,
    ) -> Option<EncryptedPacket<Self::Id>> {
        self.handle_network_input(local, from, packet, now).unwrap()
    }

    fn decrypted_input(
        &mut self,
        local: SocketAddr,
        from: SocketAddr,
        packet: DecryptedPacket<Self::Id>,
        now: Instant,
    ) -> Option<IpPacket> {
        self.handle_decrypted_network_input(local, from, packet, now)
            .unwrap()
    }

    fn poll_and_handle_timeout(&mut self, now: Instant) {
        black_box(self.poll_timeout());
        self.handle_timeout(now);
    }
}

/// A packet that every batch clones, as the TUN thread would read it.
struct Template {
    packet: IpPacket,
}

impl Template {
    fn new(proto: Proto, len: usize, up: bool) -> Self {
        let (src, dst, sport, dport) = if up {
            (
                IpAddr::from(CLIENT_TUN_V4),
                IpAddr::from(RESOURCE_HOST),
                CLIENT_PORT,
                RESOURCE_PORT,
            )
        } else {
            (
                IpAddr::from(RESOURCE_HOST),
                IpAddr::from(CLIENT_TUN_V4),
                RESOURCE_PORT,
                CLIENT_PORT,
            )
        };

        let packet = match proto {
            Proto::Udp => {
                ip_packet::make::udp_packet(src, dst, sport, dport, &vec![0xab; len - 28]).unwrap()
            }
            Proto::Tcp => ip_packet::make::tcp_packet(
                src,
                dst,
                sport,
                dport,
                TcpFlags {
                    ack: true,
                    ..Default::default()
                },
                &vec![0xab; len - 40],
            )
            .unwrap(),
        };
        assert_eq!(packet.packet().len(), len);

        Self { packet }
    }

    fn batch(&self, n: usize) -> PacketBatch {
        let mut batch = PacketBatch::default();
        for _ in 0..n {
            batch.try_push(self.packet.clone()).unwrap();
        }
        batch
    }
}

/// A datagram as handed to the receiving side: local, from, payload and GSO segment size.
type Datagram = (SocketAddr, SocketAddr, Buffer<Vec<u8>>, usize);

/// One direction of the data path: sender TUN -> sender main -> network -> receiver main -> receiver TUN.
struct Pipe<SId, RId> {
    template: Template,
    batch_size: usize,
    src: SocketAddr,
    queue: UdpGsoQueue,
    threads: Option<Threads<SId, RId>>,
}

/// Stand-ins for the threads that surround connlib's main thread.
struct Threads<SId, RId> {
    tun_in: tun::InboundRx,
    tun_out: tun::OutboundTx,
    udp_send: mpsc::Sender<Vec<Datagram>>,
    udp_recv: mpsc::Receiver<Vec<Datagram>>,
    sender_crypto: Crypto<SId>,
    receiver_crypto: Crypto<RId>,
}

impl<SId, RId> Pipe<SId, RId>
where
    SId: Send + 'static,
    RId: Send + 'static,
{
    fn new(template: Template, batch_size: usize, src: SocketAddr, threaded: bool) -> Self {
        let threads = threaded.then(|| {
            let (tun_in_tx, tun_in) = tun::inbound_channel();
            let (tun_out, mut tun_out_rx) = tun::outbound_channel();
            let (udp_send, mut udp_send_rx) = mpsc::channel::<Vec<Datagram>>(64);
            let (udp_recv_tx, udp_recv) = mpsc::channel::<Vec<Datagram>>(8);

            // TUN reader: keeps the channel full of freshly written packets.
            let packet = template.packet.clone();
            spawn("tun-reader", move || {
                let template = Template { packet };
                while tun_in_tx.blocking_send(template.batch(batch_size)).is_ok() {}
            });

            // TUN writer: drops the received packets, returning their buffers from this thread.
            spawn("tun-writer", move || while tun_out_rx.blocking_recv().is_some() {});

            // UDP: the sender's send thread and the receiver's `recvmmsg` copy, in one.
            spawn("udp", move || {
                let pool = BufferPool::<Vec<u8>>::new(u16::MAX as usize, "udp-recv");

                while let Some(datagrams) = udp_send_rx.blocking_recv() {
                    let received = datagrams
                        .into_iter()
                        .map(|(local, from, payload, segment_size)| {
                            (local, from, pool.pull_initialised(&payload), segment_size)
                        })
                        .collect();

                    if udp_recv_tx.blocking_send(received).is_err() {
                        return;
                    }
                }
            });

            Threads {
                tun_in,
                tun_out,
                udp_send,
                udp_recv,
                sender_crypto: Crypto::new(),
                receiver_crypto: Crypto::new(),
            }
        });

        Self {
            template,
            batch_size,
            src,
            queue: UdpGsoQueue::new(),
            threads,
        }
    }

    fn pump<S, R>(&mut self, sender: &mut S, receiver: &mut R, now: Instant, stats: &mut Stats)
    where
        S: Peer<Id = SId>,
        R: Peer<Id = RId>,
    {
        let mut timer = Timer::new();
        let mut cx = Context::from_waker(Waker::noop());
        let n = self.batch_size;

        // Sender: TUN -> sealed datagrams.
        let mut batch = match self.threads.as_mut() {
            None => {
                let batch = make_batch(&self.template, n);
                stats.make_batch += timer.lap();
                batch
            }
            Some(threads) => {
                let batch = loop {
                    if let Poll::Ready(batch) = threads.tun_in.poll_recv(&mut cx) {
                        break batch.unwrap();
                    }
                    timer.lap(); // Don't count waiting for the TUN reader.
                };
                let lap = timer.lap();
                stats.chan += lap;
                stats.detail[0] += lap;
                batch
            }
        };
        tun_input(sender, &mut batch, now, &mut self.queue);
        stats.send_tun_input += timer.lap();
        drop(batch);
        let pending = pop_queue(&mut self.queue);
        stats.send_pop += timer.lap();

        let datagrams = match self.threads.as_mut() {
            None => {
                let sealed = seal(pending, self.src);
                stats.send_seal += timer.lap();
                sealed
            }
            Some(threads) => {
                let num = pending.len();
                submit_seals(&mut threads.sender_crypto, pending);
                let lap = timer.lap();
                stats.send_crypto_channels += lap;
                stats.detail[1] += lap;
                spin(CRYPTO_WAIT);
                timer.lap();
                let mut sealed = Vec::with_capacity(num);
                let mut collect = Duration::ZERO;
                let mut polls = 0;
                while sealed.len() < num {
                    let before = sealed.len();
                    threads.sender_crypto.poll_completed(&mut cx);
                    while let Some(d) = threads.sender_crypto.pop_sealed() {
                        sealed.push((d.dst, d.src.unwrap_or(self.src), d.packet, d.segment_size));
                    }
                    let lap = timer.lap();
                    if sealed.len() > before {
                        collect += lap;
                    } else {
                        polls += 1; // Still waiting for the workers: not counted.
                    }
                }
                stats.send_crypto_channels += collect;
                stats.detail[2] += collect;
                stats.extra_polls += polls;
                sealed
            }
        };
        sender.poll_and_handle_timeout(now);
        stats.send_timeout += timer.lap();
        let num_datagrams = datagrams.len();

        // Receiver: datagrams -> IP packets.
        let datagrams = match self.threads.as_mut() {
            None => datagrams,
            Some(threads) => {
                threads.udp_send.try_send(datagrams).ok().unwrap();
                let lap = timer.lap();
                stats.chan += lap;
                stats.detail[3] += lap;
                while threads.udp_recv.is_empty() {
                    std::hint::spin_loop();
                }
                timer.lap();
                loop {
                    if let Poll::Ready(d) = threads.udp_recv.poll_recv(&mut cx) {
                        break d.unwrap();
                    }
                }
            }
        };
        let lap = timer.lap();
        stats.chan += lap;
        stats.detail[4] += lap;
        let encrypted = network_input(receiver, &datagrams, now);
        stats.recv_network_input += timer.lap();
        drop(datagrams);

        let decrypted = match self.threads.as_mut() {
            None => {
                let decrypted = open(encrypted);
                stats.recv_open += timer.lap();
                decrypted
            }
            Some(threads) => {
                threads.receiver_crypto.open(encrypted);
                let lap = timer.lap();
                stats.recv_crypto_channels += lap;
                stats.detail[5] += lap;
                spin(CRYPTO_WAIT);
                timer.lap();
                let mut polls = 0;
                let decrypted = loop {
                    threads.receiver_crypto.poll_completed(&mut cx);
                    if let Some(d) = threads.receiver_crypto.pop_opened() {
                        break d;
                    }
                    timer.lap(); // Still waiting for the workers: not counted.
                    polls += 1;
                };
                let lap = timer.lap();
                stats.recv_crypto_channels += lap;
                stats.detail[6] += lap;
                stats.extra_polls += polls;
                decrypted
            }
        };
        let packets = decrypted_input(receiver, decrypted, now);
        stats.recv_decrypted_input += timer.lap();
        let received = packets.len();
        match self.threads.as_mut() {
            None => {
                drop_packets(packets);
                stats.recv_drop += timer.lap();
            }
            Some(threads) => {
                threads.tun_out.try_send(packets).ok().unwrap();
                let lap = timer.lap();
                stats.chan += lap;
                stats.detail[7] += lap;
            }
        }
        receiver.poll_and_handle_timeout(now);
        stats.recv_timeout += timer.lap();

        assert_eq!(received, n, "lost packets");
        stats.packets += n as u64;
        stats.datagrams += num_datagrams as u64;
    }
}

fn spawn(name: &str, f: impl FnOnce() + Send + 'static) {
    std::thread::Builder::new()
        .name(name.to_owned())
        .spawn(f)
        .unwrap();
}

struct Timer(Instant);

impl Timer {
    fn new() -> Self {
        Self(Instant::now())
    }

    fn lap(&mut self) -> Duration {
        let now = Instant::now();
        let lap = now - self.0;
        self.0 = now;
        lap
    }
}

/// How long to wait for the crypto workers before collecting their results.
///
/// Long enough for a 64-segment batch, so collecting does not include waiting.
const CRYPTO_WAIT: Duration = Duration::from_micros(100);

/// Waits for another thread without yielding the core, like a busy event loop would.
fn spin(duration: Duration) {
    let until = Instant::now() + duration;
    while Instant::now() < until {
        std::hint::spin_loop();
    }
}

fn pin_to_cpu(cpu: usize) {
    // SAFETY: `set` is a valid, zeroed `cpu_set_t` that outlives the call.
    unsafe {
        let mut set = std::mem::zeroed::<libc::cpu_set_t>();
        libc::CPU_SET(cpu, &mut set);
        libc::sched_setaffinity(0, size_of::<libc::cpu_set_t>(), &set);
    }
}

const DETAIL: [&str; 8] = [
    "  sender: TUN channel recv",
    "  sender: seal submit",
    "  sender: seal collect",
    "  sender: UDP channel send",
    "receiver: UDP channel recv",
    "receiver: open submit",
    "receiver: open collect",
    "receiver: TUN channel send",
];

#[derive(Default)]
struct Stats {
    packets: u64,
    datagrams: u64,

    /// Threaded mode: per channel / hand-off operation, see [`DETAIL`].
    detail: [Duration; 8],
    /// Threaded mode: crypto polls that found the workers not done yet.
    extra_polls: u64,

    /// Cloning the template batch (inline mode only; the TUN thread's work).
    make_batch: Duration,
    /// Channel operations to and from the TUN and UDP threads (threaded mode only).
    chan: Duration,
    /// Sender: `handle_tun_input` into the `UdpGsoQueue` (no AEAD).
    send_tun_input: Duration,
    /// Sender: popping `PendingDatagram`s off the queue.
    send_pop: Duration,
    /// Sender: sealing inline (AEAD).
    send_seal: Duration,
    /// Sender: handing batches to the crypto workers and collecting them (threaded mode only).
    send_crypto_channels: Duration,
    /// Sender: `poll_timeout` + `handle_timeout`, once per batch as the event loop does.
    send_timeout: Duration,
    /// Receiver: `handle_network_input` per segment (phase 1, no AEAD).
    recv_network_input: Duration,
    /// Receiver: opening inline (AEAD).
    recv_open: Duration,
    /// Receiver: handing batches to the crypto workers and collecting them (threaded mode only).
    recv_crypto_channels: Duration,
    /// Receiver: `handle_decrypted_network_input` (phase 2).
    recv_decrypted_input: Duration,
    /// Receiver: dropping the resulting IP packets (inline mode; normally the TUN thread's work).
    recv_drop: Duration,
    /// Receiver: `poll_timeout` + `handle_timeout`, once per batch.
    recv_timeout: Duration,
}

impl Stats {
    fn print(&self, title: &str, sender: &str, receiver: &str) {
        let per = |d: Duration| d.as_nanos() as f64 / self.packets as f64;
        let line = |side: &str, what: &str, d: Duration| {
            println!("  {side:>8} {what:<34} {:8.1} ns/pkt", per(d));
        };

        let send_main =
            self.send_tun_input + self.send_pop + self.send_timeout + self.send_crypto_channels;
        let recv_main = self.recv_network_input
            + self.recv_decrypted_input
            + self.recv_timeout
            + self.recv_crypto_channels;

        println!(
            "== {title}: {} packets in {} datagrams",
            self.packets, self.datagrams
        );
        line("", "(make batch: TUN-thread work)", self.make_batch);
        line("", "channels to TUN / UDP threads", self.chan);
        line(sender, "handle_tun_input", self.send_tun_input);
        line(sender, "gso_queue.pop", self.send_pop);
        line(sender, "crypto worker hand-off", self.send_crypto_channels);
        line(sender, "poll_timeout + handle_timeout", self.send_timeout);
        line(sender, "seal inline (AEAD)", self.send_seal);
        line(sender, "MAIN THREAD, NO AEAD", send_main);
        line(sender, "MAIN THREAD + inline AEAD", send_main + self.send_seal);
        line(receiver, "handle_network_input", self.recv_network_input);
        line(receiver, "crypto worker hand-off", self.recv_crypto_channels);
        line(receiver, "handle_decrypted_network_input", self.recv_decrypted_input);
        line(receiver, "poll_timeout + handle_timeout", self.recv_timeout);
        line(receiver, "open inline (AEAD)", self.recv_open);
        line(receiver, "(drop IP packets: TUN-thread work)", self.recv_drop);
        line(receiver, "MAIN THREAD, NO AEAD", recv_main);
        line(receiver, "MAIN THREAD + inline AEAD", recv_main + self.recv_open);

        if self.detail.iter().any(|d| !d.is_zero()) {
            for (label, d) in DETAIL.iter().zip(self.detail) {
                line("", label, d);
            }
            println!("  crypto polls that came too early: {}", self.extra_polls);
        }
    }
}

#[inline(never)]
fn make_batch(template: &Template, n: usize) -> PacketBatch {
    template.batch(n)
}

#[inline(never)]
fn tun_input<S: Peer>(sender: &mut S, batch: &mut PacketBatch, now: Instant, queue: &mut UdpGsoQueue) {
    for packet in batch.drain() {
        sender.tun_input(packet, now, queue);
    }
}

#[inline(never)]
fn pop_queue(queue: &mut UdpGsoQueue) -> Vec<PendingDatagram> {
    std::iter::from_fn(|| queue.pop()).collect()
}

#[inline(never)]
fn seal(pending: Vec<PendingDatagram>, src: SocketAddr) -> Vec<Datagram> {
    pending
        .into_iter()
        .map(|p| {
            let d = p.seal();
            (d.dst, d.src.unwrap_or(src), d.packet, d.segment_size)
        })
        .collect()
}

#[inline(never)]
fn submit_seals<T: Send + 'static>(crypto: &mut Crypto<T>, pending: Vec<PendingDatagram>) {
    for datagram in pending {
        assert!(crypto.can_seal());
        crypto.seal(datagram);
    }
}

#[inline(never)]
fn network_input<R: Peer>(
    receiver: &mut R,
    datagrams: &[Datagram],
    now: Instant,
) -> Vec<Received<EncryptedPacket<R::Id>>> {
    let mut out = Vec::with_capacity(128);
    for (local, from, buffer, segment_size) in datagrams {
        for segment in buffer.chunks(*segment_size) {
            if let Some(packet) = receiver.network_input(*local, *from, segment, now) {
                out.push(Received {
                    local: *local,
                    from: *from,
                    ecn: Ecn::NonEct,
                    packet,
                });
            }
        }
    }
    out
}

#[inline(never)]
fn open<T>(encrypted: Vec<Received<EncryptedPacket<T>>>) -> Vec<Received<DecryptedPacket<T>>> {
    encrypted
        .into_iter()
        .map(|r| Received {
            local: r.local,
            from: r.from,
            ecn: r.ecn,
            packet: r.packet.decrypt(),
        })
        .collect()
}

#[inline(never)]
fn decrypted_input<R: Peer>(
    receiver: &mut R,
    decrypted: Vec<Received<DecryptedPacket<R::Id>>>,
    now: Instant,
) -> PacketBatch {
    let mut out = PacketBatch::default();
    for r in decrypted {
        if let Some(packet) = receiver.decrypted_input(r.local, r.from, r.packet, now) {
            out.try_push(packet.with_ecn_from_transport(r.ecn)).unwrap();
        }
    }
    out
}

#[inline(never)]
fn drop_packets(packets: PacketBatch) {
    black_box(&packets);
    drop(packets);
}

/// Client, Gateway and relay, wired together by an in-memory network.
struct Sim {
    client: ClientState,
    gateway: GatewayState,
    relay: relay_proto::Server<StdRng>,

    /// Simulated time during setup; afterwards follows real time from `real_base`.
    now: Instant,
    real_base: Option<(Instant, Instant)>,
    started: Instant,
    created_at: SystemTime,

    network: VecDeque<Transmit>,
    client_setup: TransmitBuffer,
    gateway_setup: TransmitBuffer,
    relay_pool: BufferPool<Vec<u8>>,
    gateway_received: usize,
    client_received: usize,
}

impl Sim {
    fn new() -> Self {
        let now = Instant::now();
        let created_at = SystemTime::now();
        let unix_ts = created_at.duration_since(SystemTime::UNIX_EPOCH).unwrap();

        let mut client = ClientState::new([1; 32], BTreeSet::new(), false, now, unix_ts);
        client.update_interface_config(Interface {
            ipv4: CLIENT_TUN_V4,
            ipv6: CLIENT_TUN_V6,
            upstream_dns: Vec::new(),
            upstream_do53: Vec::new(),
            upstream_doh: Vec::new(),
            search_domain: None,
        });
        client.set_resources(
            vec![
                serde_json::from_value(serde_json::json!({
                    "type": "cidr",
                    "id": RESOURCE_ID,
                    "address": "172.20.0.0/24",
                    "name": "iperf",
                    "address_description": null,
                    "sites": [{ "id": SITE_ID, "name": "site" }],
                    "filters": [],
                }))
                .unwrap(),
            ],
            now,
        );

        let mut gateway = GatewayState::new([2; 32], now, unix_ts);
        gateway.update_tun_device(IpConfig {
            v4: GATEWAY_TUN_V4,
            v6: GATEWAY_TUN_V6,
        });

        let mut relay = relay_proto::Server::new(
            IpStack::Ip4(RELAY_IP),
            StdRng::seed_from_u64(0),
            RELAY_PORT,
            49152..=65535,
        );
        relay.set_accounts([relay_proto::auth::AccountId::from(uuid::Uuid::nil())]);

        let mut this = Self {
            client,
            gateway,
            relay,
            now,
            real_base: None,
            started: now,
            created_at,
            network: VecDeque::new(),
            client_setup: TransmitBuffer::new(),
            gateway_setup: TransmitBuffer::new(),
            relay_pool: BufferPool::new(2048, "relay"),
            gateway_received: 0,
            client_received: 0,
        };

        let client_relay = this.relay_credentials("client");
        let gateway_relay = this.relay_credentials("gateway");
        this.client
            .update_relays(BTreeSet::new(), BTreeSet::from([client_relay]), now);
        this.gateway
            .update_relays(BTreeSet::new(), BTreeSet::from([gateway_relay]), now);

        this
    }

    fn relay_credentials(&self, username: &str) -> (RelayId, RelaySocket, String, String, String) {
        let secs = (self.created_at + Duration::from_secs(24 * 60 * 60))
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let username = format!(
            "{secs}:{}:{username}",
            relay_proto::auth::hash_account_id(&relay_proto::auth::AccountId::from(
                uuid::Uuid::nil()
            ))
        );
        let password = relay_proto::auth::generate_password(self.relay.auth_secret(), &username);

        (
            RELAY_ID,
            RelaySocket::V4(SocketAddrV4::new(RELAY_IP, RELAY_PORT)),
            username,
            password,
            "firezone".to_owned(),
        )
    }

    /// Sends a first packet each way and drives everything until the connection has settled.
    fn establish(&mut self, proto: Proto) {
        self.advance(Duration::from_secs(2));

        let (first, reply) = match proto {
            Proto::Udp => (
                ip_packet::make::udp_packet(
                    CLIENT_TUN_V4,
                    RESOURCE_HOST,
                    CLIENT_PORT,
                    RESOURCE_PORT,
                    b"hello",
                ),
                ip_packet::make::udp_packet(
                    RESOURCE_HOST,
                    CLIENT_TUN_V4,
                    RESOURCE_PORT,
                    CLIENT_PORT,
                    b"hello",
                ),
            ),
            Proto::Tcp => (
                ip_packet::make::tcp_packet(
                    CLIENT_TUN_V4,
                    RESOURCE_HOST,
                    CLIENT_PORT,
                    RESOURCE_PORT,
                    TcpFlags {
                        syn: true,
                        ..Default::default()
                    },
                    &[],
                ),
                ip_packet::make::tcp_packet(
                    RESOURCE_HOST,
                    CLIENT_TUN_V4,
                    RESOURCE_PORT,
                    CLIENT_PORT,
                    TcpFlags {
                        syn: true,
                        ack: true,
                        ..Default::default()
                    },
                    &[],
                ),
            ),
        };

        self.client
            .handle_tun_input(first.unwrap(), self.now, &mut self.client_setup)
            .unwrap();
        self.advance(Duration::from_secs(10));
        assert!(self.gateway_received > 0, "first packet did not arrive");

        self.gateway
            .handle_tun_input(reply.unwrap(), self.now, &mut self.gateway_setup)
            .unwrap();
        self.advance(Duration::from_secs(10));
        assert!(self.client_received > 0, "reply did not arrive");

        // Let ICE settle on its final pair.
        self.advance(Duration::from_secs(30));

        self.real_base = Some((Instant::now(), self.now));
    }

    fn advance(&mut self, duration: Duration) {
        let cut_off = self.now + duration;

        loop {
            if self.step().is_continue() {
                continue;
            }

            let next = [
                self.client.poll_timeout().map(|(t, _)| t),
                self.gateway.poll_timeout().map(|(t, _)| t),
                self.relay.poll_timeout(),
            ]
            .into_iter()
            .flatten()
            .min();

            let Some(next) = next.filter(|t| *t <= cut_off) else {
                self.now = cut_off;
                return;
            };

            self.now = self.now.max(next);
            self.client.handle_timeout(self.now);
            self.gateway.handle_timeout(self.now);
            if self.relay.poll_timeout().is_some_and(|t| t <= self.now) {
                self.relay.handle_timeout(self.now);
            }
        }
    }

    /// The current time after setup: simulated base plus elapsed real time.
    fn tick(&mut self) -> Instant {
        let (real, sim) = self.real_base.unwrap();
        self.now = sim + real.elapsed();

        self.now
    }

    /// Delivers control traffic (keepalives, STUN, handshakes) produced while pumping.
    fn drain_control(&mut self) {
        while self.step().is_continue() {}
    }

    /// Makes one unit of progress, if there is any to make.
    fn step(&mut self) -> ControlFlow<()> {
        let now = self.now;

        if let Some(event) = self.client.poll_event() {
            self.on_client_event(event);
            return ControlFlow::Continue(());
        }
        if let Some(event) = self.gateway.poll_event() {
            self.on_gateway_event(event);
            return ControlFlow::Continue(());
        }
        if let Some(command) = self.relay.next_command() {
            if let relay_proto::Command::SendMessage { payload, recipient } = command {
                self.network.push_back(Transmit {
                    src: Some(SocketAddr::new(RELAY_IP.into(), RELAY_PORT)),
                    dst: recipient.into_socket(),
                    payload: self.relay_pool.pull_initialised(&payload),
                    ecn: Ecn::NonEct,
                });
            }
            return ControlFlow::Continue(());
        }
        while self.client.poll_packets().is_some() {}
        while self.client.poll_dns_queries().is_some() {}

        let mut progress = false;
        while let Some(t) = self
            .client
            .poll_transmit()
            .or_else(|| self.client_setup.poll_transmit())
        {
            self.network.push_back(with_src(t, CLIENT_SOCKET));
            progress = true;
        }
        while let Some(t) = self
            .gateway
            .poll_transmit()
            .or_else(|| self.gateway_setup.poll_transmit())
        {
            self.network.push_back(with_src(t, GATEWAY_SOCKET));
            progress = true;
        }
        if progress {
            return ControlFlow::Continue(());
        }

        let Some(transmit) = self.network.pop_front() else {
            return ControlFlow::Break(());
        };
        self.dispatch(transmit, now);

        ControlFlow::Continue(())
    }

    fn on_gateway_event(&mut self, event: GatewayEvent) {
        if let GatewayEvent::AddedIceCandidates { candidates, .. } = event {
            for c in candidates {
                self.client.add_ice_candidate(GATEWAY_ID, c, self.now);
            }
        }
    }

    fn on_client_event(&mut self, event: ClientEvent) {
        let now = self.now;

        match event {
            ClientEvent::AddedIceCandidates { candidates, .. } => {
                for c in candidates {
                    self.gateway.add_ice_candidate(CLIENT_ID, c, now);
                }
            }
            ClientEvent::RequestAccess { .. } => {
                let psk = || SecretBox::init_with(|| Key([7; 32]));
                let client_ice = IceCredentials {
                    username: "cli1".to_owned(),
                    password: "clientpassword".to_owned(),
                };
                let gateway_ice = IceCredentials {
                    username: "gat1".to_owned(),
                    password: "gatewaypasswd".to_owned(),
                };

                self.gateway
                    .create_authorization(
                        gateway::Client {
                            id: CLIENT_ID,
                            public_key: self.client.public_key().into(),
                            preshared_key: psk(),
                            ipv4: CLIENT_TUN_V4,
                            ipv6: CLIENT_TUN_V6,
                        },
                        client_ice.clone(),
                        gateway_ice.clone(),
                        None,
                        gateway::ResourceDescription::Cidr(gateway::ResourceDescriptionCidr {
                            id: RESOURCE_ID,
                            address: "172.20.0.0/24".parse().unwrap(),
                            name: "iperf".to_owned(),
                            filters: Vec::new(),
                        }),
                        false,
                        now,
                        ingest_token(),
                    )
                    .unwrap();
                while let Some(event) = self.gateway.poll_event() {
                    self.on_gateway_event(event);
                }

                self.client
                    .handle_resource_access_authorized(
                        RESOURCE_ID,
                        GATEWAY_ID,
                        self.gateway.public_key(),
                        IpConfig {
                            v4: GATEWAY_TUN_V4,
                            v6: GATEWAY_TUN_V6,
                        },
                        SITE_ID,
                        psk(),
                        client_ice,
                        gateway_ice,
                        false,
                        ingest_token(),
                        now,
                    )
                    .unwrap()
                    .unwrap();
            }
            _ => {}
        }
    }

    fn dispatch(&mut self, transmit: Transmit, now: Instant) {
        let src = transmit.src.unwrap();
        let dst = transmit.dst;

        if dst == CLIENT_SOCKET {
            if let Some(packet) = self.client.network_input(dst, src, &transmit.payload, now)
                && self
                    .client
                    .decrypted_input(dst, src, packet.decrypt(), now)
                    .is_some()
            {
                self.client_received += 1;
            }
            return;
        }

        if dst == GATEWAY_SOCKET {
            if let Some(packet) = self.gateway.network_input(dst, src, &transmit.payload, now)
                && self
                    .gateway
                    .decrypted_input(dst, src, packet.decrypt(), now)
                    .is_some()
            {
                self.gateway_received += 1;
            }
            return;
        }

        assert_eq!(dst.ip(), IpAddr::from(RELAY_IP), "unknown host {dst}");

        if dst.port() == RELAY_PORT {
            let utc = self.created_at + now.duration_since(self.started);
            let Some((port, peer)) =
                self.relay
                    .handle_client_input(&transmit.payload, ClientSocket::new(src), now, utc)
            else {
                return;
            };

            self.network.push_back(Transmit {
                src: Some(SocketAddr::new(RELAY_IP.into(), port.value())),
                dst: peer.into_socket(),
                payload: self.relay_pool.pull_initialised(&transmit.payload[4..]),
                ecn: Ecn::NonEct,
            });
            return;
        }

        let Some((client, channel)) = self.relay.handle_peer_traffic(
            &transmit.payload,
            PeerSocket::new(src),
            AllocationPort::new(dst.port()),
        ) else {
            return;
        };

        let mut payload = vec![0u8; 4 + transmit.payload.len()];
        ChannelData::encode_header_to_slice(
            channel,
            transmit.payload.len() as u16,
            &mut payload[..4],
        );
        payload[4..].copy_from_slice(&transmit.payload);

        self.network.push_back(Transmit {
            src: Some(SocketAddr::new(RELAY_IP.into(), RELAY_PORT)),
            dst: client.into_socket(),
            payload: self.relay_pool.pull_initialised(&payload),
            ecn: Ecn::NonEct,
        });
    }
}

fn with_src(mut t: Transmit, default: SocketAddr) -> Transmit {
    t.src.get_or_insert(default);
    t
}

fn ingest_token() -> tunnel::messages::IngestToken {
    serde_json::from_value(serde_json::Value::String(
        flow_tracker::TEST_INGEST_TOKEN.to_owned(),
    ))
    .unwrap()
}
