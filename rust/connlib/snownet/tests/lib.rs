use boringtun::x25519::StaticSecret;
use ip_packet::*;
use snownet::{Answer, Client, ClientNode, Event, Node, Server, ServerNode, Transmit};
use std::{
    collections::VecDeque,
    iter,
    net::{IpAddr, Ipv4Addr, SocketAddr},
    time::{Duration, Instant},
};
use str0m::{net::Protocol, Candidate};
use tracing::{debug_span, Span};
use tracing_subscriber::util::SubscriberInitExt;

#[test]
fn idle_connection_is_closed_after_5_minutes() {
    let _guard = setup_tracing();
    let mut clock = Clock::new();

    let (alice, bob) = alice_and_bob();

    let mut alice = TestNode::new(debug_span!("Alice"), alice, "1.1.1.1:80");
    let mut bob = TestNode::new(debug_span!("Bob"), bob, "2.2.2.2:80");

    handshake(&mut alice, &mut bob, &clock);

    loop {
        if alice.is_connected_to(&bob) && bob.is_connected_to(&alice) {
            break;
        }

        progress(&mut alice, &mut bob, &mut clock);
    }

    alice.ping(ip("9.9.9.9"), ip("8.8.8.8"), &bob, clock.now);
    bob.ping(ip("8.8.8.8"), ip("9.9.9.9"), &alice, clock.now);

    let start = clock.now;

    while clock.elapsed(start) <= Duration::from_secs(5 * 60) {
        progress(&mut alice, &mut bob, &mut clock);
    }

    assert_eq!(alice.packets_from(ip("8.8.8.8")).count(), 1);
    assert_eq!(bob.packets_from(ip("9.9.9.9")).count(), 1);
    assert!(alice
        .events
        .contains(&(Event::ConnectionClosed(1), clock.now)));
    assert!(bob
        .events
        .contains(&(Event::ConnectionClosed(1), clock.now)));
}

#[test]
fn connection_times_out_after_20_seconds() {
    let (mut alice, _) = alice_and_bob();

    let created_at = Instant::now();

    let _ = alice.new_connection(1, Instant::now(), created_at);
    alice.handle_timeout(created_at + Duration::from_secs(20));

    assert_eq!(alice.poll_event().unwrap(), Event::ConnectionFailed(1));
}

#[test]
fn connection_without_candidates_times_out_after_10_seconds() {
    let _ = tracing_subscriber::fmt().with_test_writer().try_init();

    let start = Instant::now();

    let (mut alice, mut bob) = alice_and_bob();
    let answer = send_offer(&mut alice, &mut bob, start);

    let accepted_at = start + Duration::from_secs(1);
    alice.accept_answer(1, bob.public_key(), answer, accepted_at);

    alice.handle_timeout(accepted_at + Duration::from_secs(10));

    assert_eq!(alice.poll_event().unwrap(), Event::ConnectionFailed(1));
}

#[test]
fn connection_with_candidates_does_not_time_out_after_10_seconds() {
    let _ = tracing_subscriber::fmt().with_test_writer().try_init();

    let start = Instant::now();

    let (mut alice, mut bob) = alice_and_bob();
    let answer = send_offer(&mut alice, &mut bob, start);

    let accepted_at = start + Duration::from_secs(1);
    alice.accept_answer(1, bob.public_key(), answer, accepted_at);
    alice.add_local_host_candidate(s("10.0.0.2:4444")).unwrap();
    alice.add_remote_candidate(1, host("10.0.0.1:4444"), accepted_at);

    alice.handle_timeout(accepted_at + Duration::from_secs(10));

    let any_failed =
        iter::from_fn(|| alice.poll_event()).any(|e| matches!(e, Event::ConnectionFailed(_)));

    assert!(!any_failed);
}

#[test]
fn answer_after_stale_connection_does_not_panic() {
    let start = Instant::now();

    let (mut alice, mut bob) = alice_and_bob();
    let answer = send_offer(&mut alice, &mut bob, start);

    let now = start + Duration::from_secs(10);
    alice.handle_timeout(now);

    alice.accept_answer(1, bob.public_key(), answer, now + Duration::from_secs(1));
}

