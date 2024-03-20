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
//! DNS server changes are (TODO <https://github.com/firezone/firezone/issues/3343>)
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

use anyhow::Result;
use std::sync::Arc;
use tokio::{runtime::Runtime, sync::Notify};
use windows::{
    core::{Interface, Result as WinResult, GUID},
    Win32::{
        Networking::NetworkListManager::{
            INetworkEvents, INetworkEvents_Impl, INetworkListManager, NetworkListManager,
            NLM_CONNECTIVITY, NLM_NETWORK_PROPERTY_CHANGE,
        },
        System::Com,
    },
};

pub(crate) use async_dns::CombinedListener as DnsListener;

#[derive(thiserror::Error, Debug)]
pub(crate) enum Error {
    #[error("Couldn't initialize COM: {0}")]
    ComInitialize(windows::core::Error),
    #[error("Couldn't stop worker thread")]
    CouldntStopWorkerThread,
    #[error("Couldn't creat NetworkListManager")]
    CreateNetworkListManager(windows::core::Error),
    #[error("Couldn't start listening to network events: {0}")]
    Listening(windows::core::Error),
    #[error("Couldn't stop listening to network events: {0}")]
    Unadvise(windows::core::Error),
}

/// Debug subcommand to test network connectivity events
pub(crate) fn run_debug() -> Result<()> {
    tracing_subscriber::fmt::init();

    // Returns Err before COM is initialized
    assert!(get_apartment_type().is_err());

    let com_worker = Worker::new()?;

    // We have to initialize COM again for the main thread. This doesn't
    // seem to be a problem in the main app since Tauri initializes COM for itself.
    let _guard = ComGuard::new();

    assert_eq!(
        get_apartment_type(),
        Ok((Com::APTTYPE_MTA, Com::APTTYPEQUALIFIER_NONE))
    );

    let rt = Runtime::new()?;

    tracing::info!("Listening for network events...");

    rt.block_on(async move {
        loop {
            com_worker.notified().await;
            // Make sure whatever Tokio thread we're on is associated with COM
            // somehow.
            assert_eq!(
                get_apartment_type()?,
                (Com::APTTYPE_MTA, Com::APTTYPEQUALIFIER_NONE)
            );

            tracing::info!(have_internet = %check_internet()?);
        }
    })
}

/// Runs a debug subcommand that listens to the registry for DNS changes
///
/// This actually listens to the entire IPv4 key, so it will have lots of false positives,
/// including when connlib changes anything on the Firezone tunnel.
/// It will often fire multiple events in quick succession.
pub(crate) fn run_dns_debug() -> Result<()> {
    async_dns::run_debug()
}

/// Returns true if Windows thinks we have Internet access per [IsConnectedToInternet](https://learn.microsoft.com/en-us/windows/win32/api/netlistmgr/nf-netlistmgr-inetworklistmanager-get_isconnectedtointernet)
///
/// Call this when `Listener` notifies you.
pub fn check_internet() -> Result<bool> {
    // Retrieving the INetworkListManager takes less than half a millisecond, and this
    // makes the lifetimes and Send+Sync much simpler for callers, so just retrieve it
    // every single time.
    // SAFETY: No lifetime problems. TODO: Could threading be a problem?
    // I think in practice we'll never call this from two threads, but what if we did?
    // Maybe make it a method on a `!Send + !Sync` guard struct?
    let network_list_manager: INetworkListManager =
        unsafe { Com::CoCreateInstance(&NetworkListManager, None, Com::CLSCTX_ALL) }?;
    // SAFETY: `network_list_manager` isn't shared between threads, and the lifetime
    // should be good.
    let have_internet = unsafe { network_list_manager.IsConnectedToInternet() }?.as_bool();

    Ok(have_internet)
}

