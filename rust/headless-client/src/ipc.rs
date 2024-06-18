use crate::{IpcClientMsg, IpcServerMsg};
use anyhow::{anyhow, Context as _, Result};
use tokio::io::{ReadHalf, WriteHalf};
use tokio_util::{
    bytes::BytesMut,
    codec::{FramedRead, FramedWrite, LengthDelimitedCodec},
};

#[cfg(target_os = "linux")]
#[path = "ipc/linux.rs"]
mod platform;

#[cfg(target_os = "windows")]
#[path = "ipc/windows.rs"]
pub mod platform;

pub(crate) use platform::Server;
use platform::{ClientStream, ServerStream};

pub(crate) type ClientRead = FramedRead<ReadHalf<ClientStream>, ClientCodec>;
pub type ClientWrite = FramedWrite<WriteHalf<ClientStream>, ClientCodec>;
pub(crate) type ServerRead = FramedRead<ReadHalf<ServerStream>, ServerCodec>;
pub(crate) type ServerWrite = FramedWrite<WriteHalf<ServerStream>, ServerCodec>;

#[derive(Clone, Copy)]
pub enum ServiceId {
    /// The IPC service used by Firezone GUI Client in production
    Prod,
    /// An IPC service used for unit tests.
    ///
    /// Includes an ID so that multiple tests can
    /// run in parallel
    Test(&'static str),
}

pub struct ClientCodec {
    inner: LengthDelimitedCodec,
}

pub struct ServerCodec {
    inner: LengthDelimitedCodec,
}

impl Default for ClientCodec {
    fn default() -> Self {
        Self {
            inner: LengthDelimitedCodec::new(),
        }
    }
}

impl Default for ServerCodec {
    fn default() -> Self {
        Self {
            inner: LengthDelimitedCodec::new(),
        }
    }
}

impl tokio_util::codec::Encoder<&IpcClientMsg> for ClientCodec {
    type Error = anyhow::Error;

    fn encode(&mut self, msg: &IpcClientMsg, buf: &mut BytesMut) -> Result<()> {
        let msg = serde_json::to_string(&msg)?;
        self.inner.encode(msg.into(), buf)?;
        Ok(())
    }
}

impl tokio_util::codec::Encoder<&IpcServerMsg> for ServerCodec {
    type Error = anyhow::Error;

    fn encode(&mut self, msg: &IpcServerMsg, buf: &mut BytesMut) -> Result<()> {
        let msg = serde_json::to_string(&msg)?;
        self.inner.encode(msg.into(), buf)?;
        Ok(())
    }
}

impl tokio_util::codec::Decoder for ClientCodec {
    type Error = anyhow::Error;
    type Item = IpcServerMsg;

    fn decode(&mut self, buf: &mut BytesMut) -> Result<Option<IpcServerMsg>> {
        let Some(msg) = self.inner.decode(buf)? else {
            return Ok(None);
        };
        let msg = serde_json::from_slice(&msg).context("Error while deserializing IpcServerMsg")?;
        Ok(Some(msg))
    }
}

impl tokio_util::codec::Decoder for ServerCodec {
    type Error = anyhow::Error;
    type Item = IpcClientMsg;

