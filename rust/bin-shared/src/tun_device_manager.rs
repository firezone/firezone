//! DNS and route control  for the virtual network interface in `firezone-tunnel`

#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(target_os = "linux")]
pub use linux as platform;

#[cfg(target_os = "windows")]
pub mod windows;
#[cfg(target_os = "windows")]
pub use windows as platform;

#[cfg(any(target_os = "linux", target_os = "windows"))]
pub use platform::TunDeviceManager;

#[cfg(test)]
#[cfg(any(target_os = "linux", target_os = "windows"))]
mod tests {
    use super::*;
    use ip_network::Ipv4Network;
    use socket_factory::DatagramOut;
    use std::{
        borrow::Cow,
        net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4},
        time::Duration,
    };
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

    #[tokio::test]
    #[ignore = "Needs admin / sudo and Internet"]
    async fn tunnel() {
        let _guard = firezone_logging::test("debug");

        no_packet_loops_tcp().await;
        no_packet_loops_udp().await;
        tunnel_drop();
    }

    // Starts up a WinTun device, claims all routes, and checks if we can still make
    // TCP connections outside of our tunnel.
    async fn no_packet_loops_tcp() {
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
        let socket = crate::platform::tcp_socket_factory(&remote).unwrap();
        let mut stream = socket.connect(remote).await.unwrap();

        // Send an HTTP request
        stream.write_all("GET /\r\n\r\n".as_bytes()).await.unwrap();
        let mut bytes = vec![];
        stream.read_to_end(&mut bytes).await.unwrap();
        let s = String::from_utf8(bytes).unwrap();
        assert_eq!(s, "<html>\r\n<head><title>400 Bad Request</title></head>\r\n<body>\r\n<center><h1>400 Bad Request</h1></center>\r\n<hr><center>cloudflare</center>\r\n</body>\r\n</html>\r\n");
    }

    // Starts up a WinTUN device, adds a "full-route" (`0.0.0.0/0`), and checks if we can still send packets to IPs outside of our tunnel.
    async fn no_packet_loops_udp() {
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

        // Make a socket.
        let mut socket = crate::platform::udp_socket_factory(&SocketAddr::V4(SocketAddrV4::new(
            Ipv4Addr::UNSPECIFIED,
            0,
        )))
        .unwrap();

        std::future::poll_fn(|cx| socket.poll_send_ready(cx))
            .await
            .unwrap();

        // Send a STUN request.
        socket
            .send(DatagramOut {
                src: None,
                dst: SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(141, 101, 90, 0), 3478)), // stun.cloudflare.com,
                packet: Cow::Borrowed(&hex_literal::hex!(
                    "000100002112A4420123456789abcdef01234567"
                )),
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

    /// Checks for regressions in issue #4765, un-initializing Wintun
    /// Redundant but harmless on Linux.
    fn tunnel_drop() {
        let mut tun_device_manager = TunDeviceManager::new(1280).unwrap();

        // Each cycle takes about half a second, so this will take a fair bit to run.
        for _ in 0..50 {
            let _tun = tun_device_manager.make_tun().unwrap(); // This will panic if we don't correctly clean-up the wintun interface.
        }
    }
}
