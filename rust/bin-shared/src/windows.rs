use crate::TUNNEL_NAME;
use anyhow::{Context as _, Result};
use firezone_logging::err_with_src;
use known_folders::{get_known_folder_path, KnownFolder};
use socket_factory::{TcpSocket, UdpSocket};
use std::{
    cmp::Ordering,
    io,
    mem::MaybeUninit,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
    path::PathBuf,
    ptr::null,
};
use uuid::Uuid;
use windows::Win32::NetworkManagement::{
    IpHelper::{GetAdaptersAddresses, MIB_IPFORWARD_TABLE2},
    Ndis::NET_LUID_LH,
};
use windows::Win32::{
    NetworkManagement::IpHelper::{
        CreateIpForwardEntry2, DeleteIpForwardEntry2, GetBestRoute2, GetIpForwardTable2,
        GET_ADAPTERS_ADDRESSES_FLAGS, IP_ADAPTER_ADDRESSES_LH, MIB_IPFORWARD_ROW2,
    },
    NetworkManagement::Ndis::IfOperStatusUp,
    Networking::WinSock::{ADDRESS_FAMILY, AF_INET, AF_INET6, AF_UNSPEC, SOCKADDR_INET},
};

/// Hides Powershell's console on Windows
///
/// <https://stackoverflow.com/questions/59692146/is-it-possible-to-use-the-standard-library-to-spawn-a-process-without-showing-th#60958956>
/// Also used for self-elevation
pub const CREATE_NO_WINDOW: u32 = 0x08000000;

/// A UUID we generated at dev time for our tunnel.
///
/// This ends up in registry keys and tunnel management.
pub const TUNNEL_UUID: Uuid = Uuid::from_u128(0xe924_5bc1_b8c1_44ca_ab1d_c6aa_d4f1_3b9c);

/// Error codes returned from Windows APIs.
///
/// For details, see the Windows Error reference: <https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-erref>.
///
/// ## tl;dr
///
/// - Windows _result_ codes are 32-bit numbers.
/// - The most-signficant bit indicates an error, if set. Hence all results here start with an `8`.
/// - We can ignore the next 4 bits.
/// - The "7" indicates the facility. In our case, this means Win32 APIs.
/// - The last 4 numbers (i.e. 16 bit) are the actual error code.
///
/// ## Adding new codes
///
/// We create the error codes using the [`HRESULT::from_win32`] constructor which sets these bits correctly.
/// The doctests make sure we actually construct the error that we'll see in logs.
/// Being able to search for these with full-text search is important for maintenance.
pub mod error {
    use windows_core::HRESULT;

    /// Win32 error code objects that don't exist (like network adapters).
    ///
    /// ```
    /// assert_eq!(firezone_bin_shared::windows::error::NOT_FOUND.0 as u32, 0x80070490)
    /// ```
    pub const NOT_FOUND: HRESULT = HRESULT::from_win32(0x0490);

    /// Win32 error code for objects that already exist (like routing table entries).
    ///
    /// ```
    /// assert_eq!(firezone_bin_shared::windows::error::OBJECT_EXISTS.0 as u32, 0x80071392)
    /// ```
    pub const OBJECT_EXISTS: HRESULT = HRESULT::from_win32(0x1392);

    /// Win32 error code for unsupported operations (like setting an IPv6 address without an IPv6 stack).
    ///
    /// ```
    /// assert_eq!(firezone_bin_shared::windows::error::NOT_SUPPORTED.0 as u32, 0x80070032)
    /// ```
    pub const NOT_SUPPORTED: HRESULT = HRESULT::from_win32(0x0032);
}

#[derive(clap::ValueEnum, Clone, Copy, Debug)]
pub enum DnsControlMethod {
    /// Explicitly disable DNS control.
    ///
    /// We don't use an `Option<Method>` because leaving out the CLI arg should
    /// use NRPT, not disable DNS control.
    Disabled,
    /// NRPT, the only DNS control method we use on Windows.
    Nrpt,
}

impl Default for DnsControlMethod {
    fn default() -> Self {
        Self::Nrpt
    }
}

/// Returns e.g. `C:/Users/User/AppData/Local/dev.firezone.client
///
/// This is where we can save config, logs, crash dumps, etc.
/// It's per-user and doesn't roam across different PCs in the same domain.
/// It's read-write for non-elevated processes.
pub fn app_local_data_dir() -> Result<PathBuf> {
    let path = get_known_folder_path(KnownFolder::LocalAppData)
        .context("Can't find %LOCALAPPDATA% dir")?
        .join(crate::BUNDLE_ID);
    Ok(path)
}

pub fn tcp_socket_factory(addr: &SocketAddr) -> io::Result<TcpSocket> {
    delete_all_routing_entries_matching(addr.ip())?;

    let route = get_best_non_tunnel_route(addr.ip())?;

    let mut socket = socket_factory::tcp(addr)?;

    // To avoid routing loops, all TCP sockets are bound to the "best" source IP.
    // Additionally, we add a dedicated route for the given address to route via the default interface.
    socket.bind((route.addr, 0).into())?;
    let entry = RoutingTableEntry::create(addr.ip(), route.original)?;

    socket.pack(entry);

    Ok(socket)
}

