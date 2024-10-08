use secrecy::Secret;
use snownet::{ClientNode, Credentials, Event, ServerNode};
use std::{
    iter,
    net::SocketAddr,
    time::{Duration, Instant},
};
use str0m::{net::Protocol, Candidate};

#[test]
fn connection_without_candidates_times_out_after_10_seconds() {
    let _guard = firezone_logging::test("trace");
    let start = Instant::now();

    let (mut alice, mut bob) = alice_and_bob();
    handshake(&mut alice, &mut bob, start);

    alice.handle_timeout(start + Duration::from_secs(10));

    assert_eq!(alice.poll_event().unwrap(), Event::ConnectionFailed(1));
}

#[test]
fn connection_with_candidates_does_not_time_out_after_10_seconds() {
    let _guard = firezone_logging::test("trace");
    let start = Instant::now();

    let (mut alice, mut bob) = alice_and_bob();
    handshake(&mut alice, &mut bob, start);

    alice.add_local_host_candidate(s("10.0.0.2:4444")).unwrap();
    alice.add_remote_candidate(1, host("10.0.0.1:4444"), start);

    alice.handle_timeout(start + Duration::from_secs(10));

    let any_failed =
        iter::from_fn(|| alice.poll_event()).any(|e| matches!(e, Event::ConnectionFailed(_)));

    assert!(!any_failed);
}

fn alice_and_bob() -> (ClientNode<u64, u64>, ServerNode<u64, u64>) {
    let alice = ClientNode::new(rand::random());
    let bob = ServerNode::new(rand::random());

    (alice, bob)
}

fn handshake(alice: &mut ClientNode<u64, u64>, bob: &mut ServerNode<u64, u64>, now: Instant) {
    alice.upsert_connection(
        1,
        bob.public_key(),
        Secret::new([0u8; 32]),
        Credentials {
            username: "foo".to_owned(),
            password: "foo".to_owned(),
        },
        Credentials {
            username: "bar".to_owned(),
            password: "bar".to_owned(),
        },
        now,
    );
    bob.upsert_connection(
        1,
        alice.public_key(),
        Secret::new([0u8; 32]),
        Credentials {
            username: "bar".to_owned(),
            password: "bar".to_owned(),
        },
        Credentials {
            username: "foo".to_owned(),
            password: "foo".to_owned(),
        },
        now,
    );
}

fn host(socket: &str) -> String {
    Candidate::host(s(socket), Protocol::Udp)
        .unwrap()
        .to_sdp_string()
}

fn s(socket: &str) -> SocketAddr {
    socket.parse().unwrap()
}
