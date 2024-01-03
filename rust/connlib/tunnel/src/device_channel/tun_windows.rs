use connlib_shared::{messages::Interface as InterfaceConfig, Result, DNS_SENTINEL};
use futures::task::AtomicWaker;
use ip_network::IpNetwork;
use std::{
    ffi::c_void,
    io,
    net::Ipv6Addr,
    os::windows::process::CommandExt,
    process::{Command, Stdio},
    str::FromStr,
    sync::Arc,
    task::{Context, Poll},
};
use windows::Win32::{
    Foundation::{BOOLEAN, HANDLE},
    System::Threading::{RegisterWaitForSingleObject, INFINITE, WT_EXECUTEINWAITTHREAD},
};

// TODO: Double-check that all these get dropped gracefully on disconnect
pub struct Tun {
    _adapter: Arc<wintun::Adapter>,
    /// The index of our network adapter, we can use this when asking Windows to add / remove routes / DNS rules
    /// It's stable across app restarts and I'm assuming across system reboots too.
    iface_idx: u32,
    session: Arc<wintun::Session>,
    waker: Arc<AtomicWaker>,
}

impl Drop for Tun {
    fn drop(&mut self) {
        tracing::debug!("dropping Tun");
        if let Err(e) = self.session.shutdown() {
            tracing::error!("wintun::Session::shutdown: {e:#?}");
        }
    }
}

// Hides Powershell's console on Windows
// <https://stackoverflow.com/questions/59692146/is-it-possible-to-use-the-standard-library-to-spawn-a-process-without-showing-th#60958956>
const CREATE_NO_WINDOW: u32 = 0x08000000;

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

        // TODO: I think wintun flashes a couple console windows here when it shells out to netsh. We should upstream the same patch I'm doing for powershell to the wintun project
        // We could also try to get rid of wintun dependency entirely
        adapter.set_network_addresses_tuple(
            config.ipv4.into(),
            [255, 255, 255, 255].into(),
            None,
        )?;
        adapter.set_network_addresses_tuple(
            config.ipv6.into(),
            Ipv6Addr::new(
                0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff,
            )
            .into(),
            None,
        )?;

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

        Ok(Self {
            _adapter: adapter,
            iface_idx,
            session,
            waker: Arc::new(Default::default()),
        })
    }

    // It's okay if this blocks until the route is added in the OS.
    pub fn add_route(&self, route: IpNetwork) -> Result<()> {
        let iface_idx = self.iface_idx;
        // TODO: Pick a more elegant way to do this
        Command::new("powershell")
            .creation_flags(CREATE_NO_WINDOW)
            .arg("-Command")
            .arg(format!(
                "New-NetRoute -InterfaceIndex {iface_idx} -DestinationPrefix \"{route}\""
            ))
            .stdout(Stdio::null())
            .status()?;
        Ok(())
    }

    pub fn poll_read(&self, buf: &mut [u8], cx: &mut Context<'_>) -> Poll<io::Result<usize>> {
        // wintun's API requires us to copy a packet here
        let recv = self.session.try_receive();
        match recv {
            Ok(None) => {} // No packet available yet
            Ok(Some(pkt)) => {
                let bytes = pkt.bytes();
                let len = bytes.len();
                if len > buf.len() {
                    // TODO: Need to set MTU on the tunnel interface to prevent this
                    tracing::warn!("Packet is too long to read ({len} bytes)");
                    return Poll::Ready(Ok(0));
                }
                buf[0..len].copy_from_slice(bytes);
                return Poll::Ready(Ok(len));
            }
            Err(err) => return Poll::Ready(Err(err.into())),
        }

        self.waker.register(cx.waker());
        let wait_handle = match self.session.get_read_wait_event() {
            Ok(handle) => handle,
            Err(err) => return Poll::Ready(Err(err.into())),
        };

        let mut obj = HANDLE(0isize);

        tracing::debug!("registering wait event");

        unsafe {
            RegisterWaitForSingleObject(
                &mut obj,
                HANDLE(wait_handle.0),
                Some(callback),
                Some(Arc::into_raw(self.waker.clone()) as *const _),
                INFINITE,
                WT_EXECUTEINWAITTHREAD,
            )
        }?;

        // TODO: Cleanup
        Poll::Pending
    }

    pub fn write4(&self, bytes: &[u8]) -> io::Result<usize> {
        self.write(bytes)
    }

    pub fn write6(&self, bytes: &[u8]) -> io::Result<usize> {
        self.write(bytes)
    }

    fn write(&self, bytes: &[u8]) -> io::Result<usize> {
        // TODO: If the ring buffer is full, don't panic, just return Ok(None) or an error or whatever the Unix impls do
        // Don't block.
        let mut pkt = self
            .session
            .allocate_send_packet(bytes.len().try_into().unwrap())
            .unwrap();
        pkt.bytes_mut().copy_from_slice(bytes);
        self.session.send_packet(pkt);
        Ok(bytes.len())
    }
}

// Callback function for Windows to wake us up to read a packet
unsafe extern "system" fn callback(ctx: *mut c_void, _: BOOLEAN) {
    Arc::from_raw(ctx as *const AtomicWaker).wake()
}
