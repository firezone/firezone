//! A module for getting callbacks from Windows when we gain / lose Internet connectivity
//!
//! # Use
//!
//! - Call `check_internet`
//! - Inside a Tokio context, construct a `Worker`
//! - Await `Worker::notified`
//! - Call `check_internet` again
//! - Loop
//!
//! # Changes detected / not detected
//!
//! Tested manually one time each, with `RUST_LOG=info cargo run -p firezone-gui-client -- debug network-changes`
//!
//! Some network changes will fire multiple events with `have_internet = true` in a row.
//! Others will report `have_internet = false` and then `have_internet = true` once they reconnect.
//!
//! We could attempt to listen for DNS changes by subscribing to changes in the Windows Registry: <https://stackoverflow.com/a/64482724>
//!
//! - Manually changing DNS servers on Wi-Fi, not detected
//!
//! - Wi-Fi-only, enable Airplane Mode, <1 second
//! - Disable Airplane Mode, return to Wi-Fi, <5 seconds
//! - Wi-Fi-only, disable Wi-Fi, <1 second
//! - Wi-Fi-only, enable Wi-Fi, <5 seconds
//! - Switching to hotspot Wi-Fi from a phone, instant (once Windows connects)
//! - Stopping the phone's hotspot and switching back to home Wi-Fi, instant (once Windows connects)
//! - On Wi-Fi, connect Ethernet, <4 seconds
//! - On Ethernet and Wi-Fi, disconnect Ethernet, not detected
//! - On Ethernet, Wi-Fi enabled but not connected, disconnect Ethernet, <2 seconds
//! - On Wi-Fi, WLAN loses Internet, 1 minute (Windows doesn't figure it out immediately)
//! - On Wi-Fi, WLAN regains Internet, 6 seconds (Some of that is the AP)
//!
//! # Latency
//!
//! 2 or 3 seconds for the user clicking "Connect" or "Disconnect" on Wi-Fi,
//! or for plugging or unplugging an Ethernet cable.
//!
//! Plugging in Ethernet may take longer since it waits on DHCP.
//! Connecting to Wi-Fi usually notifies while Windows is showing the progress bar
//! in the Wi-Fi menu.
//!
//! # Worker thread
//!
//! `Listener` must live in a worker thread if used from Tauri.
//! `
//! This is because both `Listener` and some feature in Tauri (maybe drag-and-drop) depend on COM.
//! `Listener` works fine if we initialize COM with COINIT_MULTITHREADED, but
//! Tauri initializes COM some other way.
//!
//! In the debug command we don't need a worker thread because we're the only code
//! in the process using COM.
//!
//! I tried disabling file drag-and-drop in tauri.conf.json, that didn't work:
//! - <https://github.com/tauri-apps/tauri/commit/e0e49d87a200d3681d39ff2dd80bee5d408c943e>
//! - <https://tauri.app/v1/api/js/window/#filedropenabled>
//! - <https://tauri.app/v1/api/config/#windowconfig>
//!
//! There is some explanation of the COM threading stuff in MSDN here:
//! - <https://learn.microsoft.com/en-us/windows/win32/api/objbase/ne-objbase-coinit>
//! - <https://learn.microsoft.com/en-us/windows/win32/api/combaseapi/nf-combaseapi-coinitializeex>
//!
//! Raymond Chen also explains it on his blog: <https://devblogs.microsoft.com/oldnewthing/20191125-00/?p=103135>

use crate::DnsControlMethod;
use anyhow::{Context as _, Result, anyhow};
use std::collections::HashMap;
use std::sync::Mutex;
use std::thread;
use tokio::sync::{
    mpsc::{self, error::TrySendError},
    oneshot,
};
use windows::{
    Win32::{
        Networking::NetworkListManager::{
            INetworkEvents, INetworkEvents_Impl, INetworkListManager, NLM_CONNECTIVITY,
            NLM_NETWORK_PROPERTY_CHANGE, NetworkListManager,
        },
        System::Com,
    },
    core::{GUID, Interface, Result as WinResult},
};

pub async fn new_dns_notifier(
    tokio_handle: tokio::runtime::Handle,
    _method: DnsControlMethod,
) -> Result<Worker> {
    Worker::new("Firezone DNS notifier worker", move |tx, stopper_rx| {
        winreg_listener::worker_thread(tokio_handle, tx, stopper_rx)?;
        Ok(())
    })
}