/// Worker thread that can be joined explicitly, and joins on Drop
pub(crate) struct Worker {
    inner: Option<WorkerInner>,
    // I think this is `Arc` because of the worker thread, and we need the worker thread
    // because of COM. `Notify` only has `&self` methods so it does not need `Arc` in general.
    notify: Arc<Notify>,
}

/// Needed so that `Drop` can consume the oneshot Sender and the thread's JoinHandle
struct WorkerInner {
    thread: std::thread::JoinHandle<Result<(), Error>>,
    stopper: tokio::sync::oneshot::Sender<()>,
}

impl Worker {
    pub(crate) fn new() -> Result<Self> {
        let notify = Arc::new(Notify::new());

        let (stopper, rx) = tokio::sync::oneshot::channel();
        let thread = {
            let notify = Arc::clone(&notify);
            std::thread::Builder::new()
                .name("Firezone COM worker".into())
                .spawn(move || {
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

    /// Same as `drop`, but you can catch errors
    pub(crate) fn close(&mut self) -> Result<()> {
        if let Some(inner) = self.inner.take() {
            inner
                .stopper
                .send(())
                .map_err(|_| Error::CouldntStopWorkerThread)?;
            match inner.thread.join() {
                Err(e) => std::panic::resume_unwind(e),
                Ok(x) => x?,
            }
        }
        Ok(())
    }

    pub(crate) async fn notified(&self) {
        self.notify.notified().await;
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        self.close()
            .expect("should be able to close Worker cleanly");
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
    pub fn new() -> Result<Self, Error> {
        // SAFETY: Threading shouldn't be a problem since this is meant to initialize
        // COM per-thread anyway.
        unsafe { Com::CoInitializeEx(None, Com::COINIT_MULTITHREADED) }
            .ok()
            .map_err(Error::ComInitialize)?;
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
            tracing::debug!("Uninitialized COM");
        }
    }
}

/// Listens to network connectivity change eents
struct Listener<'a> {
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
    /// * `com` - Makes sure that CoInitializeEx was called. `com` have been created
    ///   on the same thread as `new` is called on.
    /// * `notify` - A Tokio `Notify` that will be notified when Windows detects
    ///   connectivity changes. Some notifications may be spurious.
    fn new(com: &'a ComGuard, notify: Arc<Notify>) -> Result<Self, Error> {
        // `windows-rs` automatically releases (de-refs) COM objects on Drop:
        // https://github.com/microsoft/windows-rs/issues/2123#issuecomment-1293194755
        // https://github.com/microsoft/windows-rs/blob/cefdabd15e4a7a7f71b7a2d8b12d5dc148c99adb/crates/samples/windows/wmi/src/main.rs#L22
        // SAFETY: TODO
        let network_list_manager: INetworkListManager =
            unsafe { Com::CoCreateInstance(&NetworkListManager, None, Com::CLSCTX_ALL) }
                .map_err(Error::CreateNetworkListManager)?;
        let cpc: Com::IConnectionPointContainer =
            network_list_manager.cast().map_err(Error::Listening)?;
        // SAFETY: TODO
        let cxn_point_net =
            unsafe { cpc.FindConnectionPoint(&INetworkEvents::IID) }.map_err(Error::Listening)?;

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
        this.advise_cookie_net =
            Some(unsafe { this.cxn_point_net.Advise(&callbacks) }.map_err(Error::Listening)?);

        // After we call `Advise`, notify. This should avoid a problem if this happens:
        //
        // 1. Caller spawns a worker thread for Listener, but the worker thread isn't scheduled
        // 2. Caller continues setup, checks Internet is connected
        // 3. Internet gets disconnected but caller isn't notified
        // 4. Worker thread finally gets scheduled, but we never notify that the Internet was lost during setup. Caller is now out of sync with ground truth.
        this.inner.notify.notify_one();

        Ok(this)
    }

    /// Like `drop`, but you can catch errors
    ///
    /// Unregisters the network change callbacks
    pub fn close(&mut self) -> Result<(), Error> {
        if let Some(cookie) = self.advise_cookie_net.take() {
            // SAFETY: I don't see any memory safety issues.
            unsafe { self.cxn_point_net.Unadvise(cookie) }.map_err(Error::Unadvise)?;
            tracing::debug!("Unadvised");
        }
        Ok(())
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

/// Checks what COM apartment the current thread is in. For debugging only.
fn get_apartment_type() -> WinResult<(Com::APTTYPE, Com::APTTYPEQUALIFIER)> {
    let mut apt_type = Com::APTTYPE_CURRENT;
    let mut apt_qualifier = Com::APTTYPEQUALIFIER_NONE;

    // SAFETY: We just created the variables, and they're out parameters,
    // so Windows shouldn't store the pointers.
    unsafe { Com::CoGetApartmentType(&mut apt_type, &mut apt_qualifier) }?;
    Ok((apt_type, apt_qualifier))
}

mod async_dns {
    use anyhow::{Context, Result};
    use std::{ffi::c_void, ops::Deref};
    use tokio::sync::Notify;
    use windows::Win32::{
        Foundation::{CloseHandle, BOOLEAN, HANDLE, INVALID_HANDLE_VALUE},
        System::Registry,
        System::Threading::{
            CreateEventA, RegisterWaitForSingleObject, UnregisterWaitEx, INFINITE,
            WT_EXECUTEINWAITTHREAD,
        },
    };
    use winreg::RegKey;

    /// Opens and returns the IPv4 and IPv6 registry keys
    ///
    /// `HKEY_LOCAL_MACHINE/SYSTEM/CurrentControlSet/Services/Tcpip[6]/Parameters/Interfaces`
    fn open_network_registry_keys() -> Result<(RegKey, RegKey)> {
        let hklm = winreg::RegKey::predef(winreg::enums::HKEY_LOCAL_MACHINE);
        let path_4 = std::path::Path::new("SYSTEM")
            .join("CurrentControlSet")
            .join("Services")
            .join("Tcpip")
            .join("Parameters")
            .join("Interfaces");
        let path_6 = std::path::Path::new("SYSTEM")
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

    pub(crate) fn run_debug() -> Result<()> {
        tracing_subscriber::fmt::init();
        let rt = tokio::runtime::Runtime::new()?;

        let mut listener = CombinedListener::new()?;

        rt.block_on(async move {
            loop {
                tokio::select! {
                    _r = tokio::signal::ctrl_c() => break,
                    r = listener.notified() => r?,
                }

                let resolvers = crate::client::resolvers::get()?;
                tracing::info!(?resolvers);
            }

            listener.close()?;
            Ok::<_, anyhow::Error>(())
        })?;

        Ok(())
    }

    pub(crate) struct CombinedListener {
        listener_4: Listener,
        listener_6: Listener,
    }

    impl CombinedListener {
        pub(crate) fn new() -> Result<Self> {
            let (key_ipv4, key_ipv6) = open_network_registry_keys()?;
            let listener_4 = Listener::new(key_ipv4)?;
            let listener_6 = Listener::new(key_ipv6)?;

            Ok(Self {
                listener_4,
                listener_6,
            })
        }

        pub(crate) fn close(&mut self) -> Result<()> {
            self.listener_4.close()?;
            self.listener_6.close()?;
            tracing::debug!("Unregistered registry listener");
            Ok(())
        }

        pub(crate) async fn notified(&mut self) -> Result<()> {
            tokio::select! {
                r = self.listener_4.notified() => r?,
                r = self.listener_6.notified() => r?,
            }
            Ok(())
        }
    }

    struct Listener {
        key: winreg::RegKey,
        notify: std::pin::Pin<Box<Notify>>,
        wait_handle: Option<HANDLE>,
        event: Option<HANDLE>,
    }

    impl Listener {
        pub(crate) fn new(key: winreg::RegKey) -> Result<Self> {
            let notify = Box::pin(Notify::default());
            let notify_ptr: *const Notify = notify.deref();
            let event = unsafe { CreateEventA(None, false, false, None) }?;
            let mut wait_handle = HANDLE(0isize);

            // The docs say that `RegisterWaitForSingleObject` uses "a worker thread" from
            // "the thread pool".
            // Raymond Chen, who is an authority on Windows internals, says RegisterWaitForSingleObject
            // does multiple waits on the same worker thread internally:
            // <https://devblogs.microsoft.com/oldnewthing/20081117-00/?p=20183>
            // There is a different function in the CLR called `RegisterWaitForSingleObject`,
            // so he might be talking about that.
            // If he's not, then we're invisibly tying up two worker threads. Can't help it.

            // SAFETY: It's complicated.
            // The callback here can cause a lot of problems. We pin the `Notify` object.
            // We don't use an `Arc` because `Notify` already has only `&self` methods, and
            // the callback has no way to free an `Arc`.
            // When we call `UnregisterWaitEx` later, we wait for all callbacks to finish running
            // before we drop the `Notify`, to avoid a dangling pointer.
            unsafe {
                RegisterWaitForSingleObject(
                    &mut wait_handle,
                    event,
                    Some(callback),
                    Some(notify_ptr as *const _),
                    INFINITE,
                    WT_EXECUTEINWAITTHREAD,
                )
            }?;

            let mut that = Self {
                key,
                notify,
                wait_handle: Some(wait_handle),
                event: Some(event),
            };
            that.register_callback()?;

            Ok(that)
        }

        pub(crate) fn close(&mut self) -> Result<()> {
            if let Some(wait_handle) = self.wait_handle.take() {
                unsafe { UnregisterWaitEx(wait_handle, INVALID_HANDLE_VALUE) }?;
            }
            if let Some(event) = self.event.take() {
                unsafe { CloseHandle(event) }?;
            }

            Ok(())
        }

        // I'm not sure if this needs to be mut, I'm being cautious here.
        // There is no reason in practice you'd ever want to call it from two
        // threads at once.
        //
        // Cancel-safety: Probably. `tokio::sync::Notify` sounds cancel-safe.
        pub(crate) async fn notified(&mut self) -> Result<()> {
            // Order matters here
            // We want to return to the caller and let them check the DNS
            // while the callback is registered.
            self.notify.notified().await;
            self.register_callback()
                .context("`register_callback` failed")?;

            Ok(())
        }

        // Be careful with this, if you register twice before the callback fires,
        // it will probably leak something. Check the MS docs for `RegNotifyChangeKeyValue`.
        fn register_callback(&mut self) -> Result<()> {
            let event = self.event.context(
                "Can't call `register_callback` on a `Listener` that's already been closed",
            )?;
            let key_handle = Registry::HKEY(self.key.raw_handle());
            let notify_flags =
                Registry::REG_NOTIFY_CHANGE_NAME | Registry::REG_NOTIFY_CHANGE_LAST_SET;
            unsafe {
                Registry::RegNotifyChangeKeyValue(key_handle, true, notify_flags, event, true)
            }
            .ok()
            .context("`RegNotifyChangeKeyValue` failed")?;
            Ok(())
        }
    }

    impl Drop for Listener {
        fn drop(&mut self) {
            self.close()
                .expect("Should be able to drop DNS change listener");
        }
    }

    // SAFETY: The waker should be alive, because we only `Drop` it after waiting
    // for any run of this callback to finish.
    // This function runs on a worker thread in a Windows-managed thread pool where
    // many API calls are illegal, so try not to do anything in here. Right now
    // all we do is wake up our Tokio task.
    unsafe extern "system" fn callback(ctx: *mut c_void, _: BOOLEAN) {
        let notify = &*(ctx as *const tokio::sync::Notify);
        notify.notify_one();
    }
}
