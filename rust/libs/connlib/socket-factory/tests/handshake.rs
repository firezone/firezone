//! Integration tests for [`socket_factory::UdpSocket::handshake`], exercising it through its public API.

#![allow(clippy::unwrap_used)]

#[cfg(target_os = "linux")]
use std::net::{IpAddr, Ipv4Addr};

use socket_factory::udp;

#[tokio::test]
async fn handshake_roundtrips_without_source_ip_resolver() {
    let peer = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let peer_addr = peer.local_addr().unwrap();

    let socket = udp("0.0.0.0:0".parse().unwrap()).unwrap();

    let handshake = tokio::spawn(async move {
        socket
            .handshake::<128, _, _>(peer_addr, b"ping", |r| Ok::<_, &str>(r.to_vec()))
            .await
    });

    let mut buf = [0u8; 128];
    let (len, sender) = peer.recv_from(&mut buf).await.unwrap();
    assert_eq!(&buf[..len], b"ping");

    peer.send_to(b"pong", sender).await.unwrap();

    let response = handshake.await.unwrap().unwrap();
    assert_eq!(response, b"pong");
}

/// The configured source IP resolver determines the source address of the outbound query.
///
/// The resolver returns a second loopback address, so source selection by the operating
/// system (which would pick `127.0.0.1`) cannot produce a false positive. Only Linux
/// has the rest of `127.0.0.0/8` assigned to the loopback interface by default.
#[cfg(target_os = "linux")]
#[tokio::test]
async fn handshake_sends_from_resolved_source_ip() {
    let peer = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let peer_addr = peer.local_addr().unwrap();

    let socket = udp("0.0.0.0:0".parse().unwrap())
        .unwrap()
        .with_source_ip_resolver(Box::new(|_| Ok(IpAddr::from(Ipv4Addr::new(127, 0, 0, 2)))));

    let handshake = tokio::spawn(async move {
        socket
            .handshake::<128, _, _>(peer_addr, b"ping", |r| Ok::<_, &str>(r.to_vec()))
            .await
    });

    let mut buf = [0u8; 128];
    let (len, sender) = peer.recv_from(&mut buf).await.unwrap();
    assert_eq!(&buf[..len], b"ping");
    assert_eq!(sender.ip(), IpAddr::from(Ipv4Addr::new(127, 0, 0, 2)));

    peer.send_to(b"pong", sender).await.unwrap();

    let response = handshake.await.unwrap().unwrap();
    assert_eq!(response, b"pong");
}

/// A failure to resolve the source IP fails the handshake instead of falling back to
/// source selection by the operating system.
#[tokio::test]
async fn handshake_fails_when_source_ip_resolution_fails() {
    let peer = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let peer_addr = peer.local_addr().unwrap();

    let socket = udp("0.0.0.0:0".parse().unwrap())
        .unwrap()
        .with_source_ip_resolver(Box::new(|_| Err(std::io::Error::other("no route"))));

    let error = socket
        .handshake::<128, _, _>(peer_addr, b"ping", |r| Ok::<_, &str>(r.to_vec()))
        .await
        .unwrap_err();

    assert_eq!(error.to_string(), "no route");
}

#[tokio::test]
async fn handshake_ignores_rejected_datagrams() {
    let peer = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let peer_addr = peer.local_addr().unwrap();

    let socket = udp("0.0.0.0:0".parse().unwrap()).unwrap();

    let handshake = tokio::spawn(async move {
        socket
            .handshake::<128, _, _>(peer_addr, b"ping", |r| match r {
                b"pong" => Ok(r.to_vec()),
                _ => Err("not a pong"),
            })
            .await
    });

    let mut buf = [0u8; 128];
    let (_, sender) = peer.recv_from(&mut buf).await.unwrap();

    peer.send_to(b"spoofed", sender).await.unwrap();
    peer.send_to(b"pong", sender).await.unwrap();

    let response = handshake.await.unwrap().unwrap();
    assert_eq!(response, b"pong");
}

#[tokio::test]
async fn handshake_ignores_datagrams_from_other_sources() {
    let peer = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let peer_addr = peer.local_addr().unwrap();
    let other = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();

    let socket = udp("0.0.0.0:0".parse().unwrap()).unwrap();

    let handshake = tokio::spawn(async move {
        socket
            .handshake::<128, _, _>(peer_addr, b"ping", |r| Ok::<_, &str>(r.to_vec()))
            .await
    });

    let mut buf = [0u8; 128];
    let (_, sender) = peer.recv_from(&mut buf).await.unwrap();

    other.send_to(b"spoofed", sender).await.unwrap();
    peer.send_to(b"pong", sender).await.unwrap();

    let response = handshake.await.unwrap().unwrap();
    assert_eq!(response, b"pong");
}
