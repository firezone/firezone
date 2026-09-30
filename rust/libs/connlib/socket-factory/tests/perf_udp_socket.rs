//! Integration tests for [`socket_factory::PerfUdpSocket`], exercising it through its public API.

use bufferpool::BufferPool;
use ip_packet::Ecn;
use socket_factory::{DatagramOut, udp};

/// Datagrams sent to a fresh peer round-trip: the peer receives them and the reply is
/// delivered back through the same [`PerfUdpSocket`](socket_factory::PerfUdpSocket).
#[tokio::test]
async fn sends_and_receives_a_datagram() {
    const DATAGRAMS: usize = 16;

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
            packet: pool.pull_initialised(&b"hello".repeat(DATAGRAMS)),
            segment_size: 5,
            ecn: Ecn::NonEct,
        })
        .await
        .unwrap();

    let mut buf = [0u8; 16];
    let mut from = peer_addr;
    for _ in 0..DATAGRAMS {
        let (len, sender) = peer.recv_from(&mut buf).await.unwrap();
        assert_eq!(&buf[..len], b"hello");
        from = sender;
    }

    peer.send_to(b"world", from).await.unwrap();

    let mut batch = socket.recv_from().await.unwrap();
    let datagram = batch.drain().next().unwrap();

    assert_eq!(datagram.packet, b"world");
    assert_eq!(datagram.from, peer_addr);
}
