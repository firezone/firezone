use anyhow::{Context as _, Result};
use firezone_headless_client::{
    ipc::{self, Error},
    IpcClientMsg, IpcServerMsg,
};
use futures::{SinkExt, StreamExt};
use secrecy::{ExposeSecret, SecretString};
use std::net::IpAddr;

pub struct Client {
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
    pub async fn new(
        ctlr_tx: tokio::sync::mpsc::Sender<Result<IpcServerMsg>>,
    ) -> Result<Self, ipc::Error> {
        tracing::debug!(
            client_pid = std::process::id(),
            "Connecting to IPC service..."
        );
        let (mut rx, tx) = ipc::connect_to_service(ipc::ServiceId::Prod).await?;
        let task = tokio::task::spawn(async move {
            while let Some(result) = rx.next().await {
                ctlr_tx.send(result).await?;
            }
            Ok(())
        });
        Ok(Self { task, tx })
    }

    pub async fn disconnect_from_ipc(mut self) -> Result<()> {
        self.task.abort();
        self.tx.close().await?;
        Ok(())
    }

    pub async fn send_msg(&mut self, msg: &IpcClientMsg) -> Result<()> {
        self.tx
            .send(msg)
            .await
            .context("Couldn't send IPC message")?;
        Ok(())
    }

    pub async fn connect_to_firezone(
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

    pub async fn reset(&mut self) -> Result<()> {
        self.send_msg(&IpcClientMsg::Reset)
            .await
            .context("Couldn't send Reset")?;
        Ok(())
    }

    /// Tell connlib about the system's default resolvers
    pub async fn set_dns(&mut self, dns: Vec<IpAddr>) -> Result<()> {
        self.send_msg(&IpcClientMsg::SetDns(dns))
            .await
            .context("Couldn't send SetDns")?;
        Ok(())
    }
}
