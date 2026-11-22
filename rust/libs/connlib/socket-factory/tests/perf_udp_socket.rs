//! Integration tests for [`socket_factory::PerfUdpSocket`], exercising it through its public API.

#![allow(clippy::unwrap_used)]

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

    let socket = udp("127.0.0.1:0".parse().unwrap()).unwrap().into_perf();

    socket
        .send(DatagramOut {
            src: None,
            dst: peer_addr,
            packet: bufferpool::Bytes::copied_from(&b"hello".repeat(DATAGRAMS)),
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

#[cfg(apple)]
#[tokio::test]
async fn explicit_source_round_trips_before_and_after_promotion() {
    let peer = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let peer_addr = peer.local_addr().unwrap();
    let socket = udp("0.0.0.0:0".parse().unwrap()).unwrap();
    let port = socket2::SockRef::from(&socket)
        .local_addr()
        .unwrap()
        .as_socket()
        .unwrap()
        .port();
    let socket = socket.into_perf();
    let source = std::net::SocketAddr::from(([127, 0, 0, 1], port));

    for datagrams in [1, 16] {
        socket
            .send(DatagramOut {
                src: Some(source),
                dst: peer_addr,
                packet: bufferpool::Bytes::copied_from(&b"hello".repeat(datagrams)),
                segment_size: 5,
                ecn: Ecn::NonEct,
            })
            .await
            .unwrap();

        assert_eq!(
            socket.flow_socket_count(),
            if datagrams == 16 { 1 } else { 0 }
        );
        let mut buf = [0u8; 16];
        for _ in 0..datagrams {
            let (len, sender) =
                tokio::time::timeout(std::time::Duration::from_secs(3), peer.recv_from(&mut buf))
                    .await
                    .unwrap()
                    .unwrap();
            assert_eq!(&buf[..len], b"hello");
            assert_eq!(sender, source);
        }

        peer.send_to(b"world", source).await.unwrap();
        let mut batch = tokio::time::timeout(std::time::Duration::from_secs(3), socket.recv_from())
            .await
            .unwrap()
            .unwrap();
        let datagram = batch.drain().next().unwrap();
        let segment = datagram.segments().next().unwrap();
        assert_eq!(&datagram[segment], b"world");
        assert_eq!(datagram.from(), peer_addr);
    }
}

/// A receive that is already parked must wake up for a flow socket created after it started.
#[cfg(apple)]
#[tokio::test]
async fn pending_receive_wakes_for_a_new_flow_socket() {
    let peer = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let peer_addr = peer.local_addr().unwrap();
    let socket = std::sync::Arc::new(udp("127.0.0.1:0".parse().unwrap()).unwrap().into_perf());

    let recv = tokio::spawn({
        let socket = socket.clone();

        async move { recv_datagram(&socket).await }
    });
    tokio::task::yield_now().await; // Let the receive park before the flow socket exists.

    let from = promote(&socket, &peer).await;
    assert_eq!(socket.flow_socket_count(), 1);
    peer.send_to(b"world", from).await.unwrap();

    let received = tokio::time::timeout(TIMEOUT, recv).await.unwrap().unwrap();
    assert_eq!(received, (b"world".to_vec(), peer_addr));
}

/// An evicted flow socket's queued datagrams are still delivered, and once it is closed,
/// later datagrams from its peer arrive via the catch-all.
#[cfg(apple)]
#[tokio::test]
async fn eviction_delivers_queued_datagrams_and_closes_the_flow_socket() {
    const MAX_FLOW_SOCKETS: usize = 16; // `MAX_FLOW_SOCKETS` in `pool::apple`.

    let socket = udp("127.0.0.1:0".parse().unwrap()).unwrap().into_perf();
    let mut peers = Vec::new();
    for _ in 0..MAX_FLOW_SOCKETS {
        peers.push(tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap());
    }
    let mut from = None;
    for peer in &peers {
        from = Some(promote(&socket, peer).await);
    }
    let from = from.unwrap();
    assert_eq!(socket.flow_socket_count(), MAX_FLOW_SOCKETS);

    // Nothing has been received yet, so the oldest flow socket, the first peer's, is evicted next.
    let first = &peers[0];
    first.send_to(b"queued", from).await.unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(100)).await; // Let loopback deliver it.

    let last = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    promote(&socket, &last).await;
    assert_eq!(socket.flow_socket_count(), MAX_FLOW_SOCKETS);

    let first_addr = first.local_addr().unwrap();
    assert_eq!(
        recv_datagram(&socket).await,
        (b"queued".to_vec(), first_addr)
    );

    first.send_to(b"after", from).await.unwrap();
    assert_eq!(
        recv_datagram(&socket).await,
        (b"after".to_vec(), first_addr)
    );
}

/// Datagrams queued on a flow socket and on the catch-all at the same time are both delivered.
#[cfg(apple)]
#[tokio::test]
async fn receives_from_flow_and_catch_all_sockets() {
    let flow_peer = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let other_peer = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let socket = udp("127.0.0.1:0".parse().unwrap()).unwrap().into_perf();

    let from = promote(&socket, &flow_peer).await;
    assert_eq!(socket.flow_socket_count(), 1);
    flow_peer.send_to(b"flow", from).await.unwrap();
    other_peer.send_to(b"catch-all", from).await.unwrap();

    let mut senders = tokio::time::timeout(TIMEOUT, async {
        let mut senders = Vec::new();
        while senders.len() < 2 {
            let mut batch = socket.recv_from().await.unwrap();
            senders.extend(batch.drain().map(|datagram| datagram.from()));
        }

        senders
    })
    .await
    .unwrap();
    senders.sort();

    let mut expected = [
        flow_peer.local_addr().unwrap(),
        other_peer.local_addr().unwrap(),
    ];
    expected.sort();
    assert_eq!(senders, expected);
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
    let mut socket = socket.into_perf();
    socket.set_buffer_sizes(64 * 1024, 16 * 1024);

    for _ in 0..1000 {
        let _ = socket
            .send(DatagramOut {
                src: None,
                dst: closed_addr,
                packet: bufferpool::Bytes::copied_from(&[0; 1200]),
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

#[cfg(apple)]
const TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);

/// Sends `peer` a batch big enough to promote it to a flow socket and returns the address the
/// peer received it from.
#[cfg(apple)]
async fn promote(
    socket: &socket_factory::PerfUdpSocket,
    peer: &tokio::net::UdpSocket,
) -> std::net::SocketAddr {
    const DATAGRAMS: usize = 16;

    socket
        .send(DatagramOut {
            src: None,
            dst: peer.local_addr().unwrap(),
            packet: bufferpool::Bytes::copied_from(&b"hello".repeat(DATAGRAMS)),
            segment_size: 5,
            ecn: Ecn::NonEct,
        })
        .await
        .unwrap();

    let mut buf = [0u8; 16];
    let mut from = None;
    for _ in 0..DATAGRAMS {
        let (_, sender) = tokio::time::timeout(TIMEOUT, peer.recv_from(&mut buf))
            .await
            .unwrap()
            .unwrap();
        from = Some(sender);
    }

    from.unwrap()
}

/// Receives the next datagram, returning its payload and sender.
#[cfg(apple)]
async fn recv_datagram(socket: &socket_factory::PerfUdpSocket) -> (Vec<u8>, std::net::SocketAddr) {
    let mut batch = tokio::time::timeout(TIMEOUT, socket.recv_from())
        .await
        .unwrap()
        .unwrap();
    let datagram = batch.drain().next().unwrap();
    let segment = datagram.segments().next().unwrap();

    (datagram[segment].to_vec(), datagram.from())
}
