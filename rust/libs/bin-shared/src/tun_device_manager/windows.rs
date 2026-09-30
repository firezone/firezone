use crate::TUNNEL_NAME;
use crate::network_changes::TunnelInterfaceIndexGuard;
use crate::tun_device_manager::TunIpStack;
use crate::windows::TUNNEL_UUID;
use crate::windows::error::{NOT_FOUND, NOT_SUPPORTED, OBJECT_EXISTS};
use anyhow::{Context as _, Result};
use ip_network::IpNetwork;
use logging::err_with_src;
use ring::digest;
use std::net::IpAddr;
use std::{
    collections::HashSet,
    io::Read as _,
    net::{Ipv4Addr, Ipv6Addr, SocketAddrV4, SocketAddrV6},
    path::{Path, PathBuf},
};
use windows::Win32::NetworkManagement::IpHelper::{
    CreateUnicastIpAddressEntry, InitializeUnicastIpAddressEntry, MIB_UNICASTIPADDRESS_ROW,
};
use windows::Win32::{
    NetworkManagement::{
        IpHelper::{
            CreateIpForwardEntry2, DeleteIpForwardEntry2, GetIpInterfaceEntry,
            InitializeIpForwardEntry, MIB_IPFORWARD_ROW2, MIB_IPINTERFACE_ROW, SetIpInterfaceEntry,
        },
        Ndis::NET_LUID_LH,
    },
    Networking::WinSock::{ADDRESS_FAMILY, AF_INET, AF_INET6},
};
use wintun::Adapter;

pub struct TunDeviceManager {
    mtu: u32,

    /// Interface index of the last created adapter.
    iface_idx: Option<u32>,
    /// ID of the last created adapter.
    luid: Option<wintun::NET_LUID_LH>,

    routes: HashSet<IpNetwork>,
}

impl TunDeviceManager {
    #[expect(clippy::unnecessary_wraps, reason = "Fallible on Linux")]
    pub fn new(mtu: usize) -> Result<Self> {
        Ok(Self {
            iface_idx: None,
            luid: None,
            routes: HashSet::default(),
            mtu: mtu as u32,
        })
    }

