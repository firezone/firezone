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
    use tracing_subscriber::EnvFilter;

    #[tokio::test]
    #[ignore = "Needs admin / sudo and Internet"]
    async fn tunnel() {
        let _ = tracing_subscriber::fmt()
            .with_env_filter(EnvFilter::from_default_env())
            .with_test_writer()
            .try_init();

        no_packet_loops().await;
        tunnel_drop();
    }

    // Starts up a WinTUN device, adds a "full-route" (`0.0.0.0/0`) and checks if we can still send packets to IPs outside of our tunnel.
    async fn no_packet_loops() {
        let ipv4 = Ipv4Addr::from([100, 90, 215, 97]);
        let ipv6 = Ipv6Addr::from([0xfd00, 0x2021, 0x1111, 0x0, 0x0, 0x0, 0x0016, 0x588f]);

        let mut device_manager = TunDeviceManager::new().unwrap();
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

        // Send a STUN request.
        socket
            .send(DatagramOut {
                src: None,
                dst: SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(141, 101, 90, 0), 3478)), // stun.cloudflare.com,
                packet: Cow::Borrowed(&hex_literal::hex!(
                    "000100002112A4420123456789abcdef01234567"
                )),
            })
            .unwrap();

        // First send seems to always result as would block
        std::future::poll_fn(|cx| socket.poll_flush(cx))
            .await
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
        // Each cycle takes about half a second, so this will take a fair bit to run.
        for _ in 0..50 {
            let _tun = platform::Tun::new().unwrap(); // This will panic if we don't correctly clean-up the wintun interface.
        }
    }
}
