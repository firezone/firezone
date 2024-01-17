//! A module for getting callbacks from Windows when we gain / lose Internet connectivity
//!
//! # Example
//!
//! ```rust
//! use crate::network_changes::Listener;
//!
//! unsafe { Com::CoInitializeEx(None, Com::COINIT_MULTITHREADED) }?;
//!
//! let notify = Arc::new(Notify::new());
//! let _listener = Listener::new(notify)?;
//!
//! loop {
//!     dbg!(Listener::check_internet()?);
//!     notify.notified().await;
//! }
//!
//! // Safety: Make sure all the COM objects are dropped before we call
//! // CoUninitialize or the program might segfault.
//! unsafe { Com::CoUninitialize() };
//! ```
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

use anyhow::Result;
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
pub(crate) fn run_debug() -> Result<()> {
    tracing_subscriber::fmt::init();

    // Returns Err before COM is initialized
    assert!(get_apartment_type().is_err());

    // Initialize a "Multi-threaded apartment" so that Windows COM stuff
    // can be called, and COM callbacks can work.
    unsafe { Com::CoInitializeEx(None, Com::COINIT_MULTITHREADED) }?;

    // We just initialized COM on the main thread, so we should be in an MTA
    assert_eq!(
        get_apartment_type()?,
        (Com::APTTYPE_MTA, Com::APTTYPEQUALIFIER_NONE)
    );

    {
        let rt = Runtime::new().unwrap();

        let notify = Arc::new(Notify::new());
        let _listener = Listener::new(Arc::clone(&notify))?;
        println!("Listening for network events...");

        rt.block_on(async move {
            // If I used `loop` then Clippy would complain that `Ok(())` is unreachable
            // TODO: More idiomatic way to write that?
            for _ in 0.. {
                // Make sure whatever Tokio thread we're on is associated with COM
                // somehow.
                assert_eq!(
                    get_apartment_type()?,
                    (Com::APTTYPE_MTA, Com::APTTYPEQUALIFIER_NONE)
                );

                println!("check_internet() = {}", Listener::check_internet()?);
                notify.notified().await;
            }
            Ok::<_, anyhow::Error>(())
        })?;
    }

    // Required, per [CoInitializeEx docs](https://learn.microsoft.com/en-us/windows/win32/api/combaseapi/nf-combaseapi-coinitializeex#remarks)
    // Safety: Make sure all the COM objects are dropped before we call
    // CoUninitialize or the program might segfault.
    unsafe { Com::CoUninitialize() };
    Ok(())
}

/// Checks what COM apartment the current thread is in. For debugging only.
fn get_apartment_type() -> Result<(Com::APTTYPE, Com::APTTYPEQUALIFIER)> {
    let mut apt_type = Com::APTTYPE_CURRENT;
    let mut apt_qualifier = Com::APTTYPEQUALIFIER_NONE;

    // SAFETY: We just created the variables, and they're out parameters,
    // so Windows shouldn't store the pointers.
    unsafe { Com::CoGetApartmentType(&mut apt_type, &mut apt_qualifier) }?;
    Ok((apt_type, apt_qualifier))
}

/// Listens to network connectivity change eents
pub(crate) struct Listener {
    /// The cookies we get back from `Advise`. Can be None if the owner called `close`
    ///
    /// This has to be mutable because we have to hook up the callbacks during
    /// Listener's constructor
    advise_cookie_net: Option<u32>,
    cxn_point_net: Com::IConnectionPoint,

    inner: ListenerInner,
}

/// This must be separate because we need to `Clone` that `Notify` and we can't
/// `Clone` the COM objects in `Listener`
// https://kennykerr.ca/rust-getting-started/how-to-implement-com-interface.html
#[windows_implement::implement(INetworkEvents)]
#[derive(Clone)]
struct ListenerInner {
    notify: Arc<Notify>,
}

impl Drop for Listener {
    fn drop(&mut self) {
        self.close().unwrap();
    }
}

impl Drop for ListenerInner {
    fn drop(&mut self) {
        tracing::debug!("Dropped ListenerInner");
    }
}

impl Listener {
    /// Creates a new Listener
    ///
    /// Pre-req: CoInitializeEx must have been called on the calling thread
    /// with COINIT_MULTITHREADED to set up multi-threaded COM.
    ///
    /// # Arguments
    ///
    /// * `notify` - A Tokio `Notify` that will be notified when Windows detects
    ///   connectivity changes. Some notifications may be spurious.
    pub fn new(notify: Arc<Notify>) -> Result<Self> {
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
        };

        let callbacks: INetworkEvents = this.inner.clone().into();

        // SAFETY: What happens if Windows sends us a network change event while
        // we're dropping Listener?
        // Is it safe to Advise on `this` and then immediately move it?
        this.advise_cookie_net = Some(unsafe { this.cxn_point_net.Advise(&callbacks) }?);

        Ok(this)
    }

    /// This is the same as Drop, but you can catch errors from it
    /// Calling this multiple times is idempotent
    ///
    /// Unregisters the network change callbacks
    pub fn close(&mut self) -> anyhow::Result<()> {
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