    pub fn make_tun(&mut self) -> Result<Box<dyn tun::Tun>> {
        let tun = Tun::new(self.mtu)?;
        self.iface_idx = Some(tun.iface_idx());
        self.luid = Some(tun.luid);

        Ok(Box::new(tun))
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn set_ips(&mut self, ipv4: Ipv4Addr, ipv6: Ipv6Addr) -> Result<TunIpStack> {
        let luid = self
            .luid
            .context("Cannot set IPs prior to creating an adapter")?;

        // SAFETY: Both NET_LUID_LH unions should be the same. We're just copying out
        // the u64 value and re-wrapping it, since wintun doesn't refer to the windows
        // crate's version of NET_LUID_LH.
        let luid = NET_LUID_LH {
            Value: unsafe { luid.Value },
        };

        tracing::debug!(%ipv4, %ipv6, "Setting tunnel interface IPs");

        let success_v4 =
            try_set_ip(luid, IpAddr::V4(ipv4)).context("Failed to set IPv4 address")?;
        let success_v6 =
            try_set_ip(luid, IpAddr::V6(ipv6)).context("Failed to set IPv6 address")?;

        let tun_ip_stack = match (success_v4, success_v6) {
            (true, true) => TunIpStack::Dual,
            (true, false) => TunIpStack::V4Only,
            (false, true) => TunIpStack::V6Only,
            (false, false) => anyhow::bail!("Failed to set IPv4 and IPv6 address on TUN device"),
        };

        Ok(tun_ip_stack)
    }

    #[expect(clippy::unused_async, reason = "Must match Linux API")]
    pub async fn set_routes(&mut self, routes: impl IntoIterator<Item = IpNetwork>) -> Result<()> {
        let iface_idx = self
            .iface_idx
            .context("Cannot set routes without having created TUN device")?;

        let new_routes = HashSet::from_iter(routes);

        for old_route in self.routes.difference(&new_routes) {
            remove_route(*old_route, iface_idx);
        }

        for new_route in &new_routes {
            add_route(*new_route, iface_idx);
        }

        self.routes = new_routes;

        Ok(())
    }
}

// It's okay if this blocks until the route is added in the OS.
fn add_route(route: IpNetwork, iface_idx: u32) {
    let entry = forward_entry(route, iface_idx);

    // SAFETY: Windows shouldn't store the reference anywhere, it's just a way to pass lots of arguments at once. And no other thread sees this variable.
    let Err(e) = unsafe { CreateIpForwardEntry2(&entry) }.ok() else {
        tracing::debug!(%route, %iface_idx, "Created new route");

        return;
    };

    // We expect set_routes to call add_route with the same routes always making this error expected
    if e.code() == OBJECT_EXISTS {
        return;
    }

    if e.code() == NOT_FOUND {
        tracing::debug!(%route, "Failed to add route: IP stack disabled?");
        return;
    }

    tracing::warn!(%route, "Failed to add route: {}", err_with_src(&e));
}

// It's okay if this blocks until the route is removed in the OS.
fn remove_route(route: IpNetwork, iface_idx: u32) {
    let entry = forward_entry(route, iface_idx);

    // SAFETY: Windows shouldn't store the reference anywhere, it's just a way to pass lots of arguments at once. And no other thread sees this variable.

    let Err(e) = unsafe { DeleteIpForwardEntry2(&entry) }.ok() else {
        tracing::debug!(%route, %iface_idx, "Removed route");

        return;
    };

    if e.code() == NOT_FOUND {
        return;
    }

    tracing::warn!(%route, "Failed to remove route: {}", err_with_src(&e))
}

fn forward_entry(route: IpNetwork, iface_idx: u32) -> MIB_IPFORWARD_ROW2 {
    let mut row = MIB_IPFORWARD_ROW2::default();
    // SAFETY: Windows shouldn't store the reference anywhere, it's just setting defaults
    unsafe { InitializeIpForwardEntry(&mut row) };

    let prefix = &mut row.DestinationPrefix;
    match route {
        IpNetwork::V4(x) => {
            prefix.PrefixLength = x.netmask();
            prefix.Prefix.Ipv4 = SocketAddrV4::new(x.network_address(), 0).into();
        }
        IpNetwork::V6(x) => {
            prefix.PrefixLength = x.netmask();
            prefix.Prefix.Ipv6 = SocketAddrV6::new(x.network_address(), 0, 0, 0).into();
        }
    }

    row.InterfaceIndex = iface_idx;
    row.Metric = 0;

    row
}

// Must be public so the benchmark binary can find it
pub struct Tun {
    /// The index of our network adapter, we can use this when asking Windows to add / remove routes / DNS rules
    /// It's stable across app restarts and I'm assuming across system reboots too.
    iface_idx: u32,
    luid: wintun::NET_LUID_LH,

    io: tun_windows::Io,
    /// Drop after the session so address-removal callbacks remain filtered during teardown.
    _interface_index_guard: TunnelInterfaceIndexGuard,
}

impl Tun {
    fn new(mtu: u32) -> Result<Self> {
        let path = ensure_dll().context("Failed to ensure `wintun.dll` is in place")?;
        // SAFETY: we're loading a DLL from disk and it has arbitrary C code in it. There's no perfect way to prove it's safe.
        let wintun = unsafe { wintun::load_from_path(path.clone()) }
            .with_context(|| format!("Failed to load `wintun.dll` from {}", path.display()))?;

        // Create wintun adapter
        let adapter = Adapter::create(
            &wintun,
            TUNNEL_NAME,
            TUNNEL_NAME,
            Some(TUNNEL_UUID.as_u128()),
        )?;
        let iface_idx = adapter
            .get_adapter_index()
            .context("Failed to get adapter index")?;
        let interface_index_guard = TunnelInterfaceIndexGuard::new(iface_idx);
        let luid = adapter.get_luid();

        set_iface_config(luid, mtu).context("Failed to set interface config")?;

        let io = tun_windows::Io::new(
            TUNNEL_NAME,
            &adapter,
            telemetry::feature_flags::wintun_tcp_coalescing,
        )?;

        Ok(Self {
            iface_idx,
            luid,
            io,
            _interface_index_guard: interface_index_guard,
        })
    }

