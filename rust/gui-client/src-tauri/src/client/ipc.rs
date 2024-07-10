use crate::client::gui::{ControllerRequest, CtlrTx};
use anyhow::{Context as _, Result};
use firezone_headless_client::{
    ipc::{self, Error},
    IpcClientMsg, IpcServerMsg,
};
use futures::{SinkExt, StreamExt};
use secrecy::{ExposeSecret, SecretString};
use std::net::IpAddr;

pub(crate) struct Client {
    task: tokio::task::JoinHandle<Result<()>>,
    // Needed temporarily to avoid a big refactor. We can remove this in the future.
    tx: ipc::ClientWrite,
}

impl Drop for Client {
    // Might drop in-flight IPC messages
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl Client {
    pub(crate) async fn new(ctlr_tx: CtlrTx) -> Result<Self> {
        tracing::info!(
            client_pid = std::process::id(),
            "Connecting to IPC service..."
        );
        let (mut rx, tx) = ipc::connect_to_service(ipc::ServiceId::Prod).await?;
        let task = tokio::task::spawn(async move {
            while let Some(msg) = rx.next().await.transpose()? {
                match msg {
                    IpcServerMsg::Ok => {}
                    IpcServerMsg::OnDisconnect {
                        error_msg,
                        is_authentication_error,
                    } => {
                        ctlr_tx
                            .send(ControllerRequest::Disconnected {
                                error_msg,
                                is_authentication_error,
                            })
                            .await?
                    }
                    IpcServerMsg::OnUpdateResources(v) => {
                        ctlr_tx.send(ControllerRequest::UpdateResources(v)).await?
                    }
                }
            }
            Ok(())
        });
        Ok(Self { task, tx })
    }

    pub(crate) async fn disconnect_from_ipc(mut self) -> Result<()> {
        self.task.abort();
        self.tx.close().await?;
        Ok(())
    }

    pub(crate) async fn disconnect_from_firezone(&mut self) -> Result<()> {
        self.send_msg(&IpcClientMsg::Disconnect)
            .await
            .context("Couldn't send Disconnect")?;
        Ok(())
    }

    pub(crate) async fn send_msg(&mut self, msg: &IpcClientMsg) -> Result<()> {
        self.tx
            .send(msg)
            .await
            .context("Couldn't send IPC message")?;
        Ok(())
    }

    pub(crate) async fn connect_to_firezone(
        &mut self,
        api_url: &str,
        token: SecretString,
    ) -> Result<(), Error> {
        let token = token.expose_secret().clone();
        self.send_msg(&IpcClientMsg::Connect {
            api_url: api_url.to_string(),
            token,
        })
        .await
        .context("Couldn't send Connect message")
        .map_err(Error::Other)?;
        Ok(())
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
