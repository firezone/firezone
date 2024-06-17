use anyhow::Result;
use tokio::io::{ReadHalf, WriteHalf};
use tokio_util::codec::{FramedRead, FramedWrite, LengthDelimitedCodec};

#[cfg(target_os = "linux")]
#[path = "ipc/linux.rs"]
mod platform;

#[cfg(target_os = "windows")]
#[path = "ipc/windows.rs"]
pub mod platform;

pub(crate) use platform::Server;
use platform::ServerStream;
pub use platform::{connect_to_service, ClientStream};

pub(crate) type Read = FramedRead<ReadHalf<ServerStream>, LengthDelimitedCodec>;
pub(crate) type Write = FramedWrite<WriteHalf<ServerStream>, LengthDelimitedCodec>;

impl platform::Server {
    pub(crate) async fn next_client_split(&mut self) -> Result<(Read, Write)> {
        let (rx, tx) = tokio::io::split(self.next_client().await?);
        let rx = FramedRead::new(rx, LengthDelimitedCodec::new());
        let tx = FramedWrite::new(tx, LengthDelimitedCodec::new());
        Ok((rx, tx))
    }
}

#[cfg(test)]
mod tests {
    use super::platform::{connect_to_service, Server};
    use crate::{IpcClientMsg, IpcServerMsg};
    use anyhow::{ensure, Context as _, Result};
    use futures::{SinkExt, StreamExt};
    use std::time::Duration;
    use tokio::{task::JoinHandle, time::timeout};
    use tokio_util::codec::{FramedRead, FramedWrite, LengthDelimitedCodec};

    /// Make sure the IPC client and server can exchange messages
    #[tokio::test]
    async fn smoke() -> Result<()> {
        let _ = tracing_subscriber::fmt().with_test_writer().try_init();
        let loops = 10;
        const ID: &str = "OB5SZCGN";

        let mut server = Server::new(ID).await.context("Error while starting IPC server")?;

        let server_task: tokio::task::JoinHandle<Result<()>> = tokio::spawn(async move {
            for _ in 0..loops {
                let (mut rx, mut tx) = server.next_client_split().await.context("Error while waiting for next IPC client")?;
                while let Some(req) = rx.next().await {
                    let req = req.context("Error while reading from IPC client")?;
                    let req: IpcClientMsg = serde_json::from_slice(&req)?;
                    ensure!(req == IpcClientMsg::Reconnect);
                    tx.send(serde_json::to_string(&IpcServerMsg::OnTunnelReady)?.into())
                        .await.context("Error while writing to IPC client")?;
                }
                tracing::info!("Client disconnected");
            }
            Ok(())
        });

        let client_task: JoinHandle<Result<()>> = tokio::spawn(async move {
            for _ in 0..loops {
                let stream = connect_to_service(ID).await.context("Error while connecting to IPC server")?;
                let (rx, tx) = tokio::io::split(stream);
                let mut rx = FramedRead::new(rx, LengthDelimitedCodec::new());
                let mut tx = FramedWrite::new(tx, LengthDelimitedCodec::new());

                let req = IpcClientMsg::Reconnect;
                for _ in 0..10 {
                    tx.send(serde_json::to_string(&req)?.into()).await.context("Error while writing to IPC server")?;
                    let resp = rx.next().await.context("Should have gotten a reply from the IPC server")?.context("Error while reading from IPC server")?;
                    let resp: IpcServerMsg = serde_json::from_slice(&resp)?;
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

        let mut server = Server::new("H6L73DG5").await?;
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
