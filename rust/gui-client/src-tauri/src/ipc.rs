use anyhow::{Context as _, Result};
use connlib_model::{ResourceId, ResourceView};
use platform::{ClientStream, ServerStream};
use std::{collections::BTreeSet, io, net::IpAddr};
use tokio::io::{ReadHalf, WriteHalf};
use tokio_util::{
    bytes::BytesMut,
    codec::{FramedRead, FramedWrite, LengthDelimitedCodec},
};

pub(crate) use platform::Server;

pub type ClientRead = FramedRead<ReadHalf<ClientStream>, Decoder<ServerMsg>>;
pub type ClientWrite = FramedWrite<WriteHalf<ClientStream>, Encoder<ClientMsg>>;
pub(crate) type ServerRead = FramedRead<ReadHalf<ServerStream>, Decoder<ClientMsg>>;
pub(crate) type ServerWrite = FramedWrite<WriteHalf<ServerStream>, Encoder<ServerMsg>>;

#[cfg(target_os = "linux")]
#[path = "ipc/linux.rs"]
pub(crate) mod platform;

#[cfg(target_os = "windows")]
#[path = "ipc/windows.rs"]
pub(crate) mod platform;

#[cfg(target_os = "macos")]
#[path = "ipc/macos.rs"]
pub(crate) mod platform;

#[derive(Debug, thiserror::Error)]
#[error("Couldn't find IPC service `{0}`")]
pub struct NotFound(String);

