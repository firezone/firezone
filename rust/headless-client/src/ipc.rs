use crate::{IpcClientMsg, IpcServerMsg};
use anyhow::{anyhow, Context as _, Result};
use tokio::io::{ReadHalf, WriteHalf};
use tokio_util::{
    bytes::BytesMut,
    codec::{FramedRead, FramedWrite, LengthDelimitedCodec},
};

// Setting `path` directly helps `cargo-mutants` skip over uncompiled code
// for other platforms, e.g. skip Linux code when building for Windows.
#[cfg(target_os = "linux")]
#[path = "ipc/linux.rs"]
mod platform;

#[cfg(target_os = "windows")]
#[path = "ipc/windows.rs"]
pub mod platform;

pub(crate) use platform::Server;
use platform::{ClientStream, ServerStream};

pub(crate) type ClientRead = FramedRead<ReadHalf<ClientStream>, Decoder<IpcServerMsg>>;
pub type ClientWrite = FramedWrite<WriteHalf<ClientStream>, Encoder<IpcClientMsg>>;
pub(crate) type ServerRead = FramedRead<ReadHalf<ServerStream>, Decoder<IpcClientMsg>>;
pub(crate) type ServerWrite = FramedWrite<WriteHalf<ServerStream>, Encoder<IpcServerMsg>>;

/// A name that both the server and client can use to find each other
#[derive(Clone, Copy)]
pub enum ServiceId {
    /// The IPC service used by Firezone GUI Client in production
    ///
    /// This must go in `/run/dev.firezone.client` on Linux, which requires
    /// root permission
    Prod,
    /// An IPC service used for unit tests.
    ///
    /// This must go in `/run/user/$UID/dev.firezone.client` on Linux so
    /// the unit tests won't need root.
    ///
    /// Includes an ID so that multiple tests can
    /// run in parallel.
    ///
    /// The ID should have A-Z, 0-9 only, no dots or slashes.
    Test(&'static str),
}

pub struct Decoder<D> {
    inner: LengthDelimitedCodec,
    _decode_type: std::marker::PhantomData<D>,
}

pub struct Encoder<E> {
    inner: LengthDelimitedCodec,
    _encode_type: std::marker::PhantomData<E>,
}

impl<D> Default for Decoder<D> {
    fn default() -> Self {
        Self {
            inner: LengthDelimitedCodec::new(),
            _decode_type: Default::default(),
        }
    }
}

impl<E> Default for Encoder<E> {
    fn default() -> Self {
        Self {
            inner: LengthDelimitedCodec::new(),
            _encode_type: Default::default(),
        }
    }
}

impl<D: serde::de::DeserializeOwned> tokio_util::codec::Decoder for Decoder<D> {
    type Error = anyhow::Error;
    type Item = D;

    fn decode(&mut self, buf: &mut BytesMut) -> Result<Option<D>> {
        let Some(msg) = self.inner.decode(buf)? else {
            return Ok(None);
        };
        let msg = serde_json::from_slice(&msg)
            .with_context(|| format!("Error while deserializing {}", std::any::type_name::<D>()))?;
        Ok(Some(msg))
    }
}

impl<E: serde::Serialize> tokio_util::codec::Encoder<&E> for Encoder<E> {
    type Error = anyhow::Error;

    fn encode(&mut self, msg: &E, buf: &mut BytesMut) -> Result<()> {
        let msg = serde_json::to_string(msg)?;
        self.inner.encode(msg.into(), buf)?;
        Ok(())
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
                let rx = FramedRead::new(rx, Decoder::default());
                let tx = FramedWrite::new(tx, Encoder::default());
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
        let rx = FramedRead::new(rx, Decoder::default());
        let tx = FramedWrite::new(tx, Encoder::default());
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
