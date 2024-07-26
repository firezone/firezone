//! Implementation of headless Client and IPC service for Windows
//!
//! Try not to panic in the IPC service. Windows doesn't consider the
//! service to be stopped even if its only process ends, for some reason.
//! We must tell Windows explicitly when our service is stopping.

use anyhow::Result;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};

use firezone_bin_shared::TUNNEL_NAME;
use socket_factory::{TcpSocket, UdpSocket};

pub fn tcp_socket_factory(addr: &SocketAddr) -> io::Result<TcpSocket> {
    let local =
        get_best_non_tunnel_route(addr.ip())?.ok_or(io::Error::other("No route to host"))?;

    let socket = socket_factory::tcp(addr)?;
    socket.bind((local, 0).into())?; // To avoid routing loops, all TCP sockets are bound to "best" source IP.

    Ok(socket)
}

pub fn udp_socket_factory(src_addr: &SocketAddr) -> io::Result<UdpSocket> {
    let socket =
        socket_factory::udp(src_addr)?.with_source_ip_resolver(Box::new(get_best_non_tunnel_route));

    Ok(socket)
}

fn get_best_non_tunnel_route(dst: IpAddr) -> io::Result<Option<IpAddr>> {
    let src = get_best_route_excluding_interface(dst, TUNNEL_NAME)
        .ok_or(io::Error::other("No route to host"))?;

    tracing::debug!(%src, %dst, "Resolved best route outside of tunnel interface");

    Ok(Some(src))
}

/// Finds the best route (i.e. source interface) for a given destination IP, excluding interfaces where the name matches the given filter.
///
/// To prevent routing loops on Windows, we need to explicitly set a source IP for all packets.
/// Windows uses a computed metric per interface for routing.
/// We implement the same logic here, with the addition of explicitly filtering out our TUN interface.
///
/// # Performance
///
/// This function performs multiple syscalls and is thus fairly expensive.
/// It should **not** be called on a per-packet basis.
/// Callers should instead cache the result until network interfaces change.
fn get_best_route_excluding_interface(dst: IpAddr, filter: &str) -> Option<IpAddr> {
    use std::mem::MaybeUninit;
    use std::net::{Ipv4Addr, Ipv6Addr};
    use std::ptr::null;

    use windows::Win32::NetworkManagement::IpHelper::GetAdaptersAddresses;
    use windows::Win32::NetworkManagement::IpHelper::GetBestRoute2;
    use windows::Win32::NetworkManagement::IpHelper::GET_ADAPTERS_ADDRESSES_FLAGS;
    use windows::Win32::NetworkManagement::IpHelper::IP_ADAPTER_ADDRESSES_LH;
    use windows::Win32::NetworkManagement::IpHelper::MIB_IPFORWARD_ROW2;
    use windows::Win32::Networking::WinSock::ADDRESS_FAMILY;
    use windows::Win32::Networking::WinSock::AF_UNSPEC;
    use windows::Win32::Networking::WinSock::SOCKADDR_INET;
    // SAFETY: lol
    unsafe {
        // TODO: iterate until it doesn't overflow
        let mut addresses: Vec<u8> = vec![0u8; 15000];
        let mut addresses_len = addresses.len() as u32;
        let res = GetAdaptersAddresses(
            AF_UNSPEC.0 as u32,
            GET_ADAPTERS_ADDRESSES_FLAGS(0),
            Some(null()),
            Some(addresses.as_mut_ptr() as *mut _),
            &mut addresses_len as *mut _,
        );

        if res != 0 {
            todo!()
        }

        let mut next_address = addresses.as_ptr() as *const _;
        let mut luids = Vec::new();
        loop {
            let address: &IP_ADAPTER_ADDRESSES_LH = std::mem::transmute(next_address);

            if address.FriendlyName.is_null()
                || &address.FriendlyName.to_string().unwrap() != filter
            {
                luids.push(address.Luid);
            }

            if address.Next.is_null() {
                break;
            }
            next_address = address.Next;
        }

        let mut routes: Vec<(MIB_IPFORWARD_ROW2, SOCKADDR_INET)> = Vec::new();
        for luid in &luids {
            let addr: SOCKADDR_INET = SocketAddr::from((dst, 0)).into();
            let mut best_route: MaybeUninit<MIB_IPFORWARD_ROW2> = MaybeUninit::zeroed();
            let mut best_src: MaybeUninit<SOCKADDR_INET> = MaybeUninit::zeroed();

            let res = GetBestRoute2(
                Some(luid as *const _),
                0,
                None,
                &addr as *const _,
                0,
                best_route.as_mut_ptr(),
                best_src.as_mut_ptr(),
            );

            if res.is_err() {
                continue;
            }

            let best_route = best_route.assume_init();
            let best_src = best_src.assume_init();
            routes.push((best_route, best_src));
        }

        routes.sort_by(|(a, _), (b, _)| a.Metric.cmp(&b.Metric));

        let addr = routes.first()?.1;
        match addr.si_family {
            // TODO: it might be better to only get the family that we care about?
            // we will also want to discard the not matching version addresses
            ADDRESS_FAMILY(0) => match dst {
                IpAddr::V4(_) => Some(Ipv4Addr::from(addr.Ipv4.sin_addr).into()),
                IpAddr::V6(_) => Some(Ipv6Addr::from(addr.Ipv6.sin6_addr).into()),
            },
            ADDRESS_FAMILY(2) => Some(Ipv4Addr::from(addr.Ipv4.sin_addr).into()),
            ADDRESS_FAMILY(23) => Some(Ipv6Addr::from(addr.Ipv6.sin6_addr).into()),
            _ => panic!("Invalid address"),
        }
    }
}