    pub fn iface_idx(&self) -> u32 {
        self.iface_idx
    }
}

impl tun::ChannelTun for Tun {
    fn sender(&self) -> &tun::OutboundTx {
        tun::ChannelTun::sender(&self.io)
    }

    fn receiver(&mut self) -> &mut tun::InboundRx {
        tun::ChannelTun::receiver(&mut self.io)
    }

    fn name(&self) -> &str {
        TUNNEL_NAME
    }
}

/// Sets MTU on the interface
/// TODO: Set IP and other things in here too, so the code is more organized
fn set_iface_config(luid: wintun::NET_LUID_LH, mtu: u32) -> Result<()> {
    // SAFETY: Both NET_LUID_LH unions should be the same. We're just copying out
    // the u64 value and re-wrapping it, since wintun doesn't refer to the windows
    // crate's version of NET_LUID_LH.
    let luid = NET_LUID_LH {
        Value: unsafe { luid.Value },
    };

    try_set_mtu(luid, AF_INET, mtu)?;
    try_set_mtu(luid, AF_INET6, mtu)?;
    Ok(())
}

fn try_set_mtu(luid: NET_LUID_LH, family: ADDRESS_FAMILY, mtu: u32) -> Result<()> {
    let mut row = MIB_IPINTERFACE_ROW {
        Family: family,
        InterfaceLuid: luid,
        ..Default::default()
    };

    // SAFETY: TODO
    if let Err(error) = unsafe { GetIpInterfaceEntry(&mut row) }.ok() {
        if family == AF_INET6 && error.code() == NOT_FOUND {
            tracing::debug!(?family, "Couldn't set MTU, maybe IPv6 is disabled.");
        } else {
            tracing::warn!(?family, "Couldn't set MTU: {}", err_with_src(&error));
        }
        return Ok(());
    }

    // https://stackoverflow.com/questions/54857292/setipinterfaceentry-returns-error-invalid-parameter
    row.SitePrefixLength = 0;

    row.NlMtu = mtu;

    // SAFETY: TODO
    unsafe { SetIpInterfaceEntry(&mut row) }.ok()?;
    Ok(())
}

fn try_set_ip(luid: NET_LUID_LH, ip: IpAddr) -> Result<bool> {
    // Safety: Docs don't mention anything in regards to safety of this function.
    let mut row = unsafe {
        let mut row: MIB_UNICASTIPADDRESS_ROW = std::mem::zeroed();
        InitializeUnicastIpAddressEntry(&mut row);

        row
    };

    row.InterfaceLuid = luid; // Target our tunnel interface.
    row.ValidLifetime = 0xffffffff; // Infinite

    match ip {
        IpAddr::V4(ipv4) => {
            row.Address.si_family = AF_INET;
            row.Address.Ipv4 = SocketAddrV4::new(ipv4, 0).into();
            row.OnLinkPrefixLength = 32;
        }
        IpAddr::V6(ipv6) => {
            row.Address.si_family = AF_INET6;
            row.Address.Ipv6 = SocketAddrV6::new(ipv6, 0, 0, 0).into();
            row.OnLinkPrefixLength = 128;
        }
    }

    // Safety: Docs don't mention anything about safety other than having to use `InitializeUnicastIpAddressEntry` and we did that.
    let success = match unsafe { CreateUnicastIpAddressEntry(&row) }.ok() {
        Ok(()) => true,
        Err(e) if e.code() == NOT_SUPPORTED => {
            tracing::debug!(%ip, "Failed to set interface IP: IP stack not supported?");

            false
        }
        Err(e) if e.code() == NOT_FOUND => {
            tracing::debug!(%ip, "Failed to set interface IP: IP stack disabled?");

            false
        }
        Err(e) if e.code() == OBJECT_EXISTS => true, // Happens if we are trying to set the exact same IP.
        Err(e) => {
            return Err(anyhow::Error::new(e).context("Failed to create `UnicastIpAddressEntry`"));
        }
    };

    Ok(success)
}

/// Installs the DLL in %LOCALAPPDATA% and returns the DLL's absolute path
///
/// e.g. `C:\Users\User\AppData\Local\dev.firezone.client\data\wintun.dll`
/// Also verifies the SHA256 of the DLL on-disk with the expected bytes packed into the exe
fn ensure_dll() -> Result<PathBuf> {
    let dll_bytes = wintun_bytes();

    let path = wintun_dll_path().context("Can't compute wintun.dll path")?;
    // The DLL path should always have a parent
    let dir = path.parent().context("wintun.dll path invalid")?;
    std::fs::create_dir_all(dir).context("Can't create dirs for wintun.dll")?;

    tracing::debug!(?path, "wintun.dll path");

    // This hash check is not meant to protect against attacks. It only lets us skip redundant disk writes, and it updates the DLL if needed.
    // `tun_windows.rs` in connlib, and `elevation.rs`, rely on thia.
    if dll_already_exists(&path, &dll_bytes) {
        return Ok(path);
    }
    std::fs::write(&path, dll_bytes.bytes).context("Failed to write wintun.dll")?;
    Ok(path)
}

fn dll_already_exists(path: &Path, dll_bytes: &DllBytes) -> bool {
    let mut f = match std::fs::File::open(path) {
        Err(_) => return false,
        Ok(x) => x,
    };

    let actual_len = match file_length(&f) {
        Err(e) => {
            tracing::warn!(
                path = %path.display(),
                "Failed to get file length: {e:#}"
            );

            return false;
        }
        Ok(l) => l,
    };

    let expected_len = dll_bytes.bytes.len();
    // If the dll is 100 MB instead of 0.5 MB, this allows us to skip a 100 MB read
    if actual_len != expected_len {
        return false;
    }

    let mut buf = vec![0u8; expected_len];
    if f.read_exact(&mut buf).is_err() {
        return false;
    }

    let expected = dll_bytes.expected_sha256;
    let actual = digest::digest(&digest::SHA256, &buf);
    expected == actual.as_ref()
}

fn file_length(f: &std::fs::File) -> Result<usize> {
    let len = f.metadata().context("Failed to read metadata")?.len();
    let len = usize::try_from(len).context("File length doesn't fit into usize")?;

    Ok(len)
}

/// Returns the absolute path for installing and loading `wintun.dll`
///
/// e.g. `C:\Users\User\AppData\Local\dev.firezone.client\data\wintun.dll`
fn wintun_dll_path() -> Result<PathBuf> {
    let path = known_dirs::platform::app_local_data_dir()?
        .join("data")
        .join("wintun.dll");
    Ok(path)
}

struct DllBytes {
    /// Bytes embedded in the client with `include_bytes`
    pub bytes: &'static [u8],
    /// Expected SHA256 hash
    pub expected_sha256: [u8; 32],
}

#[cfg(target_arch = "x86_64")]
fn wintun_bytes() -> DllBytes {
    DllBytes {
        bytes: include_bytes!("../wintun/bin/amd64/wintun.dll"),
        expected_sha256: hex_literal::hex!(
            "e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce"
        ),
    }
}

#[cfg(target_arch = "aarch64")]
fn wintun_bytes() -> DllBytes {
    DllBytes {
        bytes: include_bytes!("../wintun/bin/arm64/wintun.dll"),
        expected_sha256: hex_literal::hex!(
            "f7ba89005544be9d85231a9e0d5f23b2d15b3311667e2dad0debd344918a3f80"
        ),
    }
}

impl tun::Tun for Tun {
    fn name(&self) -> &str { tun::ChannelTun::name(self) }
    fn into_io(self: Box<Self>) -> Result<Box<dyn tun::TunIo>> { Ok(self) }
}
