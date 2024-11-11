use crate::windows::{CREATE_NO_WINDOW, TUNNEL_UUID};
use crate::TUNNEL_NAME;
use anyhow::{Context as _, Result};
use firezone_logging::std_dyn_err;
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ring::digest;
use std::{
    collections::HashSet,
    io::{self, Read as _},
    net::{Ipv4Addr, Ipv6Addr, SocketAddrV4, SocketAddrV6},
    os::windows::process::CommandExt,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::Arc,
    task::{ready, Context, Poll},
};
use tokio::sync::mpsc;
use windows::Win32::{
    NetworkManagement::{
        IpHelper::{
            CreateIpForwardEntry2, DeleteIpForwardEntry2, GetIpInterfaceEntry,
            InitializeIpForwardEntry, SetIpInterfaceEntry, MIB_IPFORWARD_ROW2, MIB_IPINTERFACE_ROW,
        },
        Ndis::NET_LUID_LH,
    },
    Networking::WinSock::{ADDRESS_FAMILY, AF_INET, AF_INET6},
};
use wintun::Adapter;

/// The ring buffer size used for Wintun.
///
/// Must be a power of two within a certain range <https://docs.rs/wintun/latest/wintun/struct.Adapter.html#method.start_session>
/// 0x10_0000 is 1 MiB, which performs decently on the Cloudflare speed test.
/// At 1 Gbps that's about 8 ms, so any delay where Firezone isn't scheduled by the OS
/// onto a core for more than 8 ms would result in packet drops.
///
/// We think 1 MiB is similar to the buffer size on Linux / macOS but we're not sure
/// where that is configured.
const RING_BUFFER_SIZE: u32 = 0x10_0000;

pub struct TunDeviceManager {
    mtu: u32,
    iface_idx: Option<u32>,

    routes: HashSet<IpNetwork>,
}

impl TunDeviceManager {
    #[expect(clippy::unnecessary_wraps, reason = "Fallible on Linux")]
    pub fn new(mtu: usize) -> Result<Self> {
        Ok(Self {
            iface_idx: None,
            routes: HashSet::default(),
            mtu: mtu as u32,
        })
    }

