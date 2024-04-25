use anyhow::{Context, Result};
use arc_swap::ArcSwap;
use connlib_client_shared::{file_logger, Callbacks, ResourceDescription};
use firezone_headless_client::{imp::SOCK_PATH, IpcClientMsg, IpcServerMsg};
use futures::{SinkExt, StreamExt};
use secrecy::{ExposeSecret, SecretString};
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    sync::Arc,
};
use tokio::{
    net::{unix::OwnedWriteHalf, UnixStream},
    sync::Notify,
};
use tokio_util::codec::{FramedRead, FramedWrite, LengthDelimitedCodec};

use super::ControllerRequest;
use super::CtlrTx;

#[derive(Clone)]
pub(crate) struct CallbackHandler {
    pub _logger: file_logger::Handle,
    pub notify_controller: Arc<Notify>,
    pub ctlr_tx: CtlrTx,
    pub resources: Arc<ArcSwap<Vec<ResourceDescription>>>,
}

/// Forwards events to and from connlib
pub(crate) struct TunnelWrapper {
    recv_task: tokio::task::JoinHandle<Result<()>>,
    tx: FramedWrite<OwnedWriteHalf, LengthDelimitedCodec>,
}

impl TunnelWrapper {
    pub(crate) async fn disconnect(mut self) -> Result<()> {
        self.send_msg(&IpcClientMsg::Disconnect)
            .await
            .context("Couldn't send Disconnect")?;
        self.tx.close().await?;
        self.recv_task.abort();
        Ok(())
    }

    pub(crate) async fn reconnect(&mut self) -> Result<()> {
        self.send_msg(&IpcClientMsg::Reconnect)
            .await
            .context("Couldn't send Reconnect")?;
        Ok(())
    }

    /// Tell connlib about the system's default resolvers
    ///
    /// `dns` is passed as value because the in-proc impl needs that
    pub(crate) async fn set_dns(&mut self, dns: Vec<IpAddr>) -> Result<()> {
        self.send_msg(&IpcClientMsg::SetDns(dns))
            .await
            .context("Couldn't send SetDns")?;
        Ok(())
    }

    async fn send_msg(&mut self, msg: &IpcClientMsg) -> Result<()> {
        self.tx
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
    tokio_handle: tokio::runtime::Handle,
) -> Result<TunnelWrapper> {
    // TODO: Connect to the IPC service, send over the API URL and token
    tracing::info!(pid = std::process::id(), "Connecting to IPC service...");
    let stream = UnixStream::connect(SOCK_PATH)
        .await
        .context("Couldn't connect to UDS")?;
    let (rx, tx) = stream.into_split();
    let mut rx = FramedRead::new(rx, LengthDelimitedCodec::new());
    let tx = FramedWrite::new(tx, LengthDelimitedCodec::new());

    // TODO: Make sure this joins / drops somewhere
    let recv_task = tokio_handle.spawn(async move {
        while let Some(msg) = rx.next().await {
            let msg = msg?;
            let msg: IpcServerMsg = serde_json::from_slice(&msg)?;
            match msg {
                IpcServerMsg::Ok => {}
                IpcServerMsg::OnDisconnect => callback_handler.on_disconnect(
                    &connlib_client_shared::Error::Other("errors can't be serialized"),
                ),
                IpcServerMsg::OnUpdateResources(v) => callback_handler.on_update_resources(v),
                IpcServerMsg::TunnelReady => callback_handler.on_tunnel_ready(),
            }
        }
        Ok(())
    });

    let mut client = TunnelWrapper { recv_task, tx };
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
        unimplemented!()
    }

    fn on_update_resources(&self, resources: Vec<ResourceDescription>) {
        tracing::debug!("on_update_resources");
        self.resources.store(resources.into());
        self.notify_controller.notify_one();
    }
}

impl CallbackHandler {
    fn on_tunnel_ready(&self) {
        self.ctlr_tx
            .try_send(ControllerRequest::TunnelReady)
            .expect("controller channel failed");
    }
}
