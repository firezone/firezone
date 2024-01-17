//! A module for getting callbacks from Windows when we gain / lose Internet connectivity
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
//! DNS server changes are (TODO?)
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

use std::sync::Arc;
use tokio::{runtime::Runtime, sync::Notify};
use windows::{
    core::{ComInterface, Result as WinResult, GUID},
    Win32::{
        Networking::NetworkListManager::{
            INetworkEvents, INetworkEvents_Impl, INetworkListManager, NetworkListManager,
            NLM_CONNECTIVITY, NLM_NETWORK_PROPERTY_CHANGE,
        },
        System::Com,
    },
};

/// Debug subcommand to test network connectivity events
pub(crate) fn run_debug() -> WinResult<()> {
    tracing_subscriber::fmt::init();

    // Returns Err before COM is initialized
    assert!(get_apartment_type().is_err());

    let com = ComGuard::new()?;

    // We just initialized COM on the main thread, so we should be in an MTA
    assert_eq!(
        get_apartment_type()?,
        (Com::APTTYPE_MTA, Com::APTTYPEQUALIFIER_NONE)
    );

    let rt = Runtime::new().unwrap();

    let notify = Arc::new(Notify::new());
    let _listener = Listener::new(&com, Arc::clone(&notify))?;
    println!("Listening for network events...");

    rt.block_on(async move {
        loop {
            // Make sure whatever Tokio thread we're on is associated with COM
            // somehow.
            assert_eq!(
                get_apartment_type()?,
                (Com::APTTYPE_MTA, Com::APTTYPEQUALIFIER_NONE)
            );

            println!("check_internet() = {}", Listener::check_internet()?);
            notify.notified().await;
        }
    })
}

/// Worker thread that can be joined explicitly, and joins on Drop
pub(crate) struct Worker {
    inner: Option<WorkerInner>,
    notify: Arc<Notify>,
}

/// Needed so that `Drop` can consume the oneshot Sender and the thread's JoinHandle
struct WorkerInner {
    thread: std::thread::JoinHandle<WinResult<()>>,
    stopper: tokio::sync::oneshot::Sender<()>,
}

impl Worker {
    pub fn new() -> anyhow::Result<Self> {
        let notify = Arc::new(Notify::new());

        let (stopper, rx) = tokio::sync::oneshot::channel();
        let thread = {
            let notify = Arc::clone(&notify);
            std::thread::Builder::new()
                .name("Firezone COM worker".into())
                .spawn(move || -> windows::core::Result<()> {
                    {
                        let com = ComGuard::new()?;
                        let _network_change_listener = Listener::new(&com, notify)?;
                        rx.blocking_recv().ok();
                    }
                    tracing::debug!("COM worker thread shut down gracefully");
                    Ok(())
                })?
        };

        Ok(Self {
            inner: Some(WorkerInner { thread, stopper }),
            notify,
        })
    }

    pub async fn notified(&self) {
        self.notify.notified().await;
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        if let Some(inner) = self.inner.take() {
            inner
                .stopper
                .send(())
                .expect("should be able to stop the worker thread");
            inner
                .thread
                .join()
                .expect("should be able to join the worker thread")
                .expect("worker thread should not have returned an error");
        }
    }
}

/// Enforces the initialize-use-uninitialize order for `Listener` and COM
struct ComGuard {
    dropped: bool,
}

impl ComGuard {
    /// Initialize a "Multi-threaded apartment" so that Windows COM stuff
    /// can be called, and COM callbacks can work.
    pub fn new() -> WinResult<Self> {
        // SAFETY: TODO, not sure if anything can go wrong here
        unsafe { Com::CoInitializeEx(None, Com::COINIT_MULTITHREADED) }?;
        Ok(Self { dropped: false })
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
            tracing::debug!("Uninitialized COM");
        }
    }
}

/// Checks what COM apartment the current thread is in. For debugging only.
fn get_apartment_type() -> WinResult<(Com::APTTYPE, Com::APTTYPEQUALIFIER)> {
    let mut apt_type = Com::APTTYPE_CURRENT;
    let mut apt_qualifier = Com::APTTYPEQUALIFIER_NONE;

    // SAFETY: We just created the variables, and they're out parameters,
    // so Windows shouldn't store the pointers.
    unsafe { Com::CoGetApartmentType(&mut apt_type, &mut apt_qualifier) }?;
    Ok((apt_type, apt_qualifier))
}

/// Listens to network connectivity change eents
pub(crate) struct Listener<'a> {
    /// The cookies we get back from `Advise`. Can be None if the owner called `close`
    ///
    /// This has to be mutable because we have to hook up the callbacks during
    /// Listener's constructor
    advise_cookie_net: Option<u32>,
    cxn_point_net: Com::IConnectionPoint,

    inner: ListenerInner,

    /// Hold a reference to a `ComGuard` to enforce the right init-use-uninit order
    _com: &'a ComGuard,
}

