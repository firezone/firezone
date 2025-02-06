use anyhow::{Context as _, Result};
use firezone_headless_client::{ipc, IpcClientMsg};
use futures::SinkExt;
use secrecy::{ExposeSecret, SecretString};
use std::net::IpAddr;

pub use firezone_headless_client::ipc::ClientRead;

pub struct Client {
    // Needed temporarily to avoid a big refactor. We can remove this in the future.
    tx: ipc::ClientWrite,
}

impl Client {
    pub async fn new() -> Result<(Self, ipc::ClientRead)> {
        tracing::debug!(
            client_pid = std::process::id(),
            "Connecting to IPC service..."
        );
        let (rx, tx) = ipc::connect_to_service(ipc::ServiceId::Prod).await?;

        Ok((Self { tx }, rx))
    }

    pub async fn disconnect_from_ipc(mut self) -> Result<()> {
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

    pub async fn connect_to_firezone(&mut self, api_url: &str, token: SecretString) -> Result<()> {
        let token = token.expose_secret().clone();
        self.send_msg(&IpcClientMsg::Connect {
            api_url: api_url.to_string(),
            token,
        })
        .await
        .context("Couldn't send Connect message")?;
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
