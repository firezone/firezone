use boringtun::x25519::StaticSecret;
use snownet::{Answer, ClientNode, Event, MutableIpPacket, ServerNode, Transmit};
use std::{
    collections::{HashMap, HashSet},
    iter,
    net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4},
    time::{Duration, Instant},
    vec,
};
use str0m::{net::Protocol, Candidate};
use tracing::{info_span, Span};

#[test]
fn smoke() {
    let _ = tracing_subscriber::fmt()
        .with_test_writer()
        .with_env_filter("debug")
        .try_init();

    let (mut alice, mut bob) = alice_and_bob();
    alice.add_local_host_candidate(s("1.1.1.1:80")).unwrap();
    bob.add_local_host_candidate(s("1.1.1.2:80")).unwrap();

    let start = Instant::now();

    let answer = send_offer(&mut alice, &mut bob, start);
    alice.accept_answer(1, bob.public_key(), answer, start);

    let mut alice = TestNode::new(info_span!("Alice"), EitherNode::Client(alice));
    let mut bob = TestNode::new(info_span!("Bob"), EitherNode::Server(bob));

    loop {
        if alice.is_connected_to(1) && bob.is_connected_to(1) {
            break;
        }
        progress(&mut alice, &mut bob);
    }
}

#[test]
fn connection_times_out_after_20_seconds() {
    let (mut alice, _) = alice_and_bob();

    let created_at = Instant::now();

    let _ = alice.new_connection(
        1,
        HashSet::new(),
        HashSet::new(),
        Instant::now(),
        created_at,
    );
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

    let mut alice = ClientNode::<u64>::new(StaticSecret::random_from_rng(rand::thread_rng()));

    alice.add_local_host_candidate(local_candidate).unwrap();

    let mut bob = ServerNode::<u64>::new(StaticSecret::random_from_rng(rand::thread_rng()));

    let offer = alice.new_connection(
        1,
        HashSet::new(),
        HashSet::new(),
        Instant::now(),
        Instant::now(),
    );

    assert_eq!(
        alice.poll_event(),
        None,
        "no event to be emitted before accepting the answer"
    );

    let answer = bob.accept_connection(
        1,
        offer,
        alice.public_key(),
        HashSet::new(),
        HashSet::new(),
        Instant::now(),
    );

    alice.accept_answer(1, bob.public_key(), answer, Instant::now());

    assert!(iter::from_fn(|| alice.poll_event()).any(|ev| ev
        == Event::SignalIceCandidate {
            connection: 1,
            candidate: Candidate::host(local_candidate, Protocol::Udp)
                .unwrap()
                .to_sdp_string()
        }));
}

#[test]
fn second_connection_with_same_relay_reuses_allocation() {
    let mut alice = ClientNode::<u64>::new(StaticSecret::random_from_rng(rand::thread_rng()));

    let _ = alice.new_connection(
        1,
        HashSet::new(),
        HashSet::from([relay("user1", "pass1", "realm1")]),
        Instant::now(),
        Instant::now(),
    );

    let transmit = alice.poll_transmit().unwrap();
    assert_eq!(transmit.dst, RELAY);
    assert!(alice.poll_transmit().is_none());

    let _ = alice.new_connection(
        2,
        HashSet::new(),
        HashSet::from([relay("user1", "pass1", "realm1")]),
        Instant::now(),
        Instant::now(),
    );

    assert!(alice.poll_transmit().is_none());
}

fn alice_and_bob() -> (ClientNode<u64>, ServerNode<u64>) {
    let alice = ClientNode::<u64>::new(StaticSecret::random_from_rng(rand::thread_rng()));
    let bob = ServerNode::<u64>::new(StaticSecret::random_from_rng(rand::thread_rng()));

    (alice, bob)
}

fn send_offer(alice: &mut ClientNode<u64>, bob: &mut ServerNode<u64>, now: Instant) -> Answer {
    let offer = alice.new_connection(1, HashSet::new(), HashSet::new(), Instant::now(), now);

    bob.accept_connection(
        1,
        offer,
        alice.public_key(),
        HashSet::new(),
        HashSet::new(),
        now,
    )
}

fn relay(username: &str, pass: &str, realm: &str) -> (SocketAddr, String, String, String) {
    (
        RELAY,
        username.to_owned(),
        pass.to_owned(),
        realm.to_owned(),
    )
}

fn host(socket: &str) -> String {
    Candidate::host(s(socket), Protocol::Udp)
        .unwrap()
        .to_sdp_string()
}

