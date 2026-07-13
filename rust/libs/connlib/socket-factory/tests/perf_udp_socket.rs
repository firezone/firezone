//! Integration tests for [`socket_factory::PerfUdpSocket`], exercising it through its public API.

use bufferpool::BufferPool;
use gat_lending_iterator::LendingIterator as _;
use ip_packet::Ecn;
use socket_factory::{DatagramOut, udp};

/// A datagram sent to a fresh peer round-trips: the peer receives it and the reply is
/// delivered back through the same [`PerfUdpSocket`](socket_factory::PerfUdpSocket).
///
/// On Apple this goes out over a connected per-destination flow socket (see the assertion
/// below); on every other platform it uses the single catch-all socket.
#[tokio::test]
async fn sends_and_receives_a_datagram() {
    let peer = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let peer_addr = peer.local_addr().unwrap();

    let socket = udp("127.0.0.1:0".parse().unwrap())
        .unwrap()
        .into_perf()
        .unwrap();

    let pool = BufferPool::<Vec<u8>>::new(2048, "test");

    socket
        .send(DatagramOut {
            src: None,
            dst: peer_addr,
            packet: pool.pull_initialised(b"hello"),
            segment_size: 5,
            ecn: Ecn::NonEct,
        })
        .await
        .unwrap();

    // On Apple, the send must go out over a connected flow socket - not silently fall back to
    // the catch-all. A count of 0 would mean `connect()` failed (e.g. the catch-all lacked
    // `SO_REUSEPORT`) and the fast path latched off.
    #[cfg(apple)]
    assert_eq!(socket.flow_socket_count(), 1);

    let mut buf = [0u8; 16];
    let (len, from) = peer.recv_from(&mut buf).await.unwrap();
    assert_eq!(&buf[..len], b"hello");

    // The reply matches the (connected) socket's 4-tuple exactly and must be delivered via it.
    peer.send_to(b"world", from).await.unwrap();

    let mut iter = socket.recv_from().await.unwrap();
    let datagram = iter.next().unwrap();

    assert_eq!(datagram.packet, b"world");
    assert_eq!(datagram.from, peer_addr);
}