#[path = "windows/wintun_install.rs"]
mod wintun_install;

// The return value is useful on Linux
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn check_token_permissions(_path: &Path) -> Result<()> {
    // TODO: For Headless Client, make sure the token is only readable by admin / our service user on Windows
    Ok(())
}

pub(crate) fn default_token_path() -> std::path::PathBuf {
    // TODO: For Headless Client, system-wide default token path for Windows
    PathBuf::from("token.txt")
}

// Does nothing on Windows. On Linux this notifies systemd that we're ready.
// When we eventually have a system service for the Windows Headless Client,
// this could notify the Windows service controller too.
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn notify_service_controller() -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod test {
    use super::*;
    use firezone_bin_shared::TunDeviceManager;
    use ip_network::Ipv4Network;
    use socket_factory::DatagramOut;
    use std::borrow::Cow;
    use std::net::ToSocketAddrs;
    use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4};

    #[test]
    fn best_route_ip4_does_not_fail() {
        get_best_route_excluding_interface("8.8.8.8".parse().unwrap(), "Firezone");
    }

    #[test]
    fn best_route_ip6_does_not_fail() {
        get_best_route_excluding_interface("2404:6800:4006:811::200e".parse().unwrap(), "Firezone");
    }

    // Starts up a WinTUN device, adds a "full-route" (`0.0.0.0/0`) and checks if we can still send packets to IPs outside of our tunnel.
    #[tokio::test]
    #[ignore = "Needs admin & Internet"]
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
        let mut socket =
            udp_socket_factory(&SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0)))
                .unwrap();

        // Send a STUN request.
        let server = "stun.cloudflare.com:3478"
            .to_socket_addrs()
            .unwrap()
            .next()
            .unwrap();
        socket
            .send(DatagramOut {
                src: None,
                dst: server,
                packet: Cow::Borrowed(&hex_literal::hex!(
                    "000100002112A4420123456789abcdef01234567"
                )),
            })
            .unwrap();

        std::future::poll_fn(|cx| {
            let mut buf = [0u8; 1000];
            let result = std::task::ready!(socket.poll_recv_from(&mut buf, cx));

            let _response = result.unwrap().next().unwrap();

            Poll::Ready(())
        })
        .await;
    }
}