pub async fn new_network_notifier(
    _tokio_handle: tokio::runtime::Handle,
    _method: DnsControlMethod,
) -> Result<Worker> {
    Worker::new("Firezone network notifier worker", move |tx, stopper_rx| {
        {
            let com = ComGuard::new()?;
            let listener = Listener::new(&com, tx)?;
            stopper_rx.blocking_recv().ok();
            listener.close()?;
        }
        Ok(())
    })
}

/// Container for a worker thread that we can cooperatively stop.
///
/// The worker thread emits notifications with no data in them.
pub struct Worker {
    inner: Option<WorkerInner>,
    rx: NotifyReceiver,
    thread_name: String,
}

impl Drop for Worker {
    fn drop(&mut self) {
        if let Err(e) = self.close() {
            tracing::error!("Failed to close worker thread: {e:#}")
        }
    }
}

impl Worker {
    fn new<F, S>(thread_name: S, func: F) -> Result<Self>
    where
        F: FnOnce(NotifySender, oneshot::Receiver<()>) -> Result<()> + Send + 'static,
        S: Into<String>,
    {
        let thread_name = thread_name.into();
        let (tx, rx) = notify_channel();
        let inner = WorkerInner::new(thread_name.clone(), tx, func)?;
        Ok(Self {
            inner: Some(inner),
            rx,
            thread_name,
        })
    }

    /// Same as `drop`, but you can catch errors
    pub fn close(&mut self) -> Result<()> {
        if let Some(inner) = self.inner.take() {
            tracing::trace!(
                thread_name = self.thread_name,
                "Asking worker thread to stop gracefully"
            );
            inner
                .stopper
                .send(())
                .map_err(|_| anyhow!("Couldn't stop `NetworkNotifier` worker thread"))?;
            match inner.thread.join() {
                Err(e) => std::panic::resume_unwind(e),
                Ok(x) => x?,
            }
            tracing::trace!("Worker thread stopped gracefully");
        }
        Ok(())
    }

    pub async fn notified(&mut self) -> Result<()> {
        self.rx
            .notified()
            .await
            .context("Couldn't listen to notifications.")?;
        Ok(())
    }
}

/// Opens and returns the IPv4 and IPv6 registry keys
///
/// `HKEY_LOCAL_MACHINE/SYSTEM/CurrentControlSet/Services/Tcpip[6]/Parameters/Interfaces`
fn open_network_registry_keys() -> Result<(RegKey, RegKey)> {
    let hklm = winreg::RegKey::predef(winreg::enums::HKEY_LOCAL_MACHINE);
    let path_4 = Path::new("SYSTEM")
        .join("CurrentControlSet")
        .join("Services")
        .join("Tcpip")
        .join("Parameters")
        .join("Interfaces");
    let path_6 = Path::new("SYSTEM")
        .join("CurrentControlSet")
        .join("Services")
        .join("Tcpip6")
        .join("Parameters")
        .join("Interfaces");
    let flags = winreg::enums::KEY_NOTIFY;
    Ok((
        hklm.open_subkey_with_flags(path_4, flags)?,
        hklm.open_subkey_with_flags(path_6, flags)?,
    ))
}

/// Needed so that `Drop` can consume the oneshot Sender and the thread's JoinHandle
struct WorkerInner {
    stopper: oneshot::Sender<()>,
    thread: thread::JoinHandle<Result<()>>,
}

impl WorkerInner {
    fn new<
        F: FnOnce(NotifySender, oneshot::Receiver<()>) -> Result<()> + Send + 'static,
        S: Into<String>,
    >(
        thread_name: S,
        tx: NotifySender,
        func: F,
    ) -> Result<Self> {
        let (stopper, stopper_rx) = tokio::sync::oneshot::channel();
        let thread = std::thread::Builder::new()
            .name(thread_name.into())
            .spawn(move || func(tx, stopper_rx))?;

        Ok(Self { stopper, thread })
    }
}

/// Enforces the initialize-use-uninitialize order for `Listener` and COM
///
/// COM is meant to be initialized for a thread, and un-initialized for the same thread,
/// so don't pass this between threads.
struct ComGuard {
    dropped: bool,
    _unsend_unsync: PhantomUnsendUnsync,
}

/// Marks a type as !Send and !Sync without nightly / unstable features
///
/// <https://stackoverflow.com/questions/62713667/how-to-implement-send-or-sync-for-a-type>
type PhantomUnsendUnsync = std::marker::PhantomData<*const ()>;