/// This must be separate because we need to `Clone` that `Notify` and we can't
/// `Clone` the COM objects in `Listener`
// https://kennykerr.ca/rust-getting-started/how-to-implement-com-interface.html
#[windows_implement::implement(INetworkEvents)]
#[derive(Clone)]
struct ListenerInner {
    notify: Arc<Notify>,
}

impl<'a> Drop for Listener<'a> {
    fn drop(&mut self) {
        self.close().unwrap();
    }
}

impl<'a> Listener<'a> {
    /// Creates a new Listener
    ///
    /// # Arguments
    ///
    /// * `com` - Makes sure that CoInitializeEx was called. Must have been created
    ///   on the same thread as `new` is called on.
    /// * `notify` - A Tokio `Notify` that will be notified when Windows detects
    ///   connectivity changes. Some notifications may be spurious.
    fn new(com: &'a ComGuard, notify: Arc<Notify>) -> WinResult<Self> {
        // `windows-rs` automatically releases (de-refs) COM objects on Drop:
        // https://github.com/microsoft/windows-rs/issues/2123#issuecomment-1293194755
        // https://github.com/microsoft/windows-rs/blob/cefdabd15e4a7a7f71b7a2d8b12d5dc148c99adb/crates/samples/windows/wmi/src/main.rs#L22
        let network_list_manager: INetworkListManager =
            unsafe { Com::CoCreateInstance(&NetworkListManager, None, Com::CLSCTX_ALL) }?;
        let cpc: Com::IConnectionPointContainer = network_list_manager.cast()?;
        let cxn_point_net = unsafe { cpc.FindConnectionPoint(&INetworkEvents::IID) }?;

        let mut this = Listener {
            advise_cookie_net: None,
            cxn_point_net,
            inner: ListenerInner { notify },
            _com: com,
        };

        let callbacks: INetworkEvents = this.inner.clone().into();

        // SAFETY: What happens if Windows sends us a network change event while
        // we're dropping Listener?
        // Is it safe to Advise on `this` and then immediately move it?
        this.advise_cookie_net = Some(unsafe { this.cxn_point_net.Advise(&callbacks) }?);

        // After we call `Advise`, notify. This should avoid a problem if this happens:
        //
        // 1. Caller spawns a worker thread for Listener, but the worker thread isn't scheduled
        // 2. Caller continues setup, checks Internet is connected
        // 3. Internet gets disconnected but caller isn't notified
        // 4. Worker thread finally gets scheduled, but we never notify that the Internet was lost during setup. Caller is now out of sync with ground truth.
        this.inner.notify.notify_one();

        Ok(this)
    }

    /// This is the same as Drop, but you can catch errors from it
    /// Calling this multiple times is idempotent
    ///
    /// Unregisters the network change callbacks
    pub fn close(&mut self) -> WinResult<()> {
        if let Some(cookie) = self.advise_cookie_net.take() {
            // SAFETY: I don't see any memory safety issues.
            unsafe { self.cxn_point_net.Unadvise(cookie) }?;
            tracing::debug!("Unadvised");
        }
        Ok(())
    }

    /// Returns true if Windows thinks we have Internet access per [IsConnectedToInternet](https://learn.microsoft.com/en-us/windows/win32/api/netlistmgr/nf-netlistmgr-inetworklistmanager-get_isconnectedtointernet)
    ///
    /// Call this when `Listener` notifies you.
    pub fn check_internet() -> WinResult<bool> {
        // Retrieving the INetworkListManager takes less than half a millisecond, and this
        // makes the lifetimes and Send+Sync much simpler for callers, so just retrieve it
        // every single time.
        let network_list_manager: INetworkListManager =
            unsafe { Com::CoCreateInstance(&NetworkListManager, None, Com::CLSCTX_ALL) }?;
        let have_internet = unsafe { network_list_manager.IsConnectedToInternet() }?.as_bool();

        Ok(have_internet)
    }
}

impl INetworkEvents_Impl for ListenerInner {
    fn NetworkAdded(&self, _networkid: &GUID) -> WinResult<()> {
        Ok(())
    }

    fn NetworkDeleted(&self, _networkid: &GUID) -> WinResult<()> {
        Ok(())
    }

    fn NetworkConnectivityChanged(
        &self,
        _networkid: &GUID,
        _newconnectivity: NLM_CONNECTIVITY,
    ) -> WinResult<()> {
        self.notify.notify_one();
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
