use std::collections::BTreeSet;
use std::future::poll_fn;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddrV4, SocketAddrV6};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::task::{Wake, Waker};
use std::time::{Duration, Instant};

use anyhow::ErrorExt as _;
use bufferpool::Bytes;
use futures::FutureExt as _;
use ip_packet::{Ecn, IpVersion};
use socket_factory::DatagramBatch;
use tokio::sync::oneshot;

use super::*;
use crate::sockets::{QUEUE_SIZE, SocketThreadEnds};

const V4_PEER: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(192, 0, 2, 1), 3478));
const V6_PEER: SocketAddr = SocketAddr::V6(SocketAddrV6::new(
    Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1),
    3478,
    0,
    0,
));

#[tokio::test]
async fn tun_is_not_read_while_udp_overflow_is_waiting() {
    let (mut io, ends) = Io::fake();
    let (mut cx, _wakes) = expect_wakes(0);

    ends.tun_tx.send(batch()).await.unwrap();
    stall_udp(&mut io, V4_PEER);

    assert!(io.poll(&mut cx).is_pending());
}

#[tokio::test]
async fn tun_is_read_once_udp_drains() {
    let (mut io, mut ends) = Io::fake();
    let (mut cx, _wakes) = expect_wakes(1);

    ends.tun_tx.send(batch()).await.unwrap();
    stall_udp(&mut io, V4_PEER);

    let _ = io.poll(&mut cx); // Registers `cx`'s waker.
    ends.v4.outbound_rx.try_recv().unwrap();

    assert!(io.poll_unwrap(&mut cx).device.is_some());
    assert_eq!(io.sockets.num_waiting(IpVersion::V4), 0);
}

#[tokio::test]
async fn stalled_v4_blocks_tun_reads_but_not_v6_transmits() {
    let (mut io, mut ends) = Io::fake();
    let (mut cx, _wakes) = expect_wakes(0);

    ends.tun_tx.send(batch()).await.unwrap();
    stall_udp(&mut io, V4_PEER);

    io.send_network(transmit(V6_PEER, 4));

    assert!(io.poll(&mut cx).is_pending());
    assert!(ends.v6.outbound_rx.try_recv().is_ok());
}

#[tokio::test]
async fn missing_v6_drops_its_transmits_with_error_and_keeps_reading_tun() {
    let (mut io, mut ends) = Io::fake();
    let mut cx = Context::from_waker(Waker::noop());

    io.sockets.remove_v6();
    ends.tun_tx.send(batch()).await.unwrap();

    io.send_network(transmit(V6_PEER, 4));
    io.send_network(transmit(V4_PEER, 4));
    let mut first = io.poll_unwrap(&mut cx);
    let second = io.poll_unwrap(&mut cx);

    let error = first.error.drain().next().unwrap();
    assert_eq!(
        error.any_downcast_ref::<io::Error>().unwrap().kind(),
        io::ErrorKind::NotConnected
    );
    assert_eq!(io.sockets.num_waiting(IpVersion::V6), 0);
    assert!(ends.v4.outbound_rx.try_recv().is_ok());
    assert!(second.device.is_some());
}

#[tokio::test]
async fn decrypted_packets_are_not_taken_while_tun_is_full() {
    let (mut io, _ends) = Io::fake();
    let (mut cx, _wakes) = expect_wakes(0);

    stall_tun(&mut io);
    add_finished_decrypt_job(&mut io);

    assert!(io.poll(&mut cx).is_pending());
}

#[tokio::test]
async fn decrypted_packets_resume_when_tun_drains() {
    let (mut io, mut ends) = Io::fake();
    let (mut cx, _wakes) = expect_wakes(1);

    stall_tun(&mut io);
    add_finished_decrypt_job(&mut io);

    let _ = io.poll(&mut cx); // Registers `cx`'s waker.
    ends.tun_rx.recv().now_or_never().unwrap();

    assert!(io.poll_unwrap(&mut cx).decrypted.is_some());
}