fn s(socket: &str) -> SocketAddr {
    socket.parse().unwrap()
}

const RELAY: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 10000));

// Heavily inspired by https://github.com/algesten/str0m/blob/7ed5143381cf095f7074689cc254b8c9e50d25c5/src/ice/mod.rs#L547-L647.
struct TestNode {
    node: EitherNode,
    span: Span,
    received_packets: Vec<MutableIpPacket<'static>>,
    progress_count: u64,
    time: Instant,

    connection_state: HashMap<u64, bool>,

    buffer: Box<[u8; 10_000]>,
}

enum EitherNode {
    Server(ServerNode<u64>),
    Client(ClientNode<u64>),
}

impl EitherNode {
    fn poll_transmit(&mut self) -> Option<Transmit> {
        match self {
            EitherNode::Client(n) => n.poll_transmit(),
            EitherNode::Server(n) => n.poll_transmit(),
        }
    }

    fn poll_event(&mut self) -> Option<Event<u64>> {
        match self {
            EitherNode::Client(n) => n.poll_event(),
            EitherNode::Server(n) => n.poll_event(),
        }
    }

    fn poll_timeout(&mut self) -> Option<Instant> {
        match self {
            EitherNode::Client(n) => n.poll_timeout(),
            EitherNode::Server(n) => n.poll_timeout(),
        }
    }

    fn add_remote_candidate(&mut self, id: u64, candidate: String, now: Instant) {
        match self {
            EitherNode::Client(n) => n.add_remote_candidate(id, candidate, now),
            EitherNode::Server(n) => n.add_remote_candidate(id, candidate, now),
        }
    }

    pub fn decapsulate<'s>(
        &mut self,
        local: SocketAddr,
        from: SocketAddr,
        packet: &[u8],
        now: Instant,
        buffer: &'s mut [u8],
    ) -> Result<Option<(u64, MutableIpPacket<'s>)>, snownet::Error> {
        match self {
            EitherNode::Client(n) => n.decapsulate(local, from, packet, now, buffer),
            EitherNode::Server(n) => n.decapsulate(local, from, packet, now, buffer),
        }
    }

    fn handle_timeout(&mut self, now: Instant) {
        match self {
            EitherNode::Client(n) => n.handle_timeout(now),
            EitherNode::Server(n) => n.handle_timeout(now),
        }
    }
}

impl TestNode {
    pub fn new(span: Span, node: EitherNode) -> Self {
        let now = Instant::now();
        TestNode {
            node,
            span,
            progress_count: 0,
            time: now,
            received_packets: vec![],
            buffer: Box::new([0u8; 10_000]),
            connection_state: HashMap::default(),
        }
    }

    fn is_connected_to(&self, id: u64) -> bool {
        self.connection_state.get(&id).copied().unwrap_or_default()
    }
}

fn progress(a1: &mut TestNode, a2: &mut TestNode) {
    let (f, t) = if a1.progress_count % 2 == a2.progress_count % 2 {
        (a2, a1)
    } else {
        (a1, a2)
    };

    t.progress_count += 1;
    if t.progress_count > 100 {
        panic!("Test looped more than 100 times");
    }

    while let Some(v) = t.span.in_scope(|| t.node.poll_event()) {
        match v {
            Event::SignalIceCandidate {
                connection,
                candidate,
            } => f.node.add_remote_candidate(connection, candidate, f.time),
            Event::ConnectionEstablished(id) => {
                *t.connection_state.entry(id).or_default() = true;
            }
            Event::ConnectionFailed(id) => {
                *t.connection_state.entry(id).or_default() = false;
            }
        };
    }

    if let Some(trans) = f.span.in_scope(|| f.node.poll_transmit()) {
        let Some(src) = trans.src else {
            return;
        };

        if let Some((_, packet)) = t
            .span
            .in_scope(|| {
                t.node
                    .decapsulate(trans.dst, src, &trans.payload, t.time, t.buffer.as_mut())
            })
            .unwrap()
        {
            t.received_packets.push(packet.to_owned())
        }
    } else {
        t.span.in_scope(|| t.node.handle_timeout(t.time));
    }

    let tim_f = f.span.in_scope(|| f.node.poll_timeout()).unwrap_or(f.time);
    f.time = tim_f;

    let tim_t = t.span.in_scope(|| t.node.poll_timeout()).unwrap_or(t.time);
    t.time = tim_t;
}
