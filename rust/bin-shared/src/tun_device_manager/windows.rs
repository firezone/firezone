use anyhow::{Context as _, Result};
use connlib_shared::{
    windows::{CREATE_NO_WINDOW, TUNNEL_NAME},
    DEFAULT_MTU,
};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use std::{
    collections::HashSet,
    io,
    net::{Ipv4Addr, Ipv6Addr, SocketAddrV4, SocketAddrV6},
    os::windows::process::CommandExt,
    process::{Command, Stdio},
    str::FromStr,
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
    Networking::WinSock::{AF_INET, AF_INET6},
};
use wintun::Adapter;

// Not sure how this and `TUNNEL_NAME` differ
const ADAPTER_NAME: &str = "Firezone";
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
    iface_idx: Option<u32>,

    routes: HashSet<IpNetwork>,
}

impl TunDeviceManager {
    // Fallible on Linux
    #[allow(clippy::unnecessary_wraps)]
    pub fn new() -> Result<Self> {
        Ok(Self {
            iface_idx: None,
            routes: HashSet::default(),
        })
    }

    pub fn make_tun(&mut self) -> Result<Tun> {
        let tun = Tun::new()?;
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

        if new_routes == self.routes {
            return Ok(());
        }

        for new_route in new_routes.difference(&self.routes) {
            add_route(*new_route, iface_idx)?;
        }

        for old_route in self.routes.difference(&new_routes) {
            remove_route(*old_route, iface_idx)?;
        }

        self.routes = new_routes;

        Ok(())
    }
}

// It's okay if this blocks until the route is added in the OS.
fn add_route(route: IpNetwork, iface_idx: u32) -> Result<()> {
    const DUPLICATE_ERR: u32 = 0x80071392;
    let entry = forward_entry(route, iface_idx);

    // SAFETY: Windows shouldn't store the reference anywhere, it's just a way to pass lots of arguments at once. And no other thread sees this variable.
    match unsafe { CreateIpForwardEntry2(&entry) }.ok() {
        Ok(()) => Ok(()),
        Err(e) if e.code().0 as u32 == DUPLICATE_ERR => {
            tracing::debug!(%route, "Failed to add duplicate route, ignoring");
            Ok(())
        }
        Err(e) => Err(e.into()),
    }
}

// It's okay if this blocks until the route is removed in the OS.
fn remove_route(route: IpNetwork, iface_idx: u32) -> Result<()> {
    let entry = forward_entry(route, iface_idx);

    // SAFETY: Windows shouldn't store the reference anywhere, it's just a way to pass lots of arguments at once. And no other thread sees this variable.
    unsafe { DeleteIpForwardEntry2(&entry) }.ok()?;
    Ok(())
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
            tracing::error!(?error, "wintun::Session::shutdown");
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
    pub fn new() -> Result<Self> {
        const TUNNEL_UUID: &str = "e9245bc1-b8c1-44ca-ab1d-c6aad4f13b9c";

        // SAFETY: we're loading a DLL from disk and it has arbitrary C code in it.
        // The Windows client, in `wintun_install` hashes the DLL at startup, before calling connlib, so it's unlikely for the DLL to be accidentally corrupted by the time we get here.
        let path = connlib_shared::windows::wintun_dll_path()?;
        let wintun = unsafe { wintun::load_from_path(path) }?;

        // Create wintun adapter
        let uuid = uuid::Uuid::from_str(TUNNEL_UUID)
            .expect("static UUID should always parse correctly")
            .as_u128();
        let adapter = &Adapter::create(&wintun, ADAPTER_NAME, TUNNEL_NAME, Some(uuid))?;
        let iface_idx = adapter.get_adapter_index()?;

        set_iface_config(adapter.get_luid(), DEFAULT_MTU as u32)?;

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
    #[allow(clippy::unnecessary_wraps)] // Fn signature must align with other platform implementations.
    fn write(&self, bytes: &[u8]) -> io::Result<usize> {
        let len = bytes
            .len()
            .try_into()
            .expect("Packet length should fit into u16");

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

    // Set MTU for IPv4
    {
        let mut row = MIB_IPINTERFACE_ROW {
            Family: AF_INET,
            InterfaceLuid: luid,
            ..Default::default()
        };

        // SAFETY: TODO
        unsafe { GetIpInterfaceEntry(&mut row) }.ok()?;

        // https://stackoverflow.com/questions/54857292/setipinterfaceentry-returns-error-invalid-parameter
        row.SitePrefixLength = 0;

        // Set MTU for IPv4
        row.NlMtu = mtu;

        // SAFETY: TODO
        unsafe { SetIpInterfaceEntry(&mut row) }.ok()?;
    }

    // Set MTU for IPv6
    {
        let mut row = MIB_IPINTERFACE_ROW {
            Family: AF_INET6,
            InterfaceLuid: luid,
            ..Default::default()
        };

        // SAFETY: TODO
        unsafe { GetIpInterfaceEntry(&mut row) }.ok()?;

        // https://stackoverflow.com/questions/54857292/setipinterfaceentry-returns-error-invalid-parameter
        row.SitePrefixLength = 0;

        // Set MTU for IPv4
        row.NlMtu = mtu;

        // SAFETY: TODO
        unsafe { SetIpInterfaceEntry(&mut row) }.ok()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tracing_subscriber::EnvFilter;

    /// Checks for regressions in issue #4765, un-initializing Wintun
    #[test]
    #[ignore = "Needs admin privileges"]
    fn tunnel_drop() {
        let _ = tracing_subscriber::fmt()
            .with_env_filter(EnvFilter::from_default_env())
            .with_test_writer()
            .try_init();
        // Each cycle takes about half a second, so this will take a fair bit to run.
        for _ in 0..50 {
            let _tun = Tun::new().unwrap(); // This will panic if we don't correctly clean-up the wintun interface.
        }
    }
}
