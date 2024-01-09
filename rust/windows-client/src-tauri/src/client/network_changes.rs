use windows::{
    core::{ComInterface, Result as WinResult, GUID},
    Win32::{
        Networking::NetworkListManager::{
            INetworkEvents, INetworkEvents_Impl, INetworkListManager, NetworkListManager,
            NLM_CONNECTIVITY, NLM_NETWORK_PROPERTY_CHANGE,
        },
        System::Com::{CoCreateInstance, IConnectionPoint, IConnectionPointContainer, CLSCTX_ALL},
    },
};

pub(crate) struct Listener {
    /// The cookie we get back from `Advise`. Can be None if the owner called `close`
    advise_cookie: Option<u32>,
    /// An IConnectionPoint is where we register our CallbackHandler
    cxn_point: IConnectionPoint,
}

impl Drop for Listener {
    fn drop(&mut self) {
        self.close().unwrap();
    }
}

impl Listener {
    /// Pre-req: CoInitializeEx must have been called on the calling thread to
    /// initialize COM.
    pub fn new() -> anyhow::Result<Self> {
        // `windows-rs` automatically releases (de-refs) COM objects on Drop:
        // https://github.com/microsoft/windows-rs/issues/2123#issuecomment-1293194755
        // https://github.com/microsoft/windows-rs/blob/cefdabd15e4a7a7f71b7a2d8b12d5dc148c99adb/crates/samples/windows/wmi/src/main.rs#L22
        let network_list_manager: INetworkListManager =
            unsafe { CoCreateInstance(&NetworkListManager, None, CLSCTX_ALL) }?;
        let cpc: IConnectionPointContainer = network_list_manager.cast()?;
        let cxn_point = unsafe { cpc.FindConnectionPoint(&INetworkEvents::IID) }?;
        let listener: INetworkEvents = CallbackHandler {}.into();
        // TODO: Make sure to call Unadvise later to avoid leaks
        let advise_cookie = Some(unsafe { cxn_point.Advise(&listener) }?);

        Ok(Self {
            advise_cookie,
            cxn_point,
        })
    }

    /// This is the same as Drop, but you can catch errors from it
    /// Calling this multiple times is idempotent
    fn close(&mut self) -> anyhow::Result<()> {
        if let Some(advise_cookie) = self.advise_cookie.take() {
            // SAFETY: I don't see any memory safety issues.
            unsafe { self.cxn_point.Unadvise(advise_cookie) }?;
            tracing::debug!("Unadvised");
        }
        Ok(())
    }
}

// https://kennykerr.ca/rust-getting-started/how-to-implement-com-interface.html
#[windows_implement::implement(INetworkEvents)]
struct CallbackHandler {}
impl INetworkEvents_Impl for CallbackHandler {
    fn NetworkAdded(&self, networkid: &GUID) -> WinResult<()> {
        // TODO: Send these events over a Tokio mpsc channel if we need them in the GUI
        println!("NetworkAdded {networkid:?}");
        Ok(())
    }

    fn NetworkDeleted(&self, networkid: &GUID) -> WinResult<()> {
        println!("NetworkDeleted {networkid:?}");
        Ok(())
    }

    fn NetworkConnectivityChanged(
        &self,
        networkid: &GUID,
        newconnectivity: NLM_CONNECTIVITY,
    ) -> WinResult<()> {
        println!("NetworkConnectivityChanged {networkid:?} {newconnectivity:?}");
        Ok(())
    }

    fn NetworkPropertyChanged(
        &self,
        networkid: &GUID,
        flags: NLM_NETWORK_PROPERTY_CHANGE,
    ) -> WinResult<()> {
        println!("NetworkPropertyChanged {networkid:?} {flags:?}");
        Ok(())
    }
}
