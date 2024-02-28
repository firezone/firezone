use boringtun::x25519::StaticSecret;
use snownet::{ClientNode, Event, ServerNode};
use std::{
    collections::HashSet,
    iter,
    net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4},
    time::{Duration, Instant},
};
use str0m::{net::Protocol, Candidate};

#[test]
fn connection_times_out_after_20_seconds() {
    let start = Instant::now();

    let (mut alice, _) = alice_and_bob(start);

    let _ = alice.new_connection(1, HashSet::new(), HashSet::new());
    alice.handle_timeout(start + Duration::from_secs(20));

    assert_eq!(alice.poll_event().unwrap(), Event::ConnectionFailed(1));
}

#[test]
fn answer_after_stale_connection_does_not_panic() {
    let start = Instant::now();

    let (mut alice, mut bob) = alice_and_bob(start);

    let offer = alice.new_connection(1, HashSet::new(), HashSet::new());
    let answer =
        bob.accept_connection(1, offer, alice.public_key(), HashSet::new(), HashSet::new());

    alice.handle_timeout(start + Duration::from_secs(10));

    alice.accept_answer(1, bob.public_key(), answer);
}

#[test]
fn only_generate_candidate_event_after_answer() {
    let local_candidate = SocketAddr::new(IpAddr::from(Ipv4Addr::LOCALHOST), 10000);

    let mut alice = ClientNode::<u64>::new(
        StaticSecret::random_from_rng(rand::thread_rng()),
        Instant::now(),
    );

    alice.add_local_host_candidate(local_candidate).unwrap();

    let mut bob = ServerNode::<u64>::new(
        StaticSecret::random_from_rng(rand::thread_rng()),
        Instant::now(),
    );

    let offer = alice.new_connection(1, HashSet::new(), HashSet::new());

    assert_eq!(
        alice.poll_event(),
        None,
        "no event to be emitted before accepting the answer"
    );

    let answer =
        bob.accept_connection(1, offer, alice.public_key(), HashSet::new(), HashSet::new());

    alice.accept_answer(1, bob.public_key(), answer);

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
    let mut alice = ClientNode::<u64>::new(
        StaticSecret::random_from_rng(rand::thread_rng()),
        Instant::now(),
    );

    let _ = alice.new_connection(
        1,
        HashSet::new(),
        HashSet::from([relay("user1", "pass1", "realm1")]),
    );

    let transmit = alice.poll_transmit().unwrap();
    assert_eq!(transmit.dst, RELAY);
    assert!(alice.poll_transmit().is_none());

    let _ = alice.new_connection(
        2,
        HashSet::new(),
        HashSet::from([relay("user1", "pass1", "realm1")]),
    );

    assert!(alice.poll_transmit().is_none());
}

fn alice_and_bob(start: Instant) -> (ClientNode<u64>, ServerNode<u64>) {
    let alice = ClientNode::<u64>::new(StaticSecret::random_from_rng(rand::thread_rng()), start);
    let bob = ServerNode::<u64>::new(StaticSecret::random_from_rng(rand::thread_rng()), start);

    (alice, bob)
}

fn relay(username: &str, pass: &str, realm: &str) -> (SocketAddr, String, String, String) {
    (
        RELAY,
        username.to_owned(),
        pass.to_owned(),
        realm.to_owned(),
    )
}

const RELAY: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 10000));
