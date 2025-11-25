#![allow(clippy::unwrap_used)]

use bin_shared::{TunDeviceManager, platform::tcp_socket_factory};
use ip_network::Ipv4Network;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

// Starts up a WinTun device, claims all routes, and checks if we can still make
// TCP connections outside of our tunnel.
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
        .set_routes(
            vec![Ipv4Network::new(Ipv4Addr::UNSPECIFIED, 0).unwrap()],
            vec![],
        )
        .await
        .unwrap();

    let remote = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::from([1, 1, 1, 1]), 80));
    let socket = tcp_socket_factory(remote).unwrap();
    let mut stream = socket.connect(remote).await.unwrap();

    // Send an HTTP request
    stream.write_all("GET /\r\n\r\n".as_bytes()).await.unwrap();
    let mut bytes = vec![];
    stream.read_to_end(&mut bytes).await.unwrap();
    let s = String::from_utf8(bytes).unwrap();

    assert!(s.contains("Bad Request"));
}