#[test]
fn only_generate_candidate_event_after_answer() {
    let local_candidate = SocketAddr::new(IpAddr::from(Ipv4Addr::LOCALHOST), 10000);

    let mut alice = ClientNode::<u64, u64>::new(StaticSecret::random_from_rng(rand::thread_rng()));
    alice.add_local_host_candidate(local_candidate).unwrap();

    let mut bob = ServerNode::<u64, u64>::new(StaticSecret::random_from_rng(rand::thread_rng()));

    let offer = alice.new_connection(1, Instant::now(), Instant::now());

    assert_eq!(
        alice.poll_event(),
        None,
        "no event to be emitted before accepting the answer"
    );

    let answer = bob.accept_connection(1, offer, alice.public_key(), Instant::now());

    alice.accept_answer(1, bob.public_key(), answer, Instant::now());

    assert!(iter::from_fn(|| alice.poll_event()).any(|ev| ev
        == Event::NewIceCandidate {
            connection: 1,
            candidate: Candidate::host(local_candidate, Protocol::Udp)
                .unwrap()
                .to_sdp_string()
        }));
}

fn setup_tracing() -> tracing::subscriber::DefaultGuard {
    tracing_subscriber::fmt()
        .with_test_writer()
        .with_env_filter("debug")
        .finish()
        .set_default()
}

fn alice_and_bob() -> (ClientNode<u64, u64>, ServerNode<u64, u64>) {
    let alice = ClientNode::new(StaticSecret::random_from_rng(rand::thread_rng()));
    let bob = ServerNode::new(StaticSecret::random_from_rng(rand::thread_rng()));

    (alice, bob)
}

fn send_offer(
    alice: &mut ClientNode<u64, u64>,
    bob: &mut ServerNode<u64, u64>,
    now: Instant,
) -> Answer {
    let offer = alice.new_connection(1, Instant::now(), now);

    bob.accept_connection(1, offer, alice.public_key(), now)
}

fn host(socket: &str) -> String {
    Candidate::host(s(socket), Protocol::Udp)
        .unwrap()
        .to_sdp_string()
}

fn s(socket: &str) -> SocketAddr {
    socket.parse().unwrap()
}

fn ip(ip: &str) -> IpAddr {
    ip.parse().unwrap()
}

// Heavily inspired by https://github.com/algesten/str0m/blob/7ed5143381cf095f7074689cc254b8c9e50d25c5/src/ice/mod.rs#L547-L647.
struct TestNode<R> {
    node: Node<R, u64, u64>,
    transmits: VecDeque<Transmit<'static>>,

    span: Span,
    received_packets: Vec<IpPacket<'static>>,
    /// All local interfaces.
    local: Vec<SocketAddr>,
    events: Vec<(Event<u64>, Instant)>,

    buffer: Box<[u8; 10_000]>,
}

struct Clock {
    start: Instant,
    now: Instant,

    tick_rate: Duration,
    max_time: Instant,
}

impl Clock {
    fn new() -> Self {
        let now = Instant::now();
        let tick_rate = Duration::from_millis(100);
        let one_hour = Duration::from_secs(60) * 60;

        Self {
            start: now,
            now,
            tick_rate,
            max_time: now + one_hour,
        }
    }

    fn tick(&mut self) {
        self.now += self.tick_rate;

        let elapsed = self.elapsed(self.start);

        if elapsed.as_millis() % 60_000 == 0 {
            tracing::info!("Time since start: {elapsed:?}")
        }

        if self.now >= self.max_time {
            panic!("Time exceeded")
        }
    }

    fn elapsed(&self, start: Instant) -> Duration {
        self.now.duration_since(start)
    }
}

impl<R> TestNode<R> {
    pub fn new(span: Span, mut node: Node<R, u64, u64>, primary: &str) -> Self {
        let primary = primary.parse().unwrap();
        node.add_local_host_candidate(primary).unwrap();

        TestNode {
            node,
            span,
            received_packets: vec![],
            buffer: Box::new([0u8; 10_000]),
            local: vec![primary],
            events: Default::default(),
            transmits: Default::default(),
        }
    }

