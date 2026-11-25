//! Integration tests for [`socket_factory::UdpSocket::connect`], exercising it through its public API.

#![allow(clippy::unwrap_used)]

#[cfg(target_os = "linux")]
use std::net::{IpAddr, Ipv4Addr};

use socket_factory::udp;

#[tokio::test]
async fn connected_socket_roundtrips_without_source_ip_resolver() {
    let peer = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let peer_addr = peer.local_addr().unwrap();

    let socket = udp("0.0.0.0:0".parse().unwrap())
        .unwrap()
        .connect(peer_addr)
        .await
        .unwrap();
    socket.send(b"ping").await.unwrap();

    let mut buf = [0u8; 128];
    let (len, sender) = peer.recv_from(&mut buf).await.unwrap();
    assert_eq!(&buf[..len], b"ping");

    peer.send_to(b"pong", sender).await.unwrap();

    let len = socket.recv(&mut buf).await.unwrap();
    assert_eq!(&buf[..len], b"pong");
}

/// The configured source IP resolver determines the source address of the connected socket.
///
/// The resolver returns a second loopback address, so source selection by the operating
/// system (which would pick `127.0.0.1`) cannot produce a false positive. Only Linux
/// has the rest of `127.0.0.0/8` assigned to the loopback interface by default.
#[cfg(target_os = "linux")]
#[tokio::test]
async fn connected_socket_sends_from_resolved_source_ip() {
    let peer = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let peer_addr = peer.local_addr().unwrap();

    let socket = udp("0.0.0.0:0".parse().unwrap())
        .unwrap()
        .with_source_ip_resolver(Box::new(|_| Ok(IpAddr::from(Ipv4Addr::new(127, 0, 0, 2)))))
        .connect(peer_addr)
        .await
        .unwrap();
    socket.send(b"ping").await.unwrap();

    let mut buf = [0u8; 128];
    let (len, sender) = peer.recv_from(&mut buf).await.unwrap();
    assert_eq!(&buf[..len], b"ping");
    assert_eq!(sender.ip(), IpAddr::from(Ipv4Addr::new(127, 0, 0, 2)));

    peer.send_to(b"pong", sender).await.unwrap();

    let len = socket.recv(&mut buf).await.unwrap();
    assert_eq!(&buf[..len], b"pong");
}

/// A failure to resolve the source IP fails the connect instead of falling back to
/// source selection by the operating system.
#[tokio::test]
async fn connect_fails_when_source_ip_resolution_fails() {
    let peer = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let peer_addr = peer.local_addr().unwrap();

    let result = udp("0.0.0.0:0".parse().unwrap())
        .unwrap()
        .with_source_ip_resolver(Box::new(|_| Err(std::io::Error::other("no route"))))
        .connect(peer_addr)
        .await;

    assert_eq!(result.err().unwrap().to_string(), "no route");
}

#[tokio::test]
async fn connected_socket_ignores_datagrams_from_other_sources() {
    let peer = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let peer_addr = peer.local_addr().unwrap();
    let other = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();

    let socket = udp("0.0.0.0:0".parse().unwrap())
        .unwrap()
        .connect(peer_addr)
        .await
        .unwrap();
    socket.send(b"ping").await.unwrap();

    let mut buf = [0u8; 128];
    let (_, sender) = peer.recv_from(&mut buf).await.unwrap();

    other.send_to(b"spoofed", sender).await.unwrap();
    peer.send_to(b"pong", sender).await.unwrap();

    let len = socket.recv(&mut buf).await.unwrap();
    assert_eq!(&buf[..len], b"pong");
}