/// A name that both the server and client can use to find each other
///
/// In the platform-specific code, this is translated to a Unix Domain Socket
/// path on Linux, and a named pipe name on Windows.
/// These have different restrictions on naming.
///
/// UDS are mostly like normal
/// files, so for production we want them in `/run/dev.firezone.client`, which
/// systemd will create for us, and the Client can trust no other service
/// will impersonate that path. For tests we want them in `/run/user/$UID/`,
/// which we can use without root privilege.
///
/// Named pipes are not part of the normal file hierarchy, they can only
/// have 2 or 3 slashes in them, and we don't distinguish yet between
/// privileged and non-privileged named pipes. Windows is slowly rolling out
/// UDS support, so in a year or two we might be better off making it UDS
/// on all platforms.
///
/// Because the paths are so different (and Windows actually uses a `String`),
/// we have this [`SocketId`] abstraction instead of just a `PathBuf`.
#[derive(Clone, Copy)]
pub enum SocketId {
    /// The IPC socket used by Firezone GUI Client in production to connect to the tunnel service.
    ///
    /// This must go in `/run/dev.firezone.client` on Linux, which requires
    /// root permission
    Prod,
    /// An IPC socket used for unit tests.
    ///
    /// This must go in `/run/user/$UID/dev.firezone.client` on Linux so
    /// the unit tests won't need root.
    ///
    /// Includes an ID so that multiple tests can
    /// run in parallel.
    ///
    /// The ID should have A-Z, 0-9 only, no dots or slashes, because of Windows named pipes name restrictions.
    #[cfg(test)]
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

/// Connect to an IPC socket
pub async fn connect(id: SocketId) -> Result<(ClientRead, ClientWrite)> {
    tracing::debug!(
        client_pid = std::process::id(),
        "Connecting to IPC socket..."
    );

    // This is how ChatGPT recommended, and I couldn't think of any more clever
    // way before I asked it.
    let mut last_err = None;

    for _ in 0..10 {
        match platform::connect_to_socket(id).await {
            Ok(stream) => {
                let (rx, tx) = tokio::io::split(stream);
                let rx = FramedRead::new(rx, Decoder::default());
                let tx = FramedWrite::new(tx, Encoder::default());
                return Ok((rx, tx));
            }
            Err(error) => {
                tracing::debug!("Couldn't connect to IPC socket: {error}");
                last_err = Some(error);

                // This won't come up much for humans but it helps the automated
                // tests pass
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
        }
    }
    Err(last_err.expect("Impossible - Exhausted all retries but didn't get any errors"))
}

impl platform::Server {
    pub(crate) async fn next_client_split(&mut self) -> Result<(ServerRead, ServerWrite)> {
        let (rx, tx) = tokio::io::split(self.next_client().await?);
        let rx = FramedRead::new(rx, Decoder::default());
        let tx = FramedWrite::new(tx, Encoder::default());
        Ok((rx, tx))
    }
}

#[derive(Debug, PartialEq, serde::Deserialize, serde::Serialize)]
pub enum ClientMsg {
    ClearLogs,
    Connect {
        api_url: String,
        token: String,
    },
    Disconnect,
    ApplyLogFilter {
        directives: String,
    },
    Reset,
    SetDns(Vec<IpAddr>),
    SetDisabledResources(BTreeSet<ResourceId>),
    StartTelemetry {
        environment: String,
        release: String,
        account_slug: Option<String>,
    },
}

/// Messages that end up in the GUI, either forwarded from connlib or from the IPC service.
#[derive(Debug, serde::Deserialize, serde::Serialize, strum::Display)]
pub enum ServerMsg {
    /// The IPC service finished clearing its log dir.
    ClearedLogs(Result<(), String>),
    ConnectResult(Result<(), Error>),
    DisconnectedGracefully,
    OnDisconnect {
        error_msg: String,
        is_authentication_error: bool,
    },
    OnUpdateResources(Vec<ResourceView>),
    /// The IPC service is terminating, maybe due to a software update
    ///
    /// This is a hint that the Client should exit with a message like,
    /// "Firezone is updating, please restart the GUI" instead of an error like,
    /// "IPC connection closed".
    TerminatingGracefully,
    /// The interface and tunnel are ready for traffic.
    TunnelReady,
}

// All variants are `String` because almost no error type implements `Serialize`
#[derive(Debug, serde::Deserialize, serde::Serialize, thiserror::Error)]
pub enum Error {
    #[error("IO error: {0}")]
    Io(String),
    #[error("{0}")]
    Other(String),
}

impl From<io::Error> for Error {
    fn from(v: io::Error) -> Self {
        Self::Io(v.to_string())
    }
}

impl From<anyhow::Error> for Error {
    fn from(v: anyhow::Error) -> Self {
        Self::Other(format!("{v:#}"))
    }
}

#[cfg(test)]
mod tests {
    use super::{platform::Server, *};
    use anyhow::{Result, bail, ensure};
    use futures::{SinkExt, StreamExt};
    use std::time::Duration;
    use tokio::{task::JoinHandle, time::timeout};

    #[tokio::test]
    async fn no_such_service() -> Result<()> {
        let _guard = firezone_logging::test("trace");
        const ID: SocketId = SocketId::Test("H56FRXVH");

        if super::connect(ID).await.is_ok() {
            bail!("`connect_to_service` should have failed for a non-existent service");
        }
        Ok(())
    }

    /// Make sure the IPC client and server can exchange messages
    #[tokio::test]
    async fn smoke() -> Result<()> {
        let _guard = firezone_logging::test("trace");
        let loops = 10;
        const ID: SocketId = SocketId::Test("OB5SZCGN");

        let mut server = Server::new(ID).expect("Error while starting IPC server");

        let server_task: tokio::task::JoinHandle<Result<()>> = tokio::spawn(async move {
            for _ in 0..loops {
                let (mut rx, mut tx) = server
                    .next_client_split()
                    .await
                    .expect("Error while waiting for next IPC client");
                while let Some(req) = rx.next().await {
                    let req = req.expect("Error while reading from IPC client");
                    ensure!(req == ClientMsg::Reset);
                    tx.send(&ServerMsg::OnUpdateResources(vec![]))
                        .await
                        .expect("Error while writing to IPC client");
                }
                tracing::info!("Client disconnected");
            }
            Ok(())
        });

        let client_task: JoinHandle<Result<()>> = tokio::spawn(async move {
            for _ in 0..loops {
                let (mut rx, mut tx) = super::connect(ID)
                    .await
                    .context("Error while connecting to IPC server")?;

                let req = ClientMsg::Reset;
                for _ in 0..10 {
                    tx.send(&req)
                        .await
                        .expect("Error while writing to IPC server");
                    let resp = rx
                        .next()
                        .await
                        .expect("Should have gotten a reply from the IPC server")
                        .expect("Error while reading from IPC server");
                    ensure!(matches!(resp, ServerMsg::OnUpdateResources(_)));
                }
            }
            Ok(())
        });

        let client_result = client_task.await;
        match &client_result {
            Err(panic) => {
                tracing::error!(?panic, "Client panic");
            }
            Ok(Err(error)) => {
                tracing::error!("Client error: {error:#}");
            }
            _ => (),
        }

        let server_result = server_task.await;
        match &server_result {
            Err(panic) => {
                tracing::error!(?panic, "Server panic");
            }
            Ok(Err(error)) => {
                tracing::error!("Server error: {error:#}");
            }
            _ => (),
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
        let _guard = firezone_logging::test("trace");

        let mut server = Server::new(SocketId::Test("H6L73DG5"))?;
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
