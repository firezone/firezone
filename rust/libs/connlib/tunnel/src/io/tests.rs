use std::future::poll_fn;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddrV4, SocketAddrV6};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::task::{Wake, Waker};

use bufferpool::Bytes;
use doh_test_server::DohTestServer;
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

#[tokio::test(start_paused = true)]
async fn tun_is_not_read_while_udp_overflow_is_waiting() {
    let (mut io, ends) = Io::fake();
    let (mut cx, _wakes) = expect_wakes(0);
    ends.tun_tx.send(batch()).await.unwrap();
    io.stall_udp(V4_PEER);

    assert!(io.poll(&mut cx).is_pending());
}

#[tokio::test(start_paused = true)]
async fn tun_is_read_once_udp_drains() {
    let (mut io, mut ends) = Io::fake();
    let (mut cx, _wakes) = expect_wakes(1);
    ends.tun_tx.send(batch()).await.unwrap();
    io.stall_udp(V4_PEER);
    assert!(io.poll(&mut cx).is_pending());

    ends.v4.outbound_rx.try_recv().unwrap();

    assert!(io.poll_input(&mut cx).device.is_some());
    assert_eq!(io.sockets.num_waiting(IpVersion::V4), 0);
}

#[tokio::test(start_paused = true)]
async fn stalled_v4_blocks_tun_reads_but_not_v6_transmits() {
    let (mut io, mut ends) = Io::fake();
    let (mut cx, _wakes) = expect_wakes(0);
    ends.tun_tx.send(batch()).await.unwrap();
    io.stall_udp(V4_PEER);

    io.send_network(transmit(V6_PEER, 4));

    assert!(io.poll(&mut cx).is_pending());
    assert!(ends.v6.outbound_rx.try_recv().is_ok());
}

#[tokio::test(start_paused = true)]
async fn missing_v6_drops_its_transmits_with_error_and_keeps_reading_tun() {
    let (mut io, mut ends) = Io::fake();
    let mut cx = Context::from_waker(Waker::noop());
    io.sockets.remove_v6();
    ends.tun_tx.send(batch()).await.unwrap();

    io.send_network(transmit(V6_PEER, 4));
    io.send_network(transmit(V4_PEER, 4));
    let error = io.poll_input(&mut cx).error.drain().next().unwrap();
    let second = io.poll_input(&mut cx);

    assert_eq!(
        error.any_downcast_ref::<io::Error>().unwrap().kind(),
        io::ErrorKind::NotConnected
    );
    assert_eq!(io.sockets.num_waiting(IpVersion::V6), 0);
    assert!(ends.v4.outbound_rx.try_recv().is_ok());
    assert!(second.device.is_some());
}

#[tokio::test(start_paused = true)]
async fn decrypted_packets_are_not_taken_while_tun_is_full() {
    let (mut io, _ends) = Io::fake();
    let (mut cx, _wakes) = expect_wakes(0);
    io.stall_tun();

    io.finish_decrypt_job();

    assert!(io.poll(&mut cx).is_pending());
}

#[tokio::test(start_paused = true)]
async fn decrypted_packets_resume_when_tun_drains() {
    let (mut io, mut ends) = Io::fake();
    let (mut cx, _wakes) = expect_wakes(1);
    io.stall_tun();
    io.finish_decrypt_job();
    assert!(io.poll(&mut cx).is_pending());

    ends.tun_rx.recv().now_or_never().unwrap();

    assert!(io.poll_input(&mut cx).decrypted.is_some());
}

#[tokio::test(start_paused = true)]
async fn network_is_not_read_while_decrypt_backlog_is_full() {
    let (mut io, ends) = Io::fake();
    let _jobs = io.fill_decrypt_backlog();
    let (mut cx, _wakes) = expect_wakes(0);

    ends.v4.inbound_tx.try_send(DatagramBatch::empty()).unwrap();

    assert!(io.poll(&mut cx).is_pending());
}

#[tokio::test(start_paused = true)]
async fn network_resumes_in_same_poll_as_decrypt_backlog_frees() {
    let (mut io, ends) = Io::fake();
    let mut jobs = io.fill_decrypt_backlog();
    let (mut cx, _wakes) = expect_wakes(1);
    ends.v4.inbound_tx.try_send(DatagramBatch::empty()).unwrap();
    assert!(io.poll(&mut cx).is_pending());

    assert!(jobs.remove(0).send(DecryptedIpPackets::default()).is_ok());

    let input = io.poll_input(&mut cx);
    assert!(input.decrypted.is_some());
    assert!(input.network.is_some());
}

