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
use std::net::IpAddr;
use tokio::{runtime::Runtime, sync::mpsc};
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

    let mut com_worker = Worker::new()?;

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
            tokio::select! {
                _r = tokio::signal::ctrl_c() => break,
                () = com_worker.notified() => {},
            };
            // Make sure whatever Tokio thread we're on is associated with COM
            // somehow.
            assert_eq!(
                get_apartment_type()?,
                (Com::APTTYPE_MTA, Com::APTTYPEQUALIFIER_NONE)
            );

            tracing::info!(have_internet = %check_internet()?);
        }
        Ok::<_, anyhow::Error>(())
    })?;

    Ok(())
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
    rx: mpsc::Receiver<()>,
}

/// Needed so that `Drop` can consume the oneshot Sender and the thread's JoinHandle
struct WorkerInner {
    thread: std::thread::JoinHandle<Result<(), Error>>,
    stopper: tokio::sync::oneshot::Sender<()>,
}

impl Worker {
    pub(crate) fn new() -> Result<Self> {
        let (tx, rx) = mpsc::channel(1);

        let (stopper, stopper_rx) = tokio::sync::oneshot::channel();
        let thread = {
            std::thread::Builder::new()
                .name("Firezone COM worker".into())
                .spawn(move || {
                    {
                        let com = ComGuard::new()?;
                        let _network_change_listener = Listener::new(&com, tx)?;
                        stopper_rx.blocking_recv().ok();
                    }
                    tracing::debug!("COM worker thread shut down gracefully");
                    Ok(())
                })?
        };

        Ok(Self {
            inner: Some(WorkerInner { thread, stopper }),
            rx,
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

    pub(crate) async fn notified(&mut self) {
        self.rx.recv().await;
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

    /// Hold a reference to a `ComGuard` to enforce the right init-use-uninit order
    _com: &'a ComGuard,
}

// https://kennykerr.ca/rust-getting-started/how-to-implement-com-interface.html
#[windows_implement::implement(INetworkEvents)]
struct Callback {
    tx: mpsc::Sender<()>,
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
    /// * `tx` - A Sender to notify when Windows detects
    ///   connectivity changes. Some notifications may be spurious.
    fn new(com: &'a ComGuard, tx: mpsc::Sender<()>) -> Result<Self, Error> {
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
            _com: com,
        };

        let cb = Callback { tx: tx.clone() };

        let callbacks: INetworkEvents = cb.into();

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
        tx.try_send(()).ok();

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

impl INetworkEvents_Impl for Callback {
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
        // Use `try_send` because we're only sending a notification to wake up the receiver.
        self.tx.try_send(()).ok();
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
        tracing::debug!("Dropped `network_changes::Callback`");
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
    use std::{ffi::c_void, ops::Deref, path::Path};
    use tokio::sync::mpsc;
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

        pub(crate) async fn notified(&mut self) -> Result<()> {
            tokio::select! {
                r = self.listener_4.notified() => r?,
                r = self.listener_6.notified() => r?,
            }
            Ok(())
        }
    }

    /// Listens to one registry key for changes. Callers should await `notified`.
    struct Listener {
        key: winreg::RegKey,
        // Rust never uses `tx` again, but the C callback borrows it. So it must live as long
        // as Listener, and then be dropped after the C callback is cancelled and any
        // ongoing callback finishes running.
        //
        // We box it here to avoid this sequence:
        // - `Listener::new` called, pointer to `tx` passed to `RegisterWaitForSingleObject`
        // - `Listener` and `tx` move
        // - The callback fires, using the now-invalid previous location of `tx`
        //
        // So don't ever do `self._tx = $ANYTHING` after `new`, it'll break the callback.
        _tx: Box<mpsc::Sender<()>>,
        rx: mpsc::Receiver<()>,
        /// A handle representing our registered callback from `RegisterWaitForSingleObject`
        ///
        /// This doesn't get signalled, it's just used so we can unregister and stop the
        /// callbacks gracefully when dropping the `Listener`.
        wait_handle: HANDLE,
        /// An event that's 'signalled' when the registry key changes
        ///
        /// `RegNotifyChangeKeyValue` can't call a callback directly, so it signals this
        /// event, and we use `RegisterWaitForSingleObject` to adapt that signal into
        /// a C callback.
        event: HANDLE,
    }

    impl Listener {
        pub(crate) fn new(key: winreg::RegKey) -> Result<Self> {
            let (tx, rx) = mpsc::channel(1);
            let tx = Box::new(tx);
            let tx_ptr: *const _ = tx.deref();
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
            // The callback here can cause a lot of problems. We box the `Sender` object
            // so its memory address won't change.
            // We don't use an `Arc` because sending is already `&self`, and
            // the callback has no way to free an `Arc`, since we will always cancel the callback
            // before it fires when the `Listener` drops.
            // When we call `UnregisterWaitEx` later, we wait for all callbacks to finish running
            // before we drop everything, to prevent the callback from seeing a dangling pointer.
            unsafe {
                RegisterWaitForSingleObject(
                    &mut wait_handle,
                    event,
                    Some(callback),
                    Some(tx_ptr as *const _),
                    INFINITE,
                    WT_EXECUTEINWAITTHREAD,
                )
            }?;

            let mut that = Self {
                key,
                _tx: tx,
                rx,
                wait_handle,
                event,
            };
            that.register_callback()?;

            Ok(that)
        }

        /// Returns when the registry key has changed
        ///
        /// This is `&mut self` because calling `register_callback` twice
        /// before the callback fires would cause a resource leak.
        /// Cancel-safety: Yes. <https://docs.rs/tokio/latest/tokio/macro.select.html#cancellation-safety>
        pub(crate) async fn notified(&mut self) -> Result<Vec<IpAddr>> {
            // We use a particular order here because I initially assumed
            // `RegNotifyChangeKeyValue` has a gap in this sequence:
            // - RegNotifyChangeKeyValue
            // - (Value changes)
            // - (We catch the notification and read the DNS)
            // - (Value changes again)
            // - RegNotifyChangeKeyValue
            // - (The second change is dropped)
            //
            // But Windows seems to actually do some magic so that the 2nd
            // call of `RegNotifyChangeKeyValue` signals immediately, even though there
            // was no registered notification when the value changed.
            // See the unit test below.
            //
            // This code is ordered to protect against such a gap, by returning to the
            // caller only when we are registered, but it's redundant.
            self.rx.recv().await.context("`Listener` is closing down")?;
            self.register_callback()
                .context("`register_callback` failed")?;

            Ok(crate::client::resolvers::get().unwrap_or_default())
        }

        // Be careful with this, if you register twice before the callback fires,
        // it will leak some resource.
        // <https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regnotifychangekeyvalue#remarks>
        //
        // > Each time a process calls RegNotifyChangeKeyValue with the same set of parameters, it establishes another wait operation, creating a resource leak. Therefore, check that you are not calling RegNotifyChangeKeyValue with the same parameters until the previous wait operation has completed.
        fn register_callback(&mut self) -> Result<()> {
            let key_handle = Registry::HKEY(self.key.raw_handle());
            let notify_flags = Registry::REG_NOTIFY_CHANGE_NAME
                | Registry::REG_NOTIFY_CHANGE_LAST_SET
                | Registry::REG_NOTIFY_THREAD_AGNOSTIC;
            // Ask Windows to signal our event once when anything inside this key changes.
            // We can't ask for repeated signals.
            unsafe {
                Registry::RegNotifyChangeKeyValue(key_handle, true, notify_flags, self.event, true)
            }
            .ok()
            .context("`RegNotifyChangeKeyValue` failed")?;
            Ok(())
        }
    }

    impl Drop for Listener {
        fn drop(&mut self) {
            unsafe { UnregisterWaitEx(self.wait_handle, INVALID_HANDLE_VALUE) }
                .expect("Should be able to `UnregisterWaitEx` in the DNS change listener");
            unsafe { CloseHandle(self.event) }
                .expect("Should be able to `CloseHandle` in the DNS change listener");
            tracing::debug!("Gracefully closed DNS change listener");
        }
    }

    // SAFETY: The `Sender` should be alive, because we only `Drop` it after waiting
    // for any run of this callback to finish.
    // This function runs on a worker thread in a Windows-managed thread pool where
    // many API calls are illegal, so try not to do anything in here. Right now
    // all we do is wake up our Tokio task.
    unsafe extern "system" fn callback(ctx: *mut c_void, _: BOOLEAN) {
        let tx = &*(ctx as *const mpsc::Sender<()>);
        // It's not a problem if sending fails. It either means the `Listener`
        // is closing down, or it's already been notified.
        tx.try_send(()).ok();
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use windows::Win32::{
            Foundation::WAIT_OBJECT_0,
            System::Threading::{ResetEvent, WaitForSingleObject},
        };

        fn event_is_signaled(event: HANDLE) -> bool {
            unsafe { WaitForSingleObject(event, 0) == WAIT_OBJECT_0 }
        }

        fn reg_notify(key: &winreg::RegKey, event: HANDLE) {
            assert!(!event_is_signaled(event));
            let notify_flags = Registry::REG_NOTIFY_CHANGE_NAME
                | Registry::REG_NOTIFY_CHANGE_LAST_SET
                | Registry::REG_NOTIFY_THREAD_AGNOSTIC;
            let key_handle = Registry::HKEY(key.raw_handle());
            unsafe {
                Registry::RegNotifyChangeKeyValue(key_handle, true, notify_flags, event, true)
            }
            .ok()
            .expect("`RegNotifyChangeKeyValue` failed");
        }

        fn set_reg_value(key: &winreg::RegKey, val: u32) {
            key.set_value("some_key", &val)
                .expect("setting registry value `{val}` failed");
        }

        fn reset_event(event: HANDLE) {
            unsafe { ResetEvent(event) }.expect("`ResetEvent` failed");
            assert!(!event_is_signaled(event));
        }

        #[test]
        fn registry() {
            let flags = winreg::enums::KEY_NOTIFY | winreg::enums::KEY_WRITE;
            let key_path = Path::new("Software")
                .join("dev.firezone.client")
                .join("test_CZD3JHFS");
            let (key, _disposition) = winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER)
                .create_subkey_with_flags(&key_path, flags)
                .expect("`open_subkey_with_flags` failed");

            let event =
                unsafe { CreateEventA(None, false, false, None) }.expect("`CreateEventA` failed");

            // Registering the notify alone does not signal the event
            reg_notify(&key, event);
            assert!(!event_is_signaled(event));

            // Setting the value after we've registered does
            set_reg_value(&key, 0);
            assert!(event_is_signaled(event));

            // Do that one more time to prove it wasn't a fluke
            reset_event(event);
            reg_notify(&key, event);
            assert!(!event_is_signaled(event));

            set_reg_value(&key, 500);
            assert!(event_is_signaled(event));

            // I thought there was a gap here, but there's actually not -
            // If we get the notification, then the value changes, then we re-register,
            // we immediately get notified again. I'm not sure how Windows does this.
            // Maybe it's storing the state with our regkey handle instead of with the
            // wait operation. This is convenient but it's confusing since the docs don't
            // make it clear. I'll leave the workaround in the main code.
            reset_event(event);
            set_reg_value(&key, 1000);
            assert!(!event_is_signaled(event));
            reg_notify(&key, event);
            // This is the part I was wrong about
            assert!(event_is_signaled(event));

            // Signal normally one more time
            reset_event(event);
            reg_notify(&key, event);
            set_reg_value(&key, 2000);
            assert!(event_is_signaled(event));

            // Close the handle before the notification goes off
            reset_event(event);
            reg_notify(&key, event);
            unsafe { CloseHandle(event) }.expect("`CloseHandle` failed");
            let _ = event;

            // Setting the value shouldn't break anything or crash here.
            set_reg_value(&key, 3000);

            winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER)
                .delete_subkey_all(&key_path)
                .expect("Should be able to delete test key");
        }
    }
}