    fn decode(&mut self, buf: &mut BytesMut) -> Result<Option<IpcClientMsg>> {
        let Some(msg) = self.inner.decode(buf)? else {
            return Ok(None);
        };
        let msg = serde_json::from_slice(&msg).context("Error while deserializing IpcClientMsg")?;
        Ok(Some(msg))
    }
}

/// Connect to the IPC service
///
/// Public because the GUI Client will need it
pub async fn connect_to_service(id: ServiceId) -> Result<(ClientRead, ClientWrite)> {
    for _ in 0..10 {
        match platform::connect_to_service(id).await {
            Ok(stream) => {
                let (rx, tx) = tokio::io::split(stream);
                let rx = FramedRead::new(rx, ClientCodec::default());
                let tx = FramedWrite::new(tx, ClientCodec::default());
                return Ok((rx, tx));
            }
            Err(error) => {
                tracing::warn!(
                    ?error,
                    "Couldn't connect to IPC service, will sleep and try again"
                );
                // This won't come up much for humans but it helps the automated
                // tests pass
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
        }
    }
    Err(anyhow!(
        "Failed to connect to IPC server after multiple attempts"
    ))
}

impl platform::Server {
    pub(crate) async fn next_client_split(&mut self) -> Result<(ServerRead, ServerWrite)> {
        let (rx, tx) = tokio::io::split(self.next_client().await?);
        let rx = FramedRead::new(rx, ServerCodec::default());
        let tx = FramedWrite::new(tx, ServerCodec::default());
        Ok((rx, tx))
    }
}

#[cfg(test)]
mod tests {
    use super::{platform::Server, ServiceId};
    use crate::{IpcClientMsg, IpcServerMsg};
    use anyhow::{ensure, Context as _, Result};
    use futures::{SinkExt, StreamExt};
    use std::time::Duration;
    use tokio::{task::JoinHandle, time::timeout};

    /// Make sure the IPC client and server can exchange messages
    #[tokio::test]
    async fn smoke() -> Result<()> {
        let _ = tracing_subscriber::fmt().with_test_writer().try_init();
        let loops = 10;
        const ID: ServiceId = ServiceId::Test("OB5SZCGN");

        let mut server = Server::new(ID)
            .await
            .context("Error while starting IPC server")?;

        let server_task: tokio::task::JoinHandle<Result<()>> = tokio::spawn(async move {
            for _ in 0..loops {
                let (mut rx, mut tx) = server
                    .next_client_split()
                    .await
                    .context("Error while waiting for next IPC client")?;
                while let Some(req) = rx.next().await {
                    let req = req.context("Error while reading from IPC client")?;
                    ensure!(req == IpcClientMsg::Reconnect);
                    tx.send(&IpcServerMsg::OnTunnelReady)
                        .await
                        .context("Error while writing to IPC client")?;
                }
                tracing::info!("Client disconnected");
            }
            Ok(())
        });

        let client_task: JoinHandle<Result<()>> = tokio::spawn(async move {
            for _ in 0..loops {
                let (mut rx, mut tx) = super::connect_to_service(ID)
                    .await
                    .context("Error while connecting to IPC server")?;

                let req = IpcClientMsg::Reconnect;
                for _ in 0..10 {
                    tx.send(&req)
                        .await
                        .context("Error while writing to IPC server")?;
                    let resp = rx
                        .next()
                        .await
                        .context("Should have gotten a reply from the IPC server")?
                        .context("Error while reading from IPC server")?;
                    ensure!(resp == IpcServerMsg::OnTunnelReady);
                }
            }
            Ok(())
        });

        let client_result = client_task.await;
        if let Err(panic) = &client_result {
            tracing::error!(?panic, "Client panic");
        } else if let Ok(Err(error)) = &client_result {
            tracing::error!(?error, "Client error");
        }

        let server_result = server_task.await;
        if let Err(panic) = &server_result {
            tracing::error!(?panic, "Server panic");
        } else if let Ok(Err(error)) = &server_result {
            tracing::error!(?error, "Server error");
        }

        if client_result.is_err() || server_result.is_err() {
            anyhow::bail!("Something broke.");
        }
        Ok(())
    }

    /// Replicate #5143
    ///
    /// When the IPC service has disconnected from a GUI and loops over, sometimes
    /// the named pipe is not ready. If our IPC code doesn't handle this right,
    /// this test will fail.
    #[tokio::test]
    async fn loop_to_next_client() -> Result<()> {
        let _ = tracing_subscriber::fmt().with_test_writer().try_init();

        let mut server = Server::new(ServiceId::Test("H6L73DG5")).await?;
        for i in 0..5 {
            if let Ok(Err(err)) = timeout(Duration::from_secs(1), server.next_client()).await {
                Err(err).with_context(|| {
                    format!("Couldn't listen for next IPC client, iteration {i}")
                })?;
            }
        }
        Ok(())
    }
}