#[tokio::test]
async fn network_is_not_read_while_decrypt_backlog_is_full() {
    let (mut io, mut ends) = Io::fake();
    let (mut cx, _wakes) = expect_wakes(0);

    fill_decrypt_backlog(&mut io, &mut ends);
    ends.v4.inbound_tx.try_send(empty_batch()).unwrap();

    assert!(io.poll(&mut cx).is_pending());
}

#[tokio::test]
async fn network_resumes_in_same_poll_as_decrypt_backlog_frees() {
    let (mut io, mut ends) = Io::fake();
    let (mut cx, _wakes) = expect_wakes(1);

    fill_decrypt_backlog(&mut io, &mut ends);
    ends.v4.inbound_tx.try_send(empty_batch()).unwrap();

    let _ = io.poll(&mut cx); // Registers `cx`'s waker.
    ends.finish_decrypt_job();

    let input = io.poll_unwrap(&mut cx);
    assert!(input.decrypted.is_some());
    assert!(input.network.is_some());
}

#[tokio::test]
async fn network_is_read_from_both_families_each_poll() {
    let (mut io, ends) = Io::fake();
    let mut cx = Context::from_waker(Waker::noop());

    ends.v4.inbound_tx.try_send(datagram_from(V4_PEER)).unwrap();
    ends.v6.inbound_tx.try_send(datagram_from(V6_PEER)).unwrap();

    let mut network = io.poll_unwrap(&mut cx).network.unwrap();

    let senders = network.drain().map(|d| d.from()).collect::<Vec<_>>();
    assert_eq!(senders, vec![V4_PEER, V6_PEER]);
}

#[tokio::test]
async fn network_is_read_while_udp_is_stalled() {
    let (mut io, ends) = Io::fake();
    let mut cx = Context::from_waker(Waker::noop());

    stall_udp(&mut io, V4_PEER);
    ends.v4.inbound_tx.try_send(empty_batch()).unwrap();

    assert!(io.poll_unwrap(&mut cx).network.is_some());
}

#[tokio::test]
async fn tun_is_read_while_tun_write_is_stalled() {
    let (mut io, ends) = Io::fake();
    let (mut cx, _wakes) = expect_wakes(1);

    stall_tun(&mut io);

    let _ = io.poll(&mut cx); // Registers `cx`'s waker.
    ends.tun_tx.send(batch()).await.unwrap();

    assert!(io.poll_unwrap(&mut cx).device.is_some());
}

#[tokio::test]
async fn full_error_channels_are_drained_while_udp_and_tun_are_stalled() {
    let (mut io, ends) = Io::fake();
    let mut cx = Context::from_waker(Waker::noop());

    stall_udp(&mut io, V4_PEER);
    stall_tun(&mut io);
    let mut num_errors = 0;
    while ends.v4.error_tx.try_send(anyhow::anyhow!("v4")).is_ok() {
        num_errors += 1;
    }
    while ends.v6.error_tx.try_send(anyhow::anyhow!("v6")).is_ok() {
        num_errors += 1;
    }

    let mut input = tokio::task::unconstrained(async { io.poll_unwrap(&mut cx) }).await;

    assert_eq!(input.error.drain().count(), num_errors);
}

#[tokio::test]
async fn socket_error_wakes_stalled_io() {
    let (mut io, ends) = Io::fake();
    let (mut cx, _wakes) = expect_wakes(1);

    stall_udp(&mut io, V4_PEER);
    stall_tun(&mut io);

    let _ = io.poll(&mut cx); // Registers `cx`'s waker.
    ends.v6.error_tx.try_send(anyhow::anyhow!("v6")).unwrap();

    assert_eq!(io.poll_unwrap(&mut cx).error.drain().count(), 1);
}

#[tokio::test]
async fn dns_responses_flow_while_udp_and_tun_are_stalled() {
    let (mut io, _ends) = Io::fake();
    io.resolver = resolver::spawn(
        Arc::new(socket_factory::tcp),
        Arc::new(socket_factory::udp),
        BTreeSet::new(),
    );

    stall_udp(&mut io, V4_PEER);
    stall_tun(&mut io);
    io.send_dns_query(ResolverQuery {
        server: None,
        local: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 11111),
        remote: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 22222),
        message: dns_types::Query::new("example.com".parse().unwrap(), dns_types::RecordType::A),
        transport: dns::Transport::Udp,
        started_at: Instant::now(),
    });

    assert_eq!(poll_fn(|cx| io.poll(cx)).await.dns_responses.len(), 1);
}