    pub fn make_tun(&mut self) -> Result<Tun> {
        let tun = Tun::new(self.mtu)?;
        self.iface_idx = Some(tun.iface_idx());

        Ok(tun)
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn set_ips(&mut self, ipv4: Ipv4Addr, ipv6: Ipv6Addr) -> Result<()> {
        tracing::debug!("Setting our IPv4 = {}", ipv4);
        tracing::debug!("Setting our IPv6 = {}", ipv6);

        // TODO: See if there's a good Win32 API for this
        // Using netsh directly instead of wintun's `set_network_addresses_tuple` because their code doesn't work for IPv6
        Command::new("netsh")
            .creation_flags(CREATE_NO_WINDOW)
            .arg("interface")
            .arg("ipv4")
            .arg("set")
            .arg("address")
            .arg(format!("name=\"{TUNNEL_NAME}\""))
            .arg("source=static")
            .arg(format!("address={}", ipv4))
            .arg("mask=255.255.255.255")
            .stdout(Stdio::null())
            .status()?;

        Command::new("netsh")
            .creation_flags(CREATE_NO_WINDOW)
            .arg("interface")
            .arg("ipv6")
            .arg("set")
            .arg("address")
            .arg(format!("interface=\"{TUNNEL_NAME}\""))
            .arg(format!("address={}", ipv6))
            .stdout(Stdio::null())
            .status()?;

        Ok(())
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn set_routes(&mut self, v4: Vec<Ipv4Network>, v6: Vec<Ipv6Network>) -> Result<()> {
        let iface_idx = self
            .iface_idx
            .context("Cannot set routes without having created TUN device")?;

        let new_routes = HashSet::from_iter(
            v4.into_iter()
                .map(IpNetwork::from)
                .chain(v6.into_iter().map(IpNetwork::from)),
        );

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
    const DUPLICATE_ERR: u32 = 0x80071392;
    let entry = forward_entry(route, iface_idx);

    // SAFETY: Windows shouldn't store the reference anywhere, it's just a way to pass lots of arguments at once. And no other thread sees this variable.
    let Err(e) = unsafe { CreateIpForwardEntry2(&entry) }.ok() else {
        tracing::debug!(%route, %iface_idx, "Created new route");

        return;
    };

    // We expect set_routes to call add_route with the same routes always making this error expected
    if e.code().0 as u32 == DUPLICATE_ERR {
        return;
    }

    tracing::warn!(error = std_dyn_err(&e), %route, "Failed to add route");
}

// It's okay if this blocks until the route is removed in the OS.
fn remove_route(route: IpNetwork, iface_idx: u32) {
    const ELEMENT_NOT_FOUND: u32 = 0x80070490;
    let entry = forward_entry(route, iface_idx);

    // SAFETY: Windows shouldn't store the reference anywhere, it's just a way to pass lots of arguments at once. And no other thread sees this variable.

    let Err(e) = unsafe { DeleteIpForwardEntry2(&entry) }.ok() else {
        tracing::debug!(%route, %iface_idx, "Removed route");

        return;
    };

    if e.code().0 as u32 == ELEMENT_NOT_FOUND {
        return;
    }

    tracing::warn!(error = std_dyn_err(&e), %route, "Failed to remove route")
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
    packet_rx: mpsc::Receiver<wintun::Packet>,
    recv_thread: Option<std::thread::JoinHandle<()>>,
    session: Arc<wintun::Session>,
}

impl Drop for Tun {
    fn drop(&mut self) {
        tracing::debug!(
            channel_capacity = self.packet_rx.capacity(),
            "Shutting down packet channel..."
        );
        self.packet_rx.close(); // This avoids a deadlock when we join the worker thread, see PR 5571
        if let Err(error) = self.session.shutdown() {
            tracing::error!(error = std_dyn_err(&error), "wintun::Session::shutdown");
        }
        if let Err(error) = self
            .recv_thread
            .take()
            .expect("`recv_thread` should always be `Some` until `Tun` drops")
            .join()
        {
            tracing::error!(?error, "`Tun::recv_thread` panicked");
        }
    }
}

impl Tun {
    #[tracing::instrument(level = "debug")]
    pub fn new(mtu: u32) -> Result<Self> {
        let path = ensure_dll()?;
        // SAFETY: we're loading a DLL from disk and it has arbitrary C code in it. There's no perfect way to prove it's safe.
        let wintun = unsafe { wintun::load_from_path(path) }?;

        // Create wintun adapter
        let adapter = match Adapter::create(
            &wintun,
            TUNNEL_NAME,
            TUNNEL_NAME,
            Some(TUNNEL_UUID.as_u128()),
        ) {
            Ok(x) => x,
            Err(error) => {
                tracing::error!(error = std_dyn_err(&error), "Failed in `Adapter::create`");
                return Err(error)?;
            }
        };
        let iface_idx = adapter.get_adapter_index()?;

        set_iface_config(adapter.get_luid(), mtu)?;

        let session = Arc::new(adapter.start_session(RING_BUFFER_SIZE)?);
        // 4 is a nice power of two. Wintun already queues packets for us, so we don't
        // need much capacity here.
        let (packet_tx, packet_rx) = mpsc::channel(4);
        let recv_thread = start_recv_thread(packet_tx, Arc::clone(&session))?;

        Ok(Self {
            iface_idx,
            recv_thread: Some(recv_thread),
            packet_rx,
            session: Arc::clone(&session),
        })
    }

    pub fn iface_idx(&self) -> u32 {
        self.iface_idx
    }

    // Moves packets from the Internet towards the user
    fn write(&self, bytes: &[u8]) -> io::Result<usize> {
        let len = bytes
            .len()
            .try_into()
            .map_err(|_| io::Error::other("Packet too large; length does not fit into u16"))?;

        let Ok(mut pkt) = self.session.allocate_send_packet(len) else {
            // Ring buffer is full, just drop the packet since we're at the IP layer
            return Ok(0);
        };

        pkt.bytes_mut().copy_from_slice(bytes);
        // `send_packet` cannot fail to enqueue the packet, since we already allocated
        // space in the ring buffer.
        self.session.send_packet(pkt);
        Ok(bytes.len())
    }
}

impl tun::Tun for Tun {
    // Moves packets from the user towards the Internet
    fn poll_read(&mut self, buf: &mut [u8], cx: &mut Context<'_>) -> Poll<io::Result<usize>> {
        let pkt = ready!(self.packet_rx.poll_recv(cx));

        match pkt {
            Some(pkt) => {
                let bytes = pkt.bytes();
                let len = bytes.len();
                if len > buf.len() {
                    // This shouldn't happen now that we set IPv4 and IPv6 MTU
                    // If it does, something is wrong.
                    tracing::warn!("Packet is too long to read ({len} bytes)");
                    return Poll::Ready(Ok(0));
                }
                buf[0..len].copy_from_slice(bytes);
                Poll::Ready(Ok(len))
            }
            None => {
                tracing::error!("error receiving packet from mpsc channel");
                Poll::Ready(Err(std::io::ErrorKind::Other.into()))
            }
        }
    }

    fn name(&self) -> &str {
        TUNNEL_NAME
    }

    fn write4(&self, bytes: &[u8]) -> io::Result<usize> {
        self.write(bytes)
    }

    fn write6(&self, bytes: &[u8]) -> io::Result<usize> {
        self.write(bytes)
    }
}

// Moves packets from the user towards the Internet
fn start_recv_thread(
    packet_tx: mpsc::Sender<wintun::Packet>,
    session: Arc<wintun::Session>,
) -> io::Result<std::thread::JoinHandle<()>> {
    std::thread::Builder::new()
        .name("Firezone wintun worker".into())
        .spawn(move || loop {
            let pkt = match session.receive_blocking() {
                Ok(pkt) => pkt,
                Err(wintun::Error::ShuttingDown) => {
                    tracing::info!(
                        "Stopping outbound worker thread because Wintun is shutting down"
                    );
                    break;
                }
                Err(e) => {
                    tracing::error!("wintun::Session::receive_blocking: {e:#?}");
                    break;
                }
            };

            // Use `blocking_send` so that if connlib is behind by a few packets,
            // Wintun will queue up new packets in its ring buffer while we
            // wait for our MPSC channel to clear.
            // Unfortunately we don't know if Wintun is dropping packets, since
            // it doesn't expose a sequence number or anything.
            match packet_tx.blocking_send(pkt) {
                Ok(()) => {}
                Err(_) => {
                    tracing::info!(
                        "Stopping outbound worker thread because the packet channel closed"
                    );
                    break;
                }
            }
        })
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
        if family == AF_INET6 && error.code() == windows_core::HRESULT::from_win32(0x80070490) {
            tracing::debug!(?family, "Couldn't set MTU, maybe IPv6 is disabled.");
        } else {
            tracing::warn!(?family, error = std_dyn_err(&error), "Couldn't set MTU");
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

    let actual_len = usize::try_from(f.metadata().unwrap().len()).unwrap();
    let expected_len = dll_bytes.bytes.len();
    // If the dll is 100 MB instead of 0.5 MB, this allows us to skip a 100 MB read
    if actual_len != expected_len {
        return false;
    }

    let mut buf = vec![0u8; expected_len];
    if f.read_exact(&mut buf).is_err() {
        return false;
    }

    let expected = ring::test::from_hex(dll_bytes.expected_sha256).unwrap();
    let actual = digest::digest(&digest::SHA256, &buf);
    expected == actual.as_ref()
}

/// Returns the absolute path for installing and loading `wintun.dll`
///
/// e.g. `C:\Users\User\AppData\Local\dev.firezone.client\data\wintun.dll`
fn wintun_dll_path() -> Result<PathBuf> {
    let path = crate::windows::app_local_data_dir()?
        .join("data")
        .join("wintun.dll");
    Ok(path)
}

struct DllBytes {
    /// Bytes embedded in the client with `include_bytes`
    pub bytes: &'static [u8],
    /// Expected SHA256 hash
    pub expected_sha256: &'static str,
}

#[cfg(target_arch = "x86_64")]
fn wintun_bytes() -> DllBytes {
    DllBytes {
        bytes: include_bytes!("../wintun/bin/amd64/wintun.dll"),
        expected_sha256: "e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce",
    }
}

#[cfg(target_arch = "aarch64")]
fn wintun_bytes() -> DllBytes {
    DllBytes {
        bytes: include_bytes!("../wintun/bin/arm64/wintun.dll"),
        expected_sha256: "f7ba89005544be9d85231a9e0d5f23b2d15b3311667e2dad0debd344918a3f80",
    }
}
