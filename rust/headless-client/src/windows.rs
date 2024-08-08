//! Implementation of headless Client and IPC service for Windows
//!
//! Try not to panic in the IPC service. Windows doesn't consider the
//! service to be stopped even if its only process ends, for some reason.
//! We must tell Windows explicitly when our service is stopping.

use anyhow::Result;
use std::{
    cmp::Ordering,
    io,
    mem::MaybeUninit,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    path::{Path, PathBuf},
    ptr::null,
};

use windows::Win32::NetworkManagement::{IpHelper::GetAdaptersAddresses, Ndis::NET_LUID_LH};
use windows::Win32::Networking::WinSock::SOCKADDR_INET;
use windows::Win32::{
    NetworkManagement::IpHelper::{
        GetBestRoute2, GET_ADAPTERS_ADDRESSES_FLAGS, IP_ADAPTER_ADDRESSES_LH, MIB_IPFORWARD_ROW2,
    },
    Networking::WinSock::{ADDRESS_FAMILY, AF_UNSPEC},
};

use firezone_bin_shared::TUNNEL_NAME;
use socket_factory::{TcpSocket, UdpSocket};

pub fn tcp_socket_factory(addr: &SocketAddr) -> io::Result<TcpSocket> {
    let local = get_best_non_tunnel_route(addr.ip())?;

    let socket = socket_factory::tcp(addr)?;
    socket.bind((local, 0).into())?; // To avoid routing loops, all TCP sockets are bound to the "best" source IP.

    Ok(socket)
}

pub fn udp_socket_factory(src_addr: &SocketAddr) -> io::Result<UdpSocket> {
    let source_ip_resolver = |dst| Ok(Some(get_best_non_tunnel_route(dst)?));

    let socket =
        socket_factory::udp(src_addr)?.with_source_ip_resolver(Box::new(source_ip_resolver));

    Ok(socket)
}

struct Adapters {
    _buffer: Vec<u8>,
    next: *const IP_ADAPTER_ADDRESSES_LH,
}

impl Iterator for Adapters {
    type Item = &'static IP_ADAPTER_ADDRESSES_LH;

    fn next(&mut self) -> Option<Self::Item> {
        // SAFETY: We expect windows to give us a valid linked list where each item of the list is actually an IP_ADAPTER_ADDRESSES_LH.
        let adapter = unsafe { self.next.as_ref()? };

        self.next = adapter.Next;

        Some(adapter)
    }
}

/// Finds the best route (i.e. source interface) for a given destination IP, excluding our TUN interface.
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
fn get_best_non_tunnel_route(dst: IpAddr) -> io::Result<IpAddr> {
    let route = list_adapters()?
        .filter(|adapter| !is_tun(adapter))
        .map(|adapter| adapter.Luid)
        .filter_map(|luid| find_best_route_for_luid(&luid, dst).ok())
        .min()
        .ok_or(io::Error::other("No route to host"))?;

    let src = route.addr;

    tracing::debug!(%src, %dst, "Resolved best route outside of tunnel interface");

    Ok(src)
}

fn list_adapters() -> io::Result<Adapters> {
    use windows::Win32::Foundation::ERROR_BUFFER_OVERFLOW;
    use windows::Win32::Foundation::WIN32_ERROR;

    // 15kB is recommended to almost never fail
    let mut buffer: Vec<u8> = vec![0u8; 15000];
    let mut buffer_len = buffer.len() as u32;
    // Safety we just allocated buffer with the len we are passing
    let mut res = unsafe {
        GetAdaptersAddresses(
            AF_UNSPEC.0 as u32,
            GET_ADAPTERS_ADDRESSES_FLAGS(0),
            Some(null()),
            Some(buffer.as_mut_ptr() as *mut _),
            &mut buffer_len as *mut _,
        )
    };

    // In case of a buffer overflow buffer_len will contain the necessary length
    if res == ERROR_BUFFER_OVERFLOW.0 {
        buffer = vec![0u8; buffer_len as usize];
        // SAFETY: we just allocated buffer with the len we are passing
        res = unsafe {
            GetAdaptersAddresses(
                AF_UNSPEC.0 as u32,
                GET_ADAPTERS_ADDRESSES_FLAGS(0),
                Some(null()),
                Some(buffer.as_mut_ptr() as *mut _),
                &mut buffer_len as *mut _,
            )
        };
    }

    WIN32_ERROR(res).ok()?;

    let next = buffer.as_ptr() as *const _;
    Ok(Adapters {
        _buffer: buffer,
        next,
    })
}

fn is_tun(adapter: &IP_ADAPTER_ADDRESSES_LH) -> bool {
    if adapter.FriendlyName.is_null() {
        return false;
    }

    // SAFETY: It should be safe to call to_string since we checked it's not null and the reference should be valid
    let friendly_name = unsafe { adapter.FriendlyName.to_string() };
    let Ok(friendly_name) = friendly_name else {
        return false;
    };

    friendly_name == TUNNEL_NAME
}

#[derive(PartialEq, Eq)]
struct Route {
    metric: u32,
    addr: IpAddr,
}

impl Ord for Route {
    fn cmp(&self, other: &Self) -> Ordering {
        self.metric.cmp(&other.metric)
    }
}

impl PartialOrd for Route {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

fn find_best_route_for_luid(luid: &NET_LUID_LH, dst: IpAddr) -> Result<Route> {
    let addr: SOCKADDR_INET = SocketAddr::from((dst, 0)).into();
    let mut best_route: MaybeUninit<MIB_IPFORWARD_ROW2> = MaybeUninit::zeroed();
    let mut best_src: MaybeUninit<SOCKADDR_INET> = MaybeUninit::zeroed();

    // SAFETY: all pointers w ejust allocated with the correct types so it must be safe
    let res = unsafe {
        GetBestRoute2(
            Some(luid as *const _),
            0,
            None,
            &addr as *const _,
            0,
            best_route.as_mut_ptr(),
            best_src.as_mut_ptr(),
        )
    };

    res.ok()?;

    // SAFETY: we just successfully initialized these pointers
    let best_route = unsafe { best_route.assume_init() };
    let best_src = unsafe { best_src.assume_init() };

    Ok(Route {
        // SAFETY: we expect to get a valid address
        addr: unsafe { to_ip_addr(best_src, dst) }
            .ok_or(io::Error::other("can't find a valid route"))?,
        metric: best_route.Metric,
    })
}

// SAFETY: si_family must be always set in the union, which will be the case for a valid SOCKADDR_INET
unsafe fn to_ip_addr(addr: SOCKADDR_INET, dst: IpAddr) -> Option<IpAddr> {
    match (addr.si_family, dst) {
        (ADDRESS_FAMILY(0), IpAddr::V4(_)) | (ADDRESS_FAMILY(2), _) => {
            Some(Ipv4Addr::from(addr.Ipv4.sin_addr).into())
        }
        (ADDRESS_FAMILY(0), IpAddr::V6(_)) | (ADDRESS_FAMILY(23), _) => {
            Some(Ipv6Addr::from(addr.Ipv6.sin6_addr).into())
        }
        _ => None,
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

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn best_route_ip4_does_not_panic_or_segfault() {
        let _ = get_best_non_tunnel_route("8.8.8.8".parse().unwrap());
    }

    #[test]
    fn best_route_ip6_does_not_panic_or_segfault() {
        let _ = get_best_non_tunnel_route("2404:6800:4006:811::200e".parse().unwrap());
    }
}