impl ComGuard {
    /// Initialize a "Multi-threaded apartment" so that Windows COM stuff
    /// can be called, and COM callbacks can work.
    pub fn new() -> Result<Self> {
        // SAFETY: Threading shouldn't be a problem since this is meant to initialize
        // COM per-thread anyway.
        unsafe { Com::CoInitializeEx(None, Com::COINIT_MULTITHREADED) }
            .ok()
            .context("Failed in `CoInitializeEx`")?;
        Ok(Self {
            dropped: false,
            _unsend_unsync: Default::default(),
        })
    }
}

impl Drop for ComGuard {
    fn drop(&mut self) {
        if !self.dropped {
            self.dropped = true;
            // Required, per [CoInitializeEx docs](https://learn.microsoft.com/en-us/windows/win32/api/combaseapi/nf-combaseapi-coinitializeex#remarks)
            // Safety: Make sure all the COM objects are dropped before we call
            // CoUninitialize or the program might segfault.
            unsafe { Com::CoUninitialize() };
            tracing::trace!("Uninitialized COM");
        }
    }
}

/// Listens to network connectivity change events
struct Listener<'a> {
    /// The cookies we get back from `Advise`. Can be None if the owner called `close`
    ///
    /// This has to be mutable because we have to hook up the callbacks during
    /// Listener's constructor
    advise_cookie_net: Option<u32>,
    cxn_point_net: Com::IConnectionPoint,

    /// Hold a reference to a `ComGuard` to enforce the right init-use-uninit order
    _com: &'a ComGuard,
}

// https://kennykerr.ca/rust-getting-started/how-to-implement-com-interface.html
#[windows_implement::implement(INetworkEvents)]
struct Callback {
    tx: NotifySender,
    firezone_network_profile_id: Option<GUID>,
    network_states: Mutex<HashMap<GUID, NLM_CONNECTIVITY>>,
}

impl Drop for Listener<'_> {
    // Might never be called. Due to the way the scopes ended up,
    // we crash the GUI process before we can get back to the main thread
    // and drop the DNS listeners
    fn drop(&mut self) {
        if let Err(e) = self.close_dont_drop() {
            tracing::error!("Failed to close `Listener` gracefully: {e:#}");
        }
    }
}

impl<'a> Listener<'a> {
    /// Creates a new Listener
    ///
    /// # Arguments
    ///
    /// * `com` - Makes sure that CoInitializeEx was called. `com` have been created
    ///   on the same thread as `new` is called on.
    /// * `tx` - A Sender to notify when Windows detects
    ///   connectivity changes. Some notifications may be spurious.
    fn new(com: &'a ComGuard, tx: NotifySender) -> Result<Self> {
        // `windows-rs` automatically releases (de-refs) COM objects on Drop:
        // https://github.com/microsoft/windows-rs/issues/2123#issuecomment-1293194755
        // https://github.com/microsoft/windows-rs/blob/cefdabd15e4a7a7f71b7a2d8b12d5dc148c99adb/crates/samples/windows/wmi/src/main.rs#L22
        // SAFETY: TODO
        let network_list_manager: INetworkListManager =
            unsafe { Com::CoCreateInstance(&NetworkListManager, None, Com::CLSCTX_ALL) }
                .context("Failed in `CoCreateInstance`")?;
        let cpc: Com::IConnectionPointContainer = network_list_manager
            .cast()
            .context("Failed to cast network list manager")?;
        // SAFETY: TODO
        let cxn_point_net = unsafe { cpc.FindConnectionPoint(&INetworkEvents::IID) }
            .context("Failed in `FindConnectionPoint`")?;

        let mut this = Listener {
            advise_cookie_net: None,
            cxn_point_net,
            _com: com,
        };

        let cb = Callback {
            tx: tx.clone(),
            firezone_network_profile_id: get_network_id_of_firezone_adapter()
                .inspect_err(|e| tracing::warn!("{e:#}"))
                .ok(),
            network_states: Default::default(),
        };

        let callbacks: INetworkEvents = cb.into();

        // SAFETY: What happens if Windows sends us a network change event while
        // we're dropping Listener?
        // Is it safe to Advise on `this` and then immediately move it?
        this.advise_cookie_net = Some(
            unsafe { this.cxn_point_net.Advise(&callbacks) }
                .context("Failed to listen for network event callbacks")?,
        );

        // After we call `Advise`, notify. This should avoid a problem if this happens:
        //
        // 1. Caller spawns a worker thread for Listener, but the worker thread isn't scheduled
        // 2. Caller continues setup, checks Internet is connected
        // 3. Internet gets disconnected but caller isn't notified
        // 4. Worker thread finally gets scheduled, but we never notify that the Internet was lost during setup. Caller is now out of sync with ground truth.
        tx.notify()?;

        Ok(this)
    }

