use connlib_shared::{messages::Interface as InterfaceConfig, Result, DNS_SENTINEL};
use futures::task::AtomicWaker;
use ip_network::IpNetwork;
use std::{
    ffi::c_void,
    io,
    net::{SocketAddrV4, SocketAddrV6},
    ops::Deref,
    os::windows::process::CommandExt,
    process::{Command, Stdio},
    str::FromStr,
    sync::{Arc, Mutex},
    task::{Context, Poll},
};
use windows::Win32::{
    self,
    NetworkManagement::{
        IpHelper::{
            CreateIpForwardEntry2, GetIpInterfaceEntry, InitializeIpForwardEntry,
            SetIpInterfaceEntry, MIB_IPFORWARD_ROW2, MIB_IPINTERFACE_ROW,
        },
        Ndis::NET_LUID_LH,
    },
    Networking::WinSock::{AF_INET, AF_INET6},
};
use windows::Win32::{
    Foundation::{BOOLEAN, HANDLE},
    System::Threading::{
        RegisterWaitForSingleObject, UnregisterWaitEx, INFINITE, WT_EXECUTEINWAITTHREAD,
    },
};

// TODO: Double-check that all these get dropped gracefully on disconnect
pub struct Tun {
    _adapter: Arc<wintun::Adapter>,
    /// The index of our network adapter, we can use this when asking Windows to add / remove routes / DNS rules
    /// It's stable across app restarts and I'm assuming across system reboots too.
    iface_idx: u32,
    // Arc because the recv calls are implemented on Arc
    session: Arc<wintun::Session>,
    wait_handle: Win32::Foundation::HANDLE,
    // Pin<Box> needed so that we can pass a pointer to the wait handle callback
    // and it probably won't move. (I might be mis-understanding Pin here)
    // Mutex needed because AtomicWaker has a debug assert if you call `register` concurrently
    waker: Mutex<std::pin::Pin<Box<AtomicWaker>>>,
}

impl Drop for Tun {
    fn drop(&mut self) {
        tracing::debug!("dropping Tun");
        // SAFETY: wait_handle should be valid because it's set when the Tun is created,
        // and never changes after that, and is never used by any other functions.
        // Rust should only call Drop once, so we shouldn't unregister the same wait twice.
        // INVALID_HANDLE_VALUE means that we will wait for the callbacks to complete before
        // returning from UnregisterWaitEx, so we don't drop a waker that's in use
        // or about to be used.
        unsafe { UnregisterWaitEx(self.wait_handle, Win32::Foundation::INVALID_HANDLE_VALUE) }
            .unwrap();
        self.session.shutdown().unwrap();
    }
}

// Hides Powershell's console on Windows
// <https://stackoverflow.com/questions/59692146/is-it-possible-to-use-the-standard-library-to-spawn-a-process-without-showing-th#60958956>
const CREATE_NO_WINDOW: u32 = 0x08000000;
// Copied from tun_linux.rs
const DEFAULT_MTU: u32 = 1280;

impl Tun {
    pub fn new(config: &InterfaceConfig) -> Result<Self> {
        const TUNNEL_UUID: &str = "e9245bc1-b8c1-44ca-ab1d-c6aad4f13b9c";
        // wintun automatically appends " Tunnel" to this
        const TUNNEL_NAME: &str = "Firezone";

        // The unsafe is here because we're loading a DLL from disk and it has arbitrary C code in it.
        // The Windows client, in `wintun_install` hashes the DLL at startup, before calling connlib, so it's unlikely for the DLL to be accidentally corrupted by the time we get here.
        let wintun = unsafe { wintun::load_from_path("./wintun.dll") }?;
        let uuid = uuid::Uuid::from_str(TUNNEL_UUID)?;
        let adapter = match wintun::Adapter::create(
            &wintun,
            "Firezone",
            TUNNEL_NAME,
            Some(uuid.as_u128()),
        ) {
            Ok(x) => x,
            Err(e) => {
                tracing::error!(
                        "wintun::Adapter::create failed, probably need admin powers, or the previous interface didn't close: {}",
                        e
                    );
                return Err(e.into());
            }
        };

        tracing::debug!("Setting our IPv4 = {}", config.ipv4);
        tracing::debug!("Setting our IPv6 = {}", config.ipv6);

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
            .arg(format!("address={}", config.ipv4))
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
            .arg(format!("address={}", config.ipv6))
            .stdout(Stdio::null())
            .status()?;

        tracing::debug!("Our IPs are {:?}", adapter.get_addresses()?);

        let iface_idx = adapter.get_adapter_index()?;

        // Remove any routes that were previously associated with us
        // TODO: Pick a more elegant way to do this
        Command::new("powershell")
            .creation_flags(CREATE_NO_WINDOW)
            .arg("-Command")
            .arg(format!(
                "Remove-NetRoute -InterfaceIndex {iface_idx} -Confirm:$false"
            ))
            .stdout(Stdio::null())
            .status()?;

        set_iface_config(adapter.get_luid(), DEFAULT_MTU)?;

        // Set our DNS IP as the DNS server for our interface
        // TODO: Lots of issues with this. Windows does seem to use it, but I'm not sure why. And there's a delay before some Firefox windows pick it up. Curl might be picking it up faster because its DNS cache starts cold every time.
        Command::new("powershell")
            .creation_flags(CREATE_NO_WINDOW)
            .arg("-Command")
            .arg(format!(
                "Set-DnsClientServerAddress -InterfaceIndex {iface_idx} -ServerAddresses(\"{DNS_SENTINEL}\")"
            ))
            .stdout(Stdio::null())
            .status()?;

        let session = Arc::new(adapter.start_session(wintun::MAX_RING_CAPACITY)?);
        let mut wait_handle = HANDLE(0isize);
        let read_event = session.get_read_wait_event()?;
        let waker = Box::pin(AtomicWaker::default());
        let waker_ptr: *const AtomicWaker = waker.deref();

        unsafe {
            RegisterWaitForSingleObject(
                &mut wait_handle,
                HANDLE(read_event.0),
                Some(callback),
                Some(waker_ptr as *const _),
                INFINITE, // Infinite timeout should be okay since we only set up one wait for tunnel instance, and we try to unregister this wait when the tunnel is dropped
                WT_EXECUTEINWAITTHREAD,
            )
        }?;
        let waker = Mutex::new(waker);

        Ok(Self {
            _adapter: adapter,
            iface_idx,
            session,
            waker,
            wait_handle,
        })
    }