#[tokio::test]
async fn stalled_io_does_not_wake_itself() {
    let (mut io, mut ends) = Io::fake();
    let (mut cx, _wakes) = expect_wakes(0);

    fill_decrypt_backlog(&mut io, &mut ends);
    stall_udp(&mut io, V4_PEER);
    stall_tun(&mut io);
    ends.tun_tx.send(batch()).await.unwrap();
    ends.v4.inbound_tx.try_send(empty_batch()).unwrap();

    assert!(io.poll(&mut cx).is_pending());
    assert!(io.poll(&mut cx).is_pending());
}

#[tokio::test]
async fn transmits_while_udp_is_stalled_are_bounded() {
    let (mut io, _ends) = Io::fake();

    stall_udp(&mut io, V4_PEER);

    for _ in 0..2 * QUEUE_SIZE {
        io.send_network(transmit(V4_PEER, 4));
    }

    assert_eq!(io.sockets.num_waiting(IpVersion::V4), QUEUE_SIZE);
}

#[tokio::test]
async fn send_errors_do_not_hold_up_later_datagrams() {
    let peer = tokio::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0))
        .await
        .unwrap();
    let peer_addr = peer.local_addr().unwrap();
    let mut io = Io::real();
    let num_failing = 4 * QUEUE_SIZE;
    let oversized = std::iter::repeat_with(|| transmit(peer_addr, 70_000)).take(num_failing);

    let num_errors = tokio::time::timeout(Duration::from_secs(5), async {
        let mut num_errors = 0;

        for transmit in oversized.chain([transmit(peer_addr, 4)]) {
            io.send_network(transmit);

            while io.sockets.num_waiting(IpVersion::V4) > 0 {
                num_errors += next_send_errors(&mut io).await;
            }
        }
        while num_errors < num_failing {
            num_errors += next_send_errors(&mut io).await;
        }

        peer.recv_from(&mut [0; 16]).await.unwrap();

        num_errors
    })
    .await
    .unwrap();

    assert_eq!(num_errors, num_failing);
}

#[tokio::test]
async fn rebind_dns_clears_all_servers_on_failure() {
    let _guard = logging::test("debug");

    let mut io = Io::real();

    let result = io.rebind_dns(vec![
        SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0), // This one will almost definitely work.
        SocketAddr::new(IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1)), 40000), // This one will fail.
    ]);

    assert_eq!(
        result
            .unwrap_err()
            .drain()
            .map(|e| e.to_string())
            .collect::<Vec<_>>(),
        vec![
            "Failed to bind UDP socket on 1.1.1.1:40000",
            "Failed to bind TCP listener on 1.1.1.1:40000"
        ]
    );
    assert!(io.udp_dns_server.is_empty());
    assert!(io.tcp_dns_server.is_empty());
}

impl Io {
    fn real() -> Io {
        let udp: Arc<dyn SocketFactory<UdpSocket>> = Arc::new(socket_factory::udp);
        let (resolver, _) = resolver::channels();

        Io::new(
            Sockets::new(udp.clone()),
            CryptoWorkers::default(),
            resolver,
            Arc::new(socket_factory::tcp),
            udp,
        )
    }

    fn fake() -> (Io, FakeEnds) {
        let (sockets, v4, v6) = Sockets::fake();
        let (tun, tun_tx, tun_rx) = tun::fake(1);
        let ends = FakeEnds {
            v4,
            v6,
            tun_tx,
            tun_rx,
            decrypt_jobs: Vec::new(),
        };

        let (resolver, _) = resolver::channels();
        let mut io = Io::new(
            sockets,
            CryptoWorkers::default(),
            resolver,
            Arc::new(socket_factory::tcp),
            Arc::new(socket_factory::udp),
        );
        io.set_tun(tun);

        (io, ends)
    }

    fn poll_unwrap(&mut self, cx: &mut Context<'_>) -> Input {
        let Poll::Ready(input) = self.poll(cx) else {
            panic!("Expected input");
        };

        input
    }
}