#[tokio::test(start_paused = true)]
async fn network_is_read_from_both_families_each_poll() {
    let (mut io, ends) = Io::fake();
    let mut cx = Context::from_waker(Waker::noop());
    while ends.v4.inbound_tx.try_send(DatagramBatch::empty()).is_ok() {}
    while ends.v6.inbound_tx.try_send(DatagramBatch::empty()).is_ok() {}

    assert!(io.poll_input(&mut cx).network.is_some());

    assert_eq!(
        ends.v4.inbound_tx.capacity(),
        ends.v4.inbound_tx.max_capacity()
    );
    assert_eq!(
        ends.v6.inbound_tx.capacity(),
        ends.v6.inbound_tx.max_capacity()
    );
}

#[tokio::test(start_paused = true)]
async fn network_is_read_while_udp_is_stalled() {
    let (mut io, ends) = Io::fake();
    let mut cx = Context::from_waker(Waker::noop());
    io.stall_udp(V4_PEER);

    ends.v4.inbound_tx.try_send(DatagramBatch::empty()).unwrap();

    assert!(io.poll_input(&mut cx).network.is_some());
}

#[tokio::test(start_paused = true)]
async fn tun_is_read_while_tun_write_is_stalled() {
    let (mut io, ends) = Io::fake();
    let (mut cx, _wakes) = expect_wakes(1);
    io.stall_tun();
    assert!(io.poll(&mut cx).is_pending());

    ends.tun_tx.send(batch()).await.unwrap();

    assert!(io.poll_input(&mut cx).device.is_some());
}

#[tokio::test(start_paused = true)]
async fn full_error_channels_are_drained_while_udp_and_tun_are_stalled() {
    let (mut io, ends) = Io::fake();
    let mut cx = Context::from_waker(Waker::noop());
    io.stall_udp(V4_PEER);
    io.stall_udp(V6_PEER);
    io.stall_tun();

    let mut num_errors = 0;
    while ends.v4.error_tx.try_send(anyhow::anyhow!("v4")).is_ok() {
        num_errors += 1;
    }
    while ends.v6.error_tx.try_send(anyhow::anyhow!("v6")).is_ok() {
        num_errors += 1;
    }

    let mut num_drained = 0;
    while num_drained < num_errors {
        num_drained += io.poll_input(&mut cx).error.drain().count();
        tokio::task::yield_now().await; // Resets Tokio's coop budget, which limits one poll's drain.
    }
}

#[tokio::test(start_paused = true)]
async fn socket_error_wakes_stalled_io() {
    let (mut io, ends) = Io::fake();
    let (mut cx, _wakes) = expect_wakes(1);
    io.stall_udp(V4_PEER);
    io.stall_tun();
    assert!(io.poll(&mut cx).is_pending());

    ends.v6.error_tx.try_send(anyhow::anyhow!("v6")).unwrap();

    assert_eq!(io.poll_input(&mut cx).error.drain().count(), 1);
}

#[tokio::test(start_paused = true)]
async fn dns_responses_flow_while_udp_and_tun_are_stalled() {
    let (mut io, _ends) = Io::fake();
    let mut cx = Context::from_waker(Waker::noop());
    io.udp_socket_factory = Arc::new(no_socket);
    io.stall_udp(V4_PEER);
    io.stall_tun();

    io.send_dns_query(
        dns::RecursiveQuery {
            server: dns::Upstream::Do53 { server: V4_PEER },
            local: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 11111),
            remote: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 22222),
            message: dns_types::Query::new(
                "example.com".parse().unwrap(),
                dns_types::RecordType::A,
            ),
            transport: dns::Transport::Udp,
        },
        Instant::now(),
    );

    assert_eq!(io.poll_input(&mut cx).dns_responses.len(), 1);
}

#[tokio::test(start_paused = true)]
async fn stalled_io_does_not_wake_itself() {
    let (mut io, ends) = Io::fake();
    let _jobs = io.fill_decrypt_backlog();
    let (mut cx, _wakes) = expect_wakes(0);
    io.stall_udp(V4_PEER);
    io.stall_tun();
    ends.tun_tx.send(batch()).await.unwrap();
    ends.v4.inbound_tx.try_send(DatagramBatch::empty()).unwrap();

    assert!(io.poll(&mut cx).is_pending());
    assert!(io.poll(&mut cx).is_pending());
}

