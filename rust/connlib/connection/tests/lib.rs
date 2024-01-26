use boringtun::x25519::StaticSecret;
use firezone_connection::{ClientConnectionPool, Event};
use std::{
    collections::HashSet,
    time::{Duration, Instant},
};

#[test]
fn connection_times_out_after_10_seconds() {
    let start = Instant::now();

    let mut alice =
        ClientConnectionPool::<u64>::new(StaticSecret::random_from_rng(rand::thread_rng()), start);

    let _ = alice.new_connection(1, HashSet::new(), HashSet::new());
    alice.handle_timeout(start + Duration::from_secs(10));

    assert_eq!(alice.poll_event().unwrap(), Event::ConnectionFailed(1));
}
