use crate::client::gui::{ControllerRequest, CtlrTx};
use anyhow::{Context as _, Result};
use arc_swap::ArcSwap;
use connlib_client_shared::callbacks::ResourceDescription;
use firezone_headless_client::{IpcClientMsg, IpcServerMsg};
use futures::{SinkExt, StreamExt};
use secrecy::{ExposeSecret, SecretString};
use std::{net::IpAddr, sync::Arc};
use tokio::sync::Notify;
use tokio_util::codec::{FramedRead, FramedWrite, LengthDelimitedCodec};
use tracing::instrument;

#[cfg(target_os = "linux")]
#[path = "ipc/linux.rs"]
mod platform;

// Stub only
#[cfg(target_os = "macos")]
#[path = "ipc/macos.rs"]
mod platform;

#[cfg(target_os = "windows")]
#[path = "ipc/windows.rs"]
mod platform;

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
    connlib_is_up: bool,
    task: tokio::task::JoinHandle<Result<()>>,
    // Needed temporarily to avoid a big refactor. We can remove this in the future.
    tx: FramedWrite<tokio::io::WriteHalf<platform::IpcStream>, LengthDelimitedCodec>,
}

impl Client {
    #[instrument(skip_all)]
    pub(crate) async fn disconnect_from_ipc(mut self) -> Result<()> {
        // In case the caller didn't also disconnect from Firezone
        if let Err(error) = self.disconnect_firezone().await {
            tracing::error!(
                ?error,
                "Failed to disconnect from Firezone, disconnecting from IPC anyway"
            );
        }
        self.tx.close().await?;
        self.task.abort();
        Ok(())
    }

    pub(crate) async fn disconnect_firezone(&mut self) -> Result<()> {
        self.send_msg(&IpcClientMsg::Disconnect)
            .await
            .context("Couldn't send Disconnect")?;
        self.connlib_is_up = false;
        Ok(())
    }

    pub(crate) async fn send_msg(&mut self, msg: &IpcClientMsg) -> Result<()> {
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

    #[instrument(skip_all)]
    pub(crate) async fn connect_to_ipc(
        callback_handler: CallbackHandler,
        tokio_handle: tokio::runtime::Handle,
    ) -> Result<Self> {
        tracing::info!(
            client_pid = std::process::id(),
            "Connecting to IPC service..."
        );
        let stream = platform::connect_to_service().await?;
        let (rx, tx) = tokio::io::split(stream);
        // Receives messages from the IPC service
        let mut rx = FramedRead::new(rx, LengthDelimitedCodec::new());
        let tx = FramedWrite::new(tx, LengthDelimitedCodec::new());

        let task = tokio_handle.spawn(async move {
            while let Some(msg) = rx.next().await.transpose()? {
                match serde_json::from_slice::<IpcServerMsg>(&msg)? {
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
        Ok(Self {
            connlib_is_up: false,
            task,
            tx,
        })
    }

    pub(crate) async fn connect_to_firezone(
        &mut self,
        api_url: &str,
        token: SecretString,
    ) -> Result<()> {
        let token = token.expose_secret().clone();
        self.send_msg(&IpcClientMsg::Connect {
            api_url: api_url.to_string(),
            token,
        })
        .await
        .context("Couldn't send Connect message to IPC service")?;
        self.connlib_is_up = true;
        Ok(())
    }

    pub(crate) async fn reconnect_firezone(&mut self) -> Result<()> {
        if !self.connlib_is_up {
            tracing::debug!("Ignoring Reconnect since connlib isn't up");
            return Ok(());
        }
        self.send_msg(&IpcClientMsg::Reconnect)
            .await
            .context("Couldn't send Reconnect")?;
        Ok(())
    }

    /// Tell connlib about the system's default resolvers
    pub(crate) async fn set_dns(&mut self, dns: Vec<IpAddr>) -> Result<()> {
        if !self.connlib_is_up {
            tracing::debug!("Ignoring SetDns since connlib isn't up");
            return Ok(());
        }
        self.send_msg(&IpcClientMsg::SetDns(dns))
            .await
            .context("Couldn't send SetDns")?;
        Ok(())
    }
}