#[tokio::test]
async fn send_errors_do_not_hold_up_later_datagrams() {
    let peer = tokio::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0))
        .await
        .unwrap();
    let peer_addr = peer.local_addr().unwrap();
    let mut io = Io::for_test();
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
async fn bootstrap_doh() {
    let _guard = logging::test("debug");

    let answer = Ipv4Addr::new(192, 0, 2, 1);
    let server = DohTestServer::spawn(answer).await.unwrap();
    let mut io = Io::for_test();
    io.doh_tls_config = TlsConfig::new(server.root_cert_store());

    io.send_dns_query(example_com_recursive_query(server.url()), Instant::now());

    let response = io.next_dns_response().await.message.unwrap();

    assert_eq!(response.response_code(), dns_types::ResponseCode::NOERROR);
    assert_eq!(
        response
            .records()
            .filter_map(dns_types::records::extract_ip)
            .collect::<Vec<_>>(),
        vec![IpAddr::V4(answer)]
    );
}

#[tokio::test]
async fn failed_bootstrap_is_evicted() {
    let _guard = logging::test("debug");

    let mut io = Io::for_test();

    io.send_dns_query(
        example_com_recursive_query(DoHUrl::cloudflare()),
        Instant::now(),
    );
    let response = io.next_dns_response().await;

    assert!(response.message.is_err());
    assert!(io.doh_clients.is_empty());

    io.send_dns_query(
        example_com_recursive_query(DoHUrl::cloudflare()),
        Instant::now(),
    );

    assert!(matches!(
        io.doh_clients.get(&DoHUrl::cloudflare()),
        Some(DohClient::Connecting(_))
    ));
}

#[tokio::test]
async fn rebind_dns_clears_all_servers_on_failure() {
    let _guard = logging::test("debug");

    let mut io = Io::for_test();

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

fn example_com_recursive_query(server: DoHUrl) -> dns::RecursiveQuery {
    dns::RecursiveQuery {
        server: dns::Upstream::DoH { server },
        local: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 11111),
        remote: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 22222),
        message: dns_types::Query::new("example.com".parse().unwrap(), dns_types::RecordType::A),
        transport: dns::Transport::Udp,
    }
}

/// Helper functions to make the test more concise.
impl Io {
    fn for_test() -> Io {
        Io::new(
            Arc::new(socket_factory::tcp),
            Arc::new(socket_factory::udp),
            BTreeSet::new(),
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
        };

        let mut io = Io::for_test();
        io.sockets = sockets;
        io.set_tun(tun);

        (io, ends)
    }

    async fn next_dns_response(&mut self) -> dns::RecursiveResponse {
        loop {
            let mut input = poll_fn(|cx| self.poll(cx)).await;

            for e in input.error.drain() {
                tracing::debug!("Ignoring error unrelated to DNS: {e:#}");
            }

            if let Some(response) = input.dns_responses.pop() {
                return response;
            }
        }
    }

    fn poll_input(&mut self, cx: &mut Context<'_>) -> Input {
        let Poll::Ready(input) = self.poll(cx) else {
            panic!("Expected input");
        };

        input
    }

    /// Sends transmits to `dst` until one waits for room in its socket's channel.
    fn stall_udp(&mut self, dst: SocketAddr) {
        let version = match dst {
            SocketAddr::V4(_) => IpVersion::V4,
            SocketAddr::V6(_) => IpVersion::V6,
        };

        while self.sockets.num_waiting(version) == 0 {
            self.send_network(transmit(dst, 4));
        }
    }

    /// Queues a batch that fills the TUN channel on the next poll.
    fn stall_tun(&mut self) {
        self.queue_tun(packet());
        self.flush_tun_batch();
    }

    fn finish_decrypt_job(&mut self) {
        let job = self.decrypting.add_job();

        assert!(job.send(DecryptedIpPackets::default()).is_ok());
    }

    fn fill_decrypt_backlog(&mut self) -> Vec<oneshot::Sender<DecryptedIpPackets>> {
        let mut jobs = Vec::new();

        while self.decrypting.has_room() {
            jobs.push(self.decrypting.add_job());
        }
        // `FuturesUnordered` wakes itself once it polled every one of its futures and all are pending.
        let mut cx = Context::from_waker(Waker::noop());
        assert!(self.poll(&mut cx).is_pending());

        jobs
    }
}

struct FakeEnds {
    v4: SocketThreadEnds,
    v6: SocketThreadEnds,
    tun_tx: tun::InboundTx,
    tun_rx: tun::OutboundRx,
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

fn no_socket(_: SocketAddr) -> io::Result<UdpSocket> {
    Err(io::Error::other("No sockets in this test"))
}
