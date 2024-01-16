use windows::{
    core::{ComInterface, Result as WinResult, GUID},
    Win32::{
        Networking::NetworkListManager::{
            INetworkConnectionEvents, INetworkConnectionEvents_Impl, INetworkEvents,
            INetworkEvents_Impl, INetworkListManager, NetworkListManager,
            NLM_CONNECTION_PROPERTY_CHANGE, NLM_CONNECTIVITY, NLM_NETWORK_PROPERTY_CHANGE,
        },
        System::Com::{CoCreateInstance, IConnectionPoint, IConnectionPointContainer, CLSCTX_ALL},
    },
};

pub(crate) struct Listener {
    /// The cookie we get back from `Advise`. Can be None if the owner called `close`
    advise_cookie_1: Option<u32>,
    advise_cookie_2: Option<u32>,
    /// An IConnectionPoint is where we register our CallbackHandler
    cxn_point_1: IConnectionPoint,
    cxn_point_2: IConnectionPoint,
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

        let listener: INetworkEvents = CallbackHandler {
            network_list_manager,
        }
        .into();
        // TODO: Make sure to call Unadvise later to avoid leaks
        let cxn_point_1 = unsafe { cpc.FindConnectionPoint(&INetworkEvents::IID) }?;
        let advise_cookie_1 = Some(unsafe { cxn_point_1.Advise(&listener) }?);
        let cxn_point_2 = unsafe { cpc.FindConnectionPoint(&INetworkConnectionEvents::IID) }?;
        let advise_cookie_2 = Some(unsafe { cxn_point_2.Advise(&listener) }?);

        Ok(Self {
            advise_cookie_1,
            advise_cookie_2,
            cxn_point_1,
            cxn_point_2,
        })
    }

    /// This is the same as Drop, but you can catch errors from it
    /// Calling this multiple times is idempotent
    fn close(&mut self) -> anyhow::Result<()> {
        if let Some(advise_cookie) = self.advise_cookie_1.take() {
            // SAFETY: I don't see any memory safety issues.
            unsafe { self.cxn_point_1.Unadvise(advise_cookie) }?;
            tracing::debug!("Unadvised");
        }
        if let Some(advise_cookie) = self.advise_cookie_2.take() {
            // SAFETY: I don't see any memory safety issues.
            unsafe { self.cxn_point_2.Unadvise(advise_cookie) }?;
            tracing::debug!("Unadvised");
        }
        Ok(())
    }
}

// https://kennykerr.ca/rust-getting-started/how-to-implement-com-interface.html
#[windows_implement::implement(INetworkConnectionEvents, INetworkEvents)]
struct CallbackHandler {
    network_list_manager: INetworkListManager,
}

impl CallbackHandler {
    fn get_network_name(&self, id: GUID) -> WinResult<String> {
        let net = unsafe { self.network_list_manager.GetNetwork(id) }?;
        unsafe { net.GetName() }.map(|s| s.to_string())
    }
}

impl INetworkConnectionEvents_Impl for CallbackHandler {
    fn NetworkConnectionConnectivityChanged(
        &self,
        connectionid: &GUID,
        newconnectivity: NLM_CONNECTIVITY,
    ) -> WinResult<()> {
        let cxn = unsafe {
            self.network_list_manager
                .GetNetworkConnection(*connectionid)
        }?;
        let net = unsafe { cxn.GetNetwork() }?;
        let net_name = unsafe { net.GetName() }?;
        println!("CxnConnectivityChanged {net_name} {connectionid:?} {newconnectivity:?}");
        Ok(())
    }

    fn NetworkConnectionPropertyChanged(
        &self,
        connectionid: &GUID,
        flags: NLM_CONNECTION_PROPERTY_CHANGE,
    ) -> WinResult<()> {
        println!("CxnPropertyChanged {connectionid:?} {flags:?}");
        Ok(())
    }
}

impl INetworkEvents_Impl for CallbackHandler {
    fn NetworkAdded(&self, networkid: &GUID) -> WinResult<()> {
        // TODO: Send these events over a Tokio mpsc channel if we need them in the GUI
        println!(
            "NetAdded {} {networkid:?}",
            self.get_network_name(*networkid)?
        );
        Ok(())
    }

    fn NetworkDeleted(&self, networkid: &GUID) -> WinResult<()> {
        println!(
            "NetDeleted {} {networkid:?}",
            self.get_network_name(*networkid)?
        );
        Ok(())
    }

    fn NetworkConnectivityChanged(
        &self,
        networkid: &GUID,
        newconnectivity: NLM_CONNECTIVITY,
    ) -> WinResult<()> {
        println!(
            "NetConnectivityChanged {} {networkid:?} {newconnectivity:?}",
            self.get_network_name(*networkid)?
        );
        Ok(())
    }

    fn NetworkPropertyChanged(
        &self,
        networkid: &GUID,
        flags: NLM_NETWORK_PROPERTY_CHANGE,
    ) -> WinResult<()> {
        let net = unsafe { self.network_list_manager.GetNetwork(*networkid) }?;
        let net_name = unsafe { net.GetName() }?;
        println!("NetPropertyChanged {net_name} {networkid:?} {flags:?}");

        let cxns_enum = unsafe { net.GetNetworkConnections() }?;
        let mut cxns = vec![None; 32];

        // Safety: `Next` should really be mut, shouldn't it?
        unsafe { cxns_enum.Next(&mut cxns[..], None) }?;

        for cxn in cxns.into_iter().flatten() {
            let id = unsafe { cxn.GetConnectionId() }?;
            println!("  Cxn {id:?}");
        }

        Ok(())
    }
}
