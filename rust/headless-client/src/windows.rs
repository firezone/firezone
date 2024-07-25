//! Implementation of headless Client and IPC service for Windows
//!
//! Try not to panic in the IPC service. Windows doesn't consider the
//! service to be stopped even if its only process ends, for some reason.
//! We must tell Windows explicitly when our service is stopping.

use anyhow::Result;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};

use socket_factory::tcp;
use socket_factory::udp;
use socket_factory::{TcpSocket, UdpSocket};

pub fn tcp_socket_factory(addr: &SocketAddr) -> io::Result<TcpSocket> {
    let socket = socket_factory::tcp(addr)?;
    socket.bind(
        (
            get_best_route(addr.ip(), connlib_shared::windows::TUNNEL_NAME),
            0,
        )
            .into(),
    );
    Ok(socket)
}

pub fn udp_socket_factory(src_addr: &SocketAddr) -> io::Result<UdpSocket> {
    let socket = socket_factory::udp(src_addr)?;
    socket.set_source_ip_resolver(Box::new(|addr| {
        Some(get_best_route(addr, connlib_shared::windows::TUNNEL_NAME))
    }));
    Ok(socket)
}

fn get_best_route(dst: IpAddr, filter: &str) -> IpAddr {
    use std::mem::{size_of, size_of_val, MaybeUninit};
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
        let mut addresses_len = size_of_val(&addresses) as u32;
        GetAdaptersAddresses(
            AF_UNSPEC.0 as u32,
            GET_ADAPTERS_ADDRESSES_FLAGS(0),
            Some(null()),
            Some(addresses.as_mut_ptr() as *mut _),
            &mut addresses_len as *mut _,
        );

        let mut next_address = addresses.as_ptr() as *const _;
        let mut luids = Vec::new();
        loop {
            let address: &IP_ADAPTER_ADDRESSES_LH = std::mem::transmute(next_address);
            if &address.AdapterName.to_string().unwrap() == filter {
                continue;
            }

            luids.push(address.Luid);
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

            GetBestRoute2(
                Some(luid as *const _),
                0,
                None,
                &addr as *const _,
                0,
                best_route.as_mut_ptr(),
                best_src.as_mut_ptr(),
            );

            let best_route = best_route.assume_init();
            let best_src = best_src.assume_init();
            routes.push((best_route, best_src));
        }

        routes.sort_by(|(a, _), (b, _)| a.Metric.cmp(&b.Metric));

        let addr = routes.first().unwrap().1;
        match addr.si_family {
            ADDRESS_FAMILY(0) => todo!(),
            ADDRESS_FAMILY(2) => Ipv4Addr::from(addr.Ipv4.sin_addr).into(),
            ADDRESS_FAMILY(23) => Ipv6Addr::from(addr.Ipv6.sin6_addr).into(),
            _ => panic!("Invalid address"),
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;
    #[test]
    fn best_route_works() {
        dbg!(get_best_route("8.8.8.8".parse().unwrap()));
    }
}

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
