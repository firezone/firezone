use windows::{
    core::{ComInterface, Result as WinResult},
    Win32::{
        Networking::NetworkListManager::{
            INetworkListManager, INetworkListManagerEvents, INetworkListManagerEvents_Impl,
            NetworkListManager, NLM_CONNECTIVITY,
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
        let cxn_point = unsafe { cpc.FindConnectionPoint(&INetworkListManagerEvents::IID) }?;
        let listener: INetworkListManagerEvents = CallbackHandler {}.into();
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
#[windows_implement::implement(INetworkListManagerEvents)]
struct CallbackHandler {}
impl INetworkListManagerEvents_Impl for CallbackHandler {
    fn ConnectivityChanged(&self, newconnectivity: NLM_CONNECTIVITY) -> WinResult<()> {
        // TODO: Send this over a Tokio mpsc channel or something.
        dbg!(newconnectivity);
        Ok(())
    }
}
