use anyhow::{Context, Result};
use arc_swap::ArcSwap;
use connlib_client_shared::{file_logger, ResourceDescription};
use firezone_headless_client::IpcClientMsg;
use futures::SinkExt;
use secrecy::{ExposeSecret, SecretString};
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    sync::Arc,
};
use tokio::{net::UnixStream, sync::Notify};
use tokio_util::codec::LengthDelimitedCodec;

use super::ControllerRequest;
use super::CtlrTx;

type IpcStream = tokio_util::codec::Framed<UnixStream, LengthDelimitedCodec>;

// TODO: DRY
const SOCK_PATH: &str = "/run/firezone-client.sock";

#[derive(Clone)]
pub(crate) struct CallbackHandler {
    pub _logger: file_logger::Handle,
    pub notify_controller: Arc<Notify>,
    pub ctlr_tx: CtlrTx,
    pub resources: Arc<ArcSwap<Vec<ResourceDescription>>>,
}

/// Forwards events to and from connlib
pub(crate) struct TunnelWrapper {
    // TODO: IPC client
    stream: IpcStream,
}

impl TunnelWrapper {
    pub(crate) async fn disconnect(self) -> Result<()> {
        // TODO: Send IPC message, close gracefully
        todo!()
    }

    pub(crate) async fn reconnect(&mut self) -> Result<()> {
        self.send_msg(&IpcClientMsg::Reconnect)
            .await
            .context("Couldn't send Reconnect")?;
        Ok(())
    }

    pub(crate) async fn set_dns(&mut self, dns: Vec<IpAddr>) -> Result<()> {
        self.send_msg(&IpcClientMsg::SetDns(dns))
            .await
            .context("Couldn't send SetDns")?;
        Ok(())
    }

    async fn send_msg(&mut self, msg: &IpcClientMsg) -> Result<()> {
        self.stream
            .send(
                serde_json::to_string(msg)
                    .context("Couldn't encode IPC message as JSON")?
                    .into(),
            )
            .await
            .context("Couldn't send IPC message")?;
        Ok(())
    }
}

pub async fn connect(
    api_url: &str,
    token: SecretString,
    callback_handler: CallbackHandler,
    _tokio_handle: tokio::runtime::Handle, // Needed in `in_proc`
) -> Result<TunnelWrapper> {
    // TODO: Connect to the IPC service, send over the API URL and token
    tracing::info!(pid = std::process::id(), "Connecting to IPC service...");
    let stream = UnixStream::connect(SOCK_PATH)
        .await
        .context("Couldn't connect to UDS")?;
    let stream = IpcStream::new(stream, LengthDelimitedCodec::new());
    let mut client = TunnelWrapper { stream };
    let token = token.expose_secret().clone();
    client
        .send_msg(&IpcClientMsg::Connect {
            api_url: api_url.to_string(),
            token,
        })
        .await
        .context("Couldn't send Connect message")?;

    Ok(client)
}

// Callbacks must all be non-blocking
// TODO: DRY
impl connlib_client_shared::Callbacks for CallbackHandler {
    fn on_disconnect(&self, error: &connlib_client_shared::Error) {
        tracing::debug!("on_disconnect {error:?}");
        self.ctlr_tx
            .try_send(ControllerRequest::Disconnected)
            .expect("controller channel failed");
    }

    fn on_set_interface_config(&self, _: Ipv4Addr, _: Ipv6Addr, _: Vec<IpAddr>) -> Option<i32> {
        tracing::info!("on_set_interface_config");
        self.ctlr_tx
            .try_send(ControllerRequest::TunnelReady)
            .expect("controller channel failed");
        None
    }

    fn on_update_resources(&self, resources: Vec<ResourceDescription>) {
        tracing::debug!("on_update_resources");
        self.resources.store(resources.into());
        self.notify_controller.notify_one();
    }
}
