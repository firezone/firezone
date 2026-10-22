//! Integration tests for [`socket_factory::PerfUdpSocket`], exercising it through its public API.

use ip_packet::Ecn;
use socket_factory::{DatagramOut, udp};

/// Datagrams sent to a fresh peer round-trip: the peer receives them and the reply is
/// delivered back through the same [`PerfUdpSocket`](socket_factory::PerfUdpSocket).
///
/// The batch is big enough to promote the pair to a connected flow socket on Apple (see
/// the assertion below); on every other platform everything uses the single catch-all
/// socket.
#[tokio::test]
async fn sends_and_receives_a_datagram() {
    const DATAGRAMS: usize = 16;

    let peer = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let peer_addr = peer.local_addr().unwrap();

    let socket = udp("127.0.0.1:0".parse().unwrap())
        .unwrap()
        .into_perf()
        .unwrap();

    socket
        .send(DatagramOut {
            src: None,
            dst: peer_addr,
            packet: bufferpool::Bytes::copied_from(&b"hello".repeat(DATAGRAMS)),
            len: 5 * DATAGRAMS,
            segment_size: 5,
            ecn: Ecn::NonEct,
        })
        .await
        .unwrap();

    // On Apple, a batch of `DATAGRAMS` datagrams must connect a flow socket - not
    // silently fall back to the catch-all. A count of 0 would mean `connect()` failed
    // (e.g. the catch-all lacked `SO_REUSEPORT`) and the fast path latched off.
    #[cfg(apple)]
    assert_eq!(socket.flow_socket_count(), 1);

    let mut buf = [0u8; 16];
    let mut from = peer_addr;
    for _ in 0..DATAGRAMS {
        let (len, sender) = peer.recv_from(&mut buf).await.unwrap();
        assert_eq!(&buf[..len], b"hello");
        from = sender;
    }

    // The reply matches the (connected) socket's 4-tuple exactly and must be delivered via it.
    peer.send_to(b"world", from).await.unwrap();

    let mut batch = socket.recv_from().await.unwrap();
    let datagram = batch.drain().next().unwrap();
    let segment = datagram.segments().next().unwrap();

    assert_eq!(&datagram[segment], b"world");
    assert_eq!(datagram.from(), peer_addr);
}

/// ICMP errors from sending to a closed port must not fill the receive buffer and starve every
/// later receive.
#[cfg(target_os = "linux")]
#[tokio::test]
async fn receives_after_many_icmp_errors() {
    let closed_addr = std::net::UdpSocket::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap();
    let peer = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();

    let socket = udp("127.0.0.1:0".parse().unwrap()).unwrap();
    let socket_addr = socket2::SockRef::from(&socket)
        .local_addr()
        .unwrap()
        .as_socket()
        .unwrap();
    let mut socket = socket.into_perf().unwrap();
    socket.set_buffer_sizes(64 * 1024, 16 * 1024);

    for _ in 0..1000 {
        let _ = socket
            .send(DatagramOut {
                src: None,
                dst: closed_addr,
                packet: bufferpool::Bytes::copied_from(&[0; 1200]),
                len: 1200,
                segment_size: 1200,
                ecn: Ecn::NonEct,
            })
            .await;
    }

    peer.send_to(&[1; 1200], socket_addr).await.unwrap();

    let mut batch = tokio::time::timeout(std::time::Duration::from_secs(1), async {
        loop {
            if let Ok(batch) = socket.recv_from().await {
                break batch;
            }
        }
    })
    .await
    .expect("datagram should be received");

    let datagram = batch.drain().next().unwrap();
    assert_eq!(datagram.from(), peer.local_addr().unwrap());
}