/// Sends transmits to `dst` until one waits for room in the sockets' channels.
fn stall_udp(io: &mut Io, dst: SocketAddr) {
    let mut cx = Context::from_waker(Waker::noop());

    while io.sockets.poll_flush(&mut cx).is_ready() {
        io.send_network(transmit(dst, 4));
    }
}

/// Sends batches to the TUN device until its channel has no room for another one.
fn stall_tun(io: &mut Io) {
    let mut cx = Context::from_waker(Waker::noop());

    while io.tun.poll_flush(&mut cx).is_ready() {
        io.queue_tun(packet());
        io.flush_tun_batch();
    }
}

fn add_finished_decrypt_job(io: &mut Io) {
    let job = io.decrypting.add_job();

    assert!(job.send(DecryptedIpPackets::default()).is_ok());
}

fn fill_decrypt_backlog(io: &mut Io, ends: &mut FakeEnds) {
    while io.decrypting.has_room() {
        ends.decrypt_jobs.push(io.decrypting.add_job());
    }
    // `FuturesUnordered` wakes itself once it polled every one of its futures and all are pending.
    let mut cx = Context::from_waker(Waker::noop());
    assert!(io.poll(&mut cx).is_pending());
}

struct FakeEnds {
    v4: SocketThreadEnds,
    v6: SocketThreadEnds,
    tun_tx: tun::InboundTx,
    tun_rx: tun::OutboundRx,
    decrypt_jobs: Vec<oneshot::Sender<DecryptedIpPackets>>,
}

impl FakeEnds {
    fn finish_decrypt_job(&mut self) {
        let job = self.decrypt_jobs.remove(0);

        assert!(job.send(DecryptedIpPackets::default()).is_ok());
    }
}

/// Returns a [`Context`] whose waker must be woken exactly `expected` times before the returned guard drops.
///
/// Values declared after the guard drop before it, so wakes from dropping them count too.
fn expect_wakes(expected: usize) -> (Context<'static>, ExpectedWakes) {
    let counter = Arc::new(WakeCounter::default());
    let waker = Box::leak(Box::new(Waker::from(counter.clone())));

    (
        Context::from_waker(waker),
        ExpectedWakes { counter, expected },
    )
}

struct ExpectedWakes {
    counter: Arc<WakeCounter>,
    expected: usize,
}

impl Drop for ExpectedWakes {
    fn drop(&mut self) {
        if std::thread::panicking() {
            return;
        }

        assert_eq!(
            self.counter.0.load(Ordering::SeqCst),
            self.expected,
            "Unexpected number of wakes"
        );
    }
}

#[derive(Default)]
struct WakeCounter(AtomicUsize);

impl Wake for WakeCounter {
    fn wake(self: Arc<Self>) {
        self.0.fetch_add(1, Ordering::SeqCst);
    }
}

fn empty_batch() -> DatagramBatch {
    DatagramBatch::new(Vec::new(), Vec::new(), 0, 0)
}

fn datagram_from(from: SocketAddr) -> DatagramBatch {
    let mut meta = quinn_udp::RecvMeta::default();
    meta.addr = from;
    meta.len = 4;
    meta.stride = 4;
    meta.dst_ip = Some(from.ip());

    DatagramBatch::new(vec![Bytes::copied_from(&[0; 4])], vec![meta], 0, 1)
}

fn batch() -> tun::PacketBatch {
    tun::PacketBatch::new(packet())
}

async fn next_send_errors(io: &mut Io) -> usize {
    let mut input = poll_fn(|cx| io.poll(cx)).await;

    input
        .error
        .drain()
        .filter(|e| format!("{e:#}").contains("exceeds the maximum UDP payload"))
        .count()
}

fn transmit(dst: SocketAddr, len: usize) -> snownet::Transmit {
    snownet::Transmit {
        src: None,
        dst,
        payload: Bytes::copied_from(&vec![0; len]),
        ecn: Ecn::NonEct,
    }
}

fn packet() -> IpPacket {
    ip_packet::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 1234, 5678, &[]).unwrap()
}
