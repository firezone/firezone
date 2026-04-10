#![allow(clippy::unwrap_used)]

use bin_shared::{TunDeviceManager, platform::tcp_socket_factory};
use ip_network::Ipv4Network;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

// Starts up a WinTun device, claims all routes, and checks if we can still make
// TCP connections outside of our tunnel.
//
// The destination must be genuinely remote: on Windows, `tcp_socket_factory`
// rewrites the host route for the destination IP via the physical interface,
// which breaks any attempt to connect to the machine's own IP (Windows refuses
// to loop self-traffic back when it's been routed out the wire).
#[tokio::test]
#[ignore = "Needs admin / sudo and Internet"]
async fn no_packet_loops_tcp() {
    logging::test_global("debug"); // `Tun` uses threads and we want to see the logs of all threads.

    let ipv4 = Ipv4Addr::from([100, 90, 215, 97]);
    let ipv6 = Ipv6Addr::from([0xfd00, 0x2021, 0x1111, 0x0, 0x0, 0x0, 0x0016, 0x588f]);

    let mut device_manager = TunDeviceManager::new(1280).unwrap();
    let _tun = device_manager.make_tun().unwrap();
    device_manager.set_ips(ipv4, ipv6).await.unwrap();

    // Configure `0.0.0.0/0` route.
    device_manager
        .set_routes(vec![
            Ipv4Network::new(Ipv4Addr::UNSPECIFIED, 0).unwrap().into(),
        ])
        .await
        .unwrap();

    let remote = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::from([1, 1, 1, 1]), 80));
    let socket = tcp_socket_factory(remote).unwrap();
    let mut stream = socket.connect(remote).await.unwrap();

    // Send a well-formed HTTP/1.0 request so the server doesn't just hang up.
    // We don't care about the response body — only that bytes flow back, which
    // proves the TCP handshake completed and the socket bypassed the TUN.
    stream
        .write_all(b"GET / HTTP/1.0\r\nHost: 1.1.1.1\r\n\r\n")
        .await
        .unwrap();
    let mut bytes = vec![];
    stream.read_to_end(&mut bytes).await.unwrap();

    assert!(
        bytes.starts_with(b"HTTP/1."),
        "Expected an HTTP response, got {} bytes: {:?}",
        bytes.len(),
        String::from_utf8_lossy(&bytes),
    );
}
