#![allow(clippy::unwrap_used)]

use bin_shared::{TunDeviceManager, platform::UdpSocketFactory};
use bufferpool::BufferPool;
use bytes::BytesMut;
use gat_lending_iterator::LendingIterator as _;
use ip_network::Ipv4Network;
use ip_packet::Ecn;
use socket_factory::DatagramOut;
use socket_factory::SocketFactory as _;
use std::{
    net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4},
    time::Duration,
};

// Starts up a WinTUN device, adds a "full-route" (`0.0.0.0/0`), and checks if we can still send packets to IPs outside of our tunnel.
#[tokio::test]
#[ignore = "Needs admin / sudo and Internet"]
async fn no_packet_loops_udp() {
    logging::test_global("debug"); // `Tun` uses threads and we want to see the logs of all threads.

    let ipv4 = Ipv4Addr::from([100, 90, 215, 97]);
    let ipv6 = Ipv6Addr::from([0xfd00, 0x2021, 0x1111, 0x0, 0x0, 0x0, 0x0016, 0x588f]);

    let bufferpool = BufferPool::<BytesMut>::new(0, "test");

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

    let factory = UdpSocketFactory::default();

    // Make a socket.
    let socket = factory
        .bind(SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0)))
        .unwrap()
        .into_perf()
        .unwrap();

    // Send a STUN request.
    let packet = bufferpool
        .pull_initialised(hex_literal::hex!("000100002112A4420123456789abcdef01234567").as_ref());

    socket
        .send(DatagramOut {
            src: None,
            dst: SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(141, 101, 90, 0), 3478)), // stun.cloudflare.com,
            segment_size: packet.len(),
            packet,
            ecn: Ecn::NonEct,
        })
        .await
        .unwrap();

    let task = async {
        socket.recv_from().await.unwrap().next().unwrap();
    };

    tokio::time::timeout(Duration::from_secs(10), task)
        .await
        .unwrap();
}