    /// Like `drop`, but you can catch errors
    ///
    /// Unregisters the network change callbacks
    pub fn close(mut self) -> Result<()> {
        self.close_dont_drop()
    }

    /// Close without consuming `self`
    ///
    /// This must be factored out so that we can have both:
    /// - `close` which consumes `self` and returns a `Result` for error bubbling
    /// - `drop` which does not consume `self` and does not bubble errors, but which runs even if we forget to call `close`
    fn close_dont_drop(&mut self) -> Result<()> {
        if let Some(cookie) = self.advise_cookie_net.take() {
            // SAFETY: I don't see any memory safety issues.
            unsafe { self.cxn_point_net.Unadvise(cookie) }
                .context("Failed to unadvise connection point")?;
            tracing::trace!("Unadvised");
        }
        Ok(())
    }
}

fn get_network_id_of_firezone_adapter() -> Result<GUID> {
    let profiles = winreg::RegKey::predef(winreg::enums::HKEY_LOCAL_MACHINE)
        .open_subkey(r"SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles")
        .context("Failed to open registry key")?;

    for key in profiles.enum_keys() {
        let guid = key.context("Failed to enumerate key")?;

        let profile_name = profiles
            .open_subkey(&guid)
            .with_context(|| format!("Failed to open key `{guid}`"))?
            .get_value::<String, _>("ProfileName")
            .context("Failed to get profile name")?;

        if profile_name == "Firezone" {
            let uuid = guid.trim_start_matches("{").trim_end_matches("}");
            let uuid = uuid
                .parse::<uuid::Uuid>()
                .context("Failed to parse key as UUID")?;

            tracing::debug!(%uuid, "Found `Firezone` network profile id");

            return Ok(GUID::from_u128(uuid.as_u128()));
        }
    }

    anyhow::bail!("Unable to find `Firezone` profile network GUID")
}

// <https://github.com/microsoft/windows-rs/pull/3065>
impl INetworkEvents_Impl for Callback_Impl {
    fn NetworkAdded(&self, _networkid: &GUID) -> WinResult<()> {
        Ok(())
    }

    fn NetworkDeleted(&self, _networkid: &GUID) -> WinResult<()> {
        Ok(())
    }

    fn NetworkConnectivityChanged(
        &self,
        networkid: &GUID,
        newconnectivity: NLM_CONNECTIVITY,
    ) -> WinResult<()> {
        if self
            .firezone_network_profile_id
            .is_some_and(|firezone| networkid == &firezone)
        {
            tracing::debug!("Ignoring network change for `Firezone` adapter");
            return Ok(());
        }

        let mut network_states = self
            .network_states
            .lock()
            .unwrap_or_else(|e| e.into_inner());

        if network_states
            .get(networkid)
            .is_some_and(|state| *state == newconnectivity)
        {
            tracing::debug!(?networkid, "Ignoring duplicate network change");
            return Ok(());
        }

        network_states.insert(*networkid, newconnectivity);

        tracing::debug!(?networkid, ?newconnectivity, "Network connectivity changed");

        // No reasonable way to translate this error into a Windows error
        self.tx.notify().ok();
        Ok(())
    }

    fn NetworkPropertyChanged(
        &self,
        _networkid: &GUID,
        _flags: NLM_NETWORK_PROPERTY_CHANGE,
    ) -> WinResult<()> {
        Ok(())
    }
}

impl Drop for Callback {
    fn drop(&mut self) {
        tracing::trace!("Dropped `network_changes::Callback`");
    }
}

/// Wraps an MPSC channel of capacity 1 to use as a cancel-safe notifier
#[derive(Clone)]
struct NotifySender {
    tx: mpsc::Sender<()>,
}

struct NotifyReceiver {
    rx: mpsc::Receiver<()>,
}

impl NotifySender {
    fn notify(&self) -> Result<()> {
        // If there isn't capacity to send, it's because the receiver has a notification
        // it needs to pick up anyway, so it's fine.
        match self.tx.try_send(()) {
            Ok(()) | Err(TrySendError::Full(())) => Ok(()),
            Err(TrySendError::Closed(())) => Err(anyhow!("TrySendError::Closed")),
        }
    }
}

impl NotifyReceiver {
    async fn notified(&mut self) -> Result<()> {
        self.rx
            .recv()
            .await
            .context("All NotifySender instances are closed")
    }
}

fn notify_channel() -> (NotifySender, NotifyReceiver) {
    let (tx, rx) = mpsc::channel(1);
    (NotifySender { tx }, NotifyReceiver { rx })
}