pub fn udp_socket_factory(src_addr: &SocketAddr) -> io::Result<UdpSocket> {
    let source_ip_resolver = |dst| Ok(Some(get_best_non_tunnel_route(dst)?.addr));

    let socket =
        socket_factory::udp(src_addr)?.with_source_ip_resolver(Box::new(source_ip_resolver));

    Ok(socket)
}

fn delete_all_routing_entries_matching(addr: IpAddr) -> io::Result<()> {
    let mut table = std::ptr::null_mut::<MIB_IPFORWARD_TABLE2>();
    let ip_family = match addr {
        IpAddr::V4(_) => AF_INET,
        IpAddr::V6(_) => AF_INET6,
    };

    // Safety: `ip_family` is initialised and `table` is not-null (we pass a reference that gets coerced to a pointer).
    unsafe { GetIpForwardTable2(ip_family, &mut table) }
        .ok()
        .map_err(io::Error::other)?;

    // Safety: The pointer is aligned.
    let maybe_table = unsafe { table.as_ref() };
    let table = maybe_table.ok_or(io::Error::other("IP routing table is null"))?;
    let mut entry = table.Table.as_ptr();

    for _ in 0..table.NumEntries {
        // Safety: We never offset beyond the number of entries.
        entry = unsafe { entry.offset(1) };
        // Safety: The pointer is aligned.
        let maybe_entry_ref = unsafe { entry.as_ref() };
        let Some(entry_ref) = maybe_entry_ref else {
            continue; // Better safe than sorry.
        };

        let dp = entry_ref.DestinationPrefix;

        let route = match addr {
            IpAddr::V4(_) if dp.PrefixLength == 32 => {
                // Safety: Any 32 bit number is a valid IPv4 address
                IpAddr::V4(unsafe { dp.Prefix.Ipv4 }.sin_addr.into())
            }
            IpAddr::V6(_) if dp.PrefixLength == 128 => {
                // Safety: Any 128 bit number is a valid IPv6 address
                IpAddr::V6(unsafe { dp.Prefix.Ipv6 }.sin6_addr.into())
            }
            IpAddr::V4(_) | IpAddr::V6(_) => continue,
        };

        if route != addr {
            continue;
        }

        let iface_idx = entry_ref.InterfaceIndex;

        // Safety: The `entry` is initialised.
        if let Err(e) = unsafe { DeleteIpForwardEntry2(entry) }.ok() {
            tracing::warn!("Failed to remove routing entry: {}", err_with_src(&e));
            continue;
        };

        tracing::debug!(%route, %iface_idx, "Removed stale route entry");
    }

    Ok(())
}

/// Represents an entry in Windows' routing table.
///
/// Routes will be created upon [`create`](RoutingTableEntry::create) and removed on [`Drop`].
struct RoutingTableEntry {
    entry: MIB_IPFORWARD_ROW2,
    route: IpAddr,
}

impl RoutingTableEntry {
    /// Creates a new routing table entry by using the given prototype and overriding the route.
    fn create(route: IpAddr, mut prototype: MIB_IPFORWARD_ROW2) -> io::Result<Self> {
        let prefix = &mut prototype.DestinationPrefix;
        match route {
            IpAddr::V4(x) => {
                prefix.PrefixLength = 32;
                prefix.Prefix.Ipv4 = SocketAddrV4::new(x, 0).into();
            }
            IpAddr::V6(x) => {
                prefix.PrefixLength = 128;
                prefix.Prefix.Ipv6 = SocketAddrV6::new(x, 0, 0, 0).into();
            }
        }

        // Safety: The prototype is initialised correctly.
        unsafe { CreateIpForwardEntry2(&prototype) }
            .ok()
            .or_else(|e| {
                if e.code() == error::OBJECT_EXISTS {
                    Ok(())
                } else {
                    Err(io::Error::other(e))
                }
            })?;

        let iface_idx = prototype.InterfaceIndex;

        tracing::debug!(%route, %iface_idx, "Created new route");

        Ok(Self {
            entry: prototype,
            route,
        })
    }
}

impl Drop for RoutingTableEntry {
    fn drop(&mut self) {
        let iface_idx = self.entry.InterfaceIndex;

        // Safety: The entry we stored is valid.
        let Err(e) = unsafe { DeleteIpForwardEntry2(&self.entry) }.ok() else {
            tracing::debug!(route = %self.route, %iface_idx, "Removed route");
            return;
        };

        if e.code() == error::NOT_FOUND {
            return;
        }

        tracing::warn!("Failed to delete routing entry: {}", err_with_src(&e));
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
fn get_best_non_tunnel_route(dst: IpAddr) -> io::Result<Route> {
    let route = list_adapters()?
        .filter(|adapter| !is_tun(adapter))
        .filter(|adapter| is_up(adapter))
        .filter_map(|adapter| find_best_route_for_luid(&adapter.Luid, dst).ok())
        .min()
        .ok_or(io::Error::other("No route to host"))?;

    tracing::debug!(src = %route.addr, %dst, "Resolved best route outside of tunnel interface");

    Ok(route)
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

fn is_up(adapter: &IP_ADAPTER_ADDRESSES_LH) -> bool {
    adapter.OperStatus == IfOperStatusUp
}

struct Route {
    metric: u32,
    addr: IpAddr,

    original: MIB_IPFORWARD_ROW2,
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

impl PartialEq for Route {
    fn eq(&self, other: &Self) -> bool {
        self.metric.eq(&other.metric) && self.addr.eq(&other.addr)
    }
}

impl Eq for Route {}

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
        original: best_route,
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
