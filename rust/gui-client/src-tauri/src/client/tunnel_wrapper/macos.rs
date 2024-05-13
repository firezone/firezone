use anyhow::Result;
use firezone_headless_client::IpcClientMsg;
use secrecy::SecretString;

pub(crate) struct TunnelWrapper {}

impl TunnelWrapper {
    #[allow(clippy::unused_async)]
    pub(crate) async fn disconnect(self) -> Result<()> {
        unimplemented!()
    }

    #[allow(clippy::unused_async)]
    pub(crate) async fn send_msg(&mut self, _msg: &IpcClientMsg) -> Result<()> {
        unimplemented!()
    }
}

pub(crate) async fn connect(
    _api_url: &str,
    _token: SecretString,
    _callback_handler: super::CallbackHandler,
    _tokio_handle: tokio::runtime::Handle,
) -> Result<TunnelWrapper> {
    unimplemented!()
}
