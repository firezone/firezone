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
        System::Com::{
            CoCreateInstance, CoInitializeEx, CoUninitialize, IConnectionPoint,
            IConnectionPointContainer, CLSCTX_ALL, COINIT_MULTITHREADED,
        },
    },
};

pub fn run_debug() -> Result<()> {
    tracing_subscriber::fmt::init();
    // Must be called for each thread that will do COM stuff
    unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }?;

    {
        let rt = Runtime::new().unwrap();

        let listener = Listener::new()?;
        println!("Listening for network events...");

        rt.block_on(async move {
            // If I used `loop` then Clippy would complain that `Ok(())` is unreachable
            // TODO: More idiomatic way to write that?
            for _ in 0.. {
                println!("check_internet() = {}", listener.check_internet()?);
                listener.notified().await;
            }
            Ok::<_, anyhow::Error>(())
        })?;
    }

    unsafe {
        // Required, per CoInitializeEx docs
        // Safety: Make sure all the COM objects are dropped before we call
        // CoUninitialize or the program might segfault.
        CoUninitialize();
    }
    Ok(())
}

pub(crate) struct Listener {
    /// The cookies we get back from `Advise`. Can be None if the owner called `close`
    ///
    /// This has to be mutable because we have to hook up the callbacks during
    /// Listener's constructor
    advise_cookie_net: Option<u32>,
    cxn_point_net: IConnectionPoint,
    network_list_manager: INetworkListManager,

    inner: ListenerInner,
}

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
    /// Pre-req: CoInitializeEx must have been called on the calling thread to
    /// initialize COM.
    pub fn new() -> Result<Self> {
        // `windows-rs` automatically releases (de-refs) COM objects on Drop:
        // https://github.com/microsoft/windows-rs/issues/2123#issuecomment-1293194755
        // https://github.com/microsoft/windows-rs/blob/cefdabd15e4a7a7f71b7a2d8b12d5dc148c99adb/crates/samples/windows/wmi/src/main.rs#L22
        let network_list_manager: INetworkListManager =
            unsafe { CoCreateInstance(&NetworkListManager, None, CLSCTX_ALL) }?;
        let cpc: IConnectionPointContainer = network_list_manager.cast()?;
        let cxn_point_net = unsafe { cpc.FindConnectionPoint(&INetworkEvents::IID) }?;

        let mut this = Listener {
            advise_cookie_net: None,
            cxn_point_net,
            network_list_manager,
            inner: ListenerInner {
                notify: Arc::new(Notify::new()),
            },
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
    pub fn close(&mut self) -> anyhow::Result<()> {
        if let Some(cookie) = self.advise_cookie_net.take() {
            // SAFETY: I don't see any memory safety issues.
            unsafe { self.cxn_point_net.Unadvise(cookie) }?;
            tracing::debug!("Unadvised");
        }
        Ok(())
    }

    pub fn check_internet(&self) -> WinResult<bool> {
        Ok(unsafe { self.network_list_manager.IsConnectedToInternet() }?.as_bool())
    }

    pub async fn notified(&self) {
        self.inner.notify.notified().await
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