    fn is_connected_to<RO>(&self, other: &TestNode<RO>) -> bool {
        self.node.connection_id(other.node.public_key()).is_some()
    }

    fn ping<RO>(&mut self, src: IpAddr, dst: IpAddr, other: &TestNode<RO>, now: Instant) {
        let id = self
            .node
            .connection_id(other.node.public_key())
            .expect("cannot ping not-connected node");

        let transmit = self
            .span
            .in_scope(|| {
                self.node.encapsulate(
                    id,
                    ip_packet::make::icmp_request_packet(src, dst, 1, 0).to_immutable(),
                    now,
                )
            })
            .unwrap()
            .unwrap()
            .into_owned();

        self.transmits.push_back(transmit);
    }

    fn packets_from(&self, src: IpAddr) -> impl Iterator<Item = &IpPacket<'static>> {
        self.received_packets
            .iter()
            .filter(move |p| p.source() == src)
    }

    fn receive(&mut self, local: SocketAddr, from: SocketAddr, packet: &[u8], now: Instant) {
        debug_assert!(self.local.contains(&local));

        if let Some((_, packet)) = self
            .span
            .in_scope(|| {
                self.node
                    .decapsulate(local, from, packet, now, self.buffer.as_mut())
            })
            .unwrap()
        {
            self.received_packets.push(packet.to_immutable().to_owned())
        }
    }

    fn drain_events<RO>(&mut self, other: &mut TestNode<RO>, now: Instant) {
        while let Some(v) = self.span.in_scope(|| self.node.poll_event()) {
            self.events.push((v.clone(), now));

            match v {
                Event::NewIceCandidate {
                    connection,
                    candidate,
                } => other
                    .span
                    .in_scope(|| other.node.add_remote_candidate(connection, candidate, now)),
                Event::InvalidateIceCandidate {
                    connection,
                    candidate,
                } => other
                    .span
                    .in_scope(|| other.node.remove_remote_candidate(connection, candidate)),
                Event::ConnectionEstablished(_)
                | Event::ConnectionFailed(_)
                | Event::ConnectionClosed(_) => {}
            };
        }
    }

    fn drain_transmits<RO>(&mut self, other: &mut TestNode<RO>, now: Instant) {
        for trans in iter::from_fn(|| self.node.poll_transmit()).chain(self.transmits.drain(..)) {
            let payload = &trans.payload;
            let dst = trans.dst;

            let Some(src) = trans.src else {
                tracing::debug!(target: "router", %dst, "Unknown relay");
                continue;
            };

            if !other.local.contains(&dst) {
                tracing::debug!(target: "router", %src, %dst, "Unknown destination");
                continue;
            }

            // Firewall allowed traffic, let's dispatch it.
            other.receive(dst, src, payload, now);
        }
    }
}

fn handshake(client: &mut TestNode<Client>, server: &mut TestNode<Server>, clock: &Clock) {
    let offer = client
        .span
        .in_scope(|| client.node.new_connection(1, clock.now, clock.now));
    let answer = server.span.in_scope(|| {
        server
            .node
            .accept_connection(1, offer, client.node.public_key(), clock.now)
    });
    client.span.in_scope(|| {
        client
            .node
            .accept_answer(1, server.node.public_key(), answer, clock.now)
    });
}

fn progress<R1, R2>(a1: &mut TestNode<R1>, a2: &mut TestNode<R2>, clock: &mut Clock) {
    clock.tick();

    a1.drain_events(a2, clock.now);
    a2.drain_events(a1, clock.now);

    a1.drain_transmits(a2, clock.now);
    a2.drain_transmits(a1, clock.now);

    if let Some(timeout) = a1.node.poll_timeout() {
        if clock.now >= timeout {
            a1.span.in_scope(|| a1.node.handle_timeout(clock.now));
        }
    }

    if let Some(timeout) = a2.node.poll_timeout() {
        if clock.now >= timeout {
            a2.span.in_scope(|| a2.node.handle_timeout(clock.now));
        }
    }

    a1.drain_events(a2, clock.now);
    a2.drain_events(a1, clock.now);
}
