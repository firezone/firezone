use anyhow::{Context as _, Result};
use firezone_headless_client::{
    ipc::{self, Error},
    IpcClientMsg,
};
use futures::SinkExt;
use secrecy::{ExposeSecret, SecretString};

pub use firezone_headless_client::ipc::ClientRead;

pub struct Client {
    // Needed temporarily to avoid a big refactor. We can remove this in the future.
    tx: ipc::ClientWrite,
}

impl Client {
    pub async fn new() -> Result<(Self, ipc::ClientRead), ipc::Error> {
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
}
