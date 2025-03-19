#![allow(clippy::unwrap_used)]

use firezone_bin_shared::{TunDeviceManager, platform::udp_socket_factory};
use ip_network::Ipv4Network;
use socket_factory::DatagramOut;
use std::{
    net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4},
    time::Duration,
};

// Starts up a WinTUN device, adds a "full-route" (`0.0.0.0/0`), and checks if we can still send packets to IPs outside of our tunnel.
#[tokio::test]
#[ignore = "Needs admin / sudo and Internet"]
async fn no_packet_loops_udp() {
    firezone_logging::test_global("debug"); // `Tun` uses threads and we want to see the logs of all threads.

    let ipv4 = Ipv4Addr::from([100, 90, 215, 97]);
    let ipv6 = Ipv6Addr::from([0xfd00, 0x2021, 0x1111, 0x0, 0x0, 0x0, 0x0016, 0x588f]);

    let mut device_manager = TunDeviceManager::new(1280, 1).unwrap();
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

    // Make a socket.
    let mut socket =
        udp_socket_factory(&SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0))).unwrap();

    std::future::poll_fn(|cx| socket.poll_send_ready(cx))
        .await
        .unwrap();

    // Send a STUN request.
    socket
        .send(DatagramOut {
            src: None,
            dst: SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(141, 101, 90, 0), 3478)), // stun.cloudflare.com,
            packet: &hex_literal::hex!("000100002112A4420123456789abcdef01234567").as_ref(),
            segment_size: None,
        })
        .unwrap();

    let task = std::future::poll_fn(|cx| {
        let mut buf = [0u8; 1000];
        let result = std::task::ready!(socket.poll_recv_from(&mut buf, cx));

        let _response = result.unwrap().next().unwrap();

        std::task::Poll::Ready(())
    });

    tokio::time::timeout(Duration::from_secs(10), task)
        .await
        .unwrap();
}
