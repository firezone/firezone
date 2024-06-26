use crate::client::gui::{ControllerRequest, CtlrTx};
use anyhow::{Context as _, Result};
use arc_swap::ArcSwap;
use connlib_client_shared::callbacks::ResourceDescription;
use firezone_headless_client::{
    ipc::{self, Error},
    IpcClientMsg, IpcServerMsg,
};
use futures::{SinkExt, StreamExt};
use secrecy::{ExposeSecret, SecretString};
use std::{net::IpAddr, sync::Arc};
use tokio::sync::Notify;

#[derive(Clone)]
pub(crate) struct CallbackHandler {
    pub notify_controller: Arc<Notify>,
    pub ctlr_tx: CtlrTx,
    pub resources: Arc<ArcSwap<Vec<ResourceDescription>>>,
}

// Almost but not quite implements `Callbacks` from connlib.
// Because of the IPC boundary, we can deviate.
impl CallbackHandler {
    fn on_disconnect(&self, error_msg: String, is_authentication_error: bool) {
        self.ctlr_tx
            .try_send(ControllerRequest::Disconnected {
                error_msg,
                is_authentication_error,
            })
            .expect("controller channel failed");
    }

    fn on_tunnel_ready(&self) {
        self.ctlr_tx
            .try_send(ControllerRequest::TunnelReady)
            .expect("controller channel failed");
    }

    fn on_update_resources(&self, resources: Vec<ResourceDescription>) {
        tracing::debug!("on_update_resources");
        self.resources.store(resources.into());
        self.notify_controller.notify_one();
    }
}

pub(crate) struct Client {
    task: tokio::task::JoinHandle<Result<()>>,
    // Needed temporarily to avoid a big refactor. We can remove this in the future.
    tx: ipc::ClientWrite,
}

impl Client {
    pub(crate) async fn disconnect(mut self) -> Result<()> {
        self.send_msg(&IpcClientMsg::Disconnect)
            .await
            .context("Couldn't send Disconnect")?;
        self.tx.close().await?;
        self.task.abort();
        Ok(())
    }

    pub(crate) async fn send_msg(&mut self, msg: &IpcClientMsg) -> Result<()> {
        self.tx
            .send(msg)
            .await
            .context("Couldn't send IPC message")?;
        Ok(())
    }

    pub(crate) async fn connect(
        api_url: &str,
        token: SecretString,
        callback_handler: CallbackHandler,
        tokio_handle: tokio::runtime::Handle,
    ) -> Result<Self, Error> {
        tracing::info!(
            client_pid = std::process::id(),
            "Connecting to IPC service..."
        );
        let (mut rx, tx) = ipc::connect_to_service(ipc::ServiceId::Prod).await?;

        let task = tokio_handle.spawn(async move {
            while let Some(msg) = rx.next().await.transpose()? {
                match msg {
                    IpcServerMsg::Ok => {}
                    IpcServerMsg::OnDisconnect {
                        error_msg,
                        is_authentication_error,
                    } => callback_handler.on_disconnect(error_msg, is_authentication_error),
                    IpcServerMsg::OnTunnelReady => callback_handler.on_tunnel_ready(),
                    IpcServerMsg::OnUpdateResources(v) => callback_handler.on_update_resources(v),
                }
            }
            Ok(())
        });

        let mut client = Self { task, tx };
        let token = token.expose_secret().clone();
        client
            .send_msg(&IpcClientMsg::Connect {
                api_url: api_url.to_string(),
                token,
            })
            .await
            .context("Couldn't send Connect message")
            .map_err(Error::Other)?;
        Ok(client)
    }

    pub(crate) async fn reconnect(&mut self) -> Result<()> {
        self.send_msg(&IpcClientMsg::Reconnect)
            .await
            .context("Couldn't send Reconnect")?;
        Ok(())
    }

    /// Tell connlib about the system's default resolvers
    pub(crate) async fn set_dns(&mut self, dns: Vec<IpAddr>) -> Result<()> {
        self.send_msg(&IpcClientMsg::SetDns(dns))
            .await
            .context("Couldn't send SetDns")?;
        Ok(())
    }
}