    // It's okay if this blocks until the route is added in the OS.
    pub fn add_route(&self, route: IpNetwork) -> Result<()> {
        tracing::debug!("add_route {route}");
        let mut row = MIB_IPFORWARD_ROW2::default();
        // Safety: Windows shouldn't store the reference anywhere, it's just setting defaults
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

        row.InterfaceIndex = self.iface_idx;
        row.Metric = 0;

        // Safety: Windows shouldn't store the reference anywhere, it's just a way to pass lots of arguments at once.
        match unsafe { CreateIpForwardEntry2(&row) } {
            Ok(_) => {}
            Err(e) => {
                if e.code().0 as u32 == 0x80071392 {
                    // "Object already exists" error
                    tracing::warn!("Failed to add duplicate route, ignoring");
                } else {
                    Err(e)?;
                }
            }
        }
        Ok(())
    }

    pub fn poll_read(&self, buf: &mut [u8], cx: &mut Context<'_>) -> Poll<io::Result<usize>> {
        // wintun's blocking receive internally spins 5 times before blocking,
        // so I'll do the same here
        for _ in 0..5 {
            match self.try_receive(buf) {
                Err(e) => return Poll::Ready(Err(e)),
                Ok(None) => {}
                Ok(Some(x)) => return Poll::Ready(Ok(x)),
            }
        }

        {
            let waker = self.waker.lock().unwrap();
            waker.register(cx.waker());
        }

        // Must try_receive again in case a packet arrived while we were registering.
        // https://docs.rs/futures/latest/futures/task/struct.AtomicWaker.html#examples
        match self.try_receive(buf) {
            Err(e) => return Poll::Ready(Err(e)),
            Ok(None) => {}
            Ok(Some(x)) => return Poll::Ready(Ok(x)),
        }

        Poll::Pending
    }

    /// Try to receive a packet without blocking
    fn try_receive(&self, buf: &mut [u8]) -> io::Result<Option<usize>> {
        match self.session.try_receive() {
            Ok(None) => Ok(None), // No packet available yet
            Ok(Some(pkt)) => {
                let bytes = pkt.bytes();
                let len = bytes.len();
                if len > buf.len() {
                    // This shouldn't happen now that we set IPv4 and IPv6 MTU
                    // If it does, something is wrong.
                    tracing::warn!("Packet is too long to read ({len} bytes)");
                    return Ok(None);
                }
                // wintun's API requires this memcpy
                buf[0..len].copy_from_slice(bytes);
                Ok(Some(len))
            }
            Err(err) => Err(err.into()),
        }
    }

    pub fn write4(&self, bytes: &[u8]) -> io::Result<usize> {
        self.write(bytes)
    }

    pub fn write6(&self, bytes: &[u8]) -> io::Result<usize> {
        self.write(bytes)
    }

    fn write(&self, bytes: &[u8]) -> io::Result<usize> {
        // Don't block.
        let Ok(mut pkt) = self
            .session
            .allocate_send_packet(bytes.len().try_into().unwrap())
        else {
            // Couldn't write any bytes, the send buffer is full.
            return Ok(0);
        };
        pkt.bytes_mut().copy_from_slice(bytes);
        self.session.send_packet(pkt);
        Ok(bytes.len())
    }
}

/// Callback function for Windows to wake us up to read a packet
// SAFETY: Tun's Drop should unregister this callback before the waker gets dropped
// Calling UnregisterWaitEx with INVALID_HANDLE_VALUE means that the Drop impl
// will wait for this callback to complete before the waker is dropped.
unsafe extern "system" fn callback(ctx: *mut c_void, _: BOOLEAN) {
    let waker = &*(ctx as *const AtomicWaker);
    waker.wake()
}

/// Sets MTU on the interface
/// TODO: Set IP and other things in here too, so the code is more organized
fn set_iface_config(luid: wintun::NET_LUID_LH, mtu: u32) -> Result<()> {
    // Safety: Both NET_LUID_LH unions should be the same. We're just copying out
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

        unsafe { GetIpInterfaceEntry(&mut row) }?;

        // https://stackoverflow.com/questions/54857292/setipinterfaceentry-returns-error-invalid-parameter
        row.SitePrefixLength = 0;

        // Set MTU for IPv4
        row.NlMtu = mtu;
        unsafe { SetIpInterfaceEntry(&mut row) }?;
    }

    // Set MTU for IPv6
    {
        let mut row = MIB_IPINTERFACE_ROW {
            Family: AF_INET6,
            InterfaceLuid: luid,
            ..Default::default()
        };

        unsafe { GetIpInterfaceEntry(&mut row) }?;

        // https://stackoverflow.com/questions/54857292/setipinterfaceentry-returns-error-invalid-parameter
        row.SitePrefixLength = 0;

        // Set MTU for IPv4
        row.NlMtu = mtu;
        unsafe { SetIpInterfaceEntry(&mut row) }?;
    }
    Ok(())
}
