use boringtun::x25519::StaticSecret;
use snownet::{ClientNode, Event};
use std::{
    collections::HashSet,
    net::{Ipv4Addr, SocketAddr, SocketAddrV4},
    time::{Duration, Instant},
};

#[test]
fn connection_times_out_after_10_seconds() {
    let start = Instant::now();

    let mut alice =
        ClientNode::<u64>::new(StaticSecret::random_from_rng(rand::thread_rng()), start);

    let _ = alice.new_connection(1, HashSet::new(), HashSet::new());
    alice.handle_timeout(start + Duration::from_secs(10));

    assert_eq!(alice.poll_event().unwrap(), Event::ConnectionFailed(1));
}

#[test]
fn reinitialize_allocation_if_credentials_for_relay_differ() {
    let mut alice = ClientNode::<u64>::new(
        StaticSecret::random_from_rng(rand::thread_rng()),
        Instant::now(),
    );

    // Make a new connection that uses RELAY with initial set of credentials
    let _ = alice.new_connection(
        1,
        HashSet::new(),
        HashSet::from([relay("user1", "pass1", "realm1")]),
    );

    let transmit = alice.poll_transmit().unwrap();
    assert_eq!(transmit.dst, RELAY);
    assert!(alice.poll_transmit().is_none());

    // Make another connection, using the same relay but different credentials (happens when the relay restarts)

    let _ = alice.new_connection(
        2,
        HashSet::new(),
        HashSet::from([relay("user2", "pass2", "realm1")]),
    );

    // Expect to send another message to the "new" relay
    let transmit = alice.poll_transmit().unwrap();
    assert_eq!(transmit.dst, RELAY);
    assert_eq!(&transmit.payload[..2], [0x0, 0x3]); // `ALLOCATE` is 0x0003: https://www.rfc-editor.org/rfc/rfc8656#name-stun-methods
    assert!(alice.poll_transmit().is_none());
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

fn relay(username: &str, pass: &str, realm: &str) -> (SocketAddr, String, String, String) {
    (
        RELAY,
        username.to_owned(),
        pass.to_owned(),
        realm.to_owned(),
    )
}

const RELAY: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 10000));
