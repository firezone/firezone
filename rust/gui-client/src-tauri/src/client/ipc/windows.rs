use anyhow::{Context as _, Result};
use connlib_client_shared::Callbacks;
use firezone_headless_client::{IpcClientMsg, IpcServerMsg};
use futures::{SinkExt, StreamExt};
use secrecy::{ExposeSecret, SecretString};
use tokio::net::windows::named_pipe::{self, NamedPipeClient};
use tokio_util::codec::{FramedRead, FramedWrite, LengthDelimitedCodec};

pub(crate) struct Client {
    task: tokio::task::JoinHandle<Result<()>>,
    // Needed temporarily to avoid a big refactor. We can remove this in the future.
    tx: FramedWrite<tokio::io::WriteHalf<NamedPipeClient>, LengthDelimitedCodec>,
}

struct IpcStream(pub NamedPipeClient);

impl IpcStream {
    /// Connect to the IPC service
    ///
    /// This is async on Linux
    #[allow(clippy::unused_async)]
    async fn connect() -> Result<Self> {
        let ipc = named_pipe::ClientOptions::new()
            .open(firezone_headless_client::windows::pipe_path())
            .context("Couldn't connect to named pipe server")?;
        Ok(Self(ipc))
    }
}

impl Client {
    pub(crate) async fn disconnect(mut self) -> Result<()> {
        self.send_msg(&IpcClientMsg::Disconnect)
            .await
            .context("Couldn't send Disconnect")?;
        self.task.abort();
        Ok(())
    }

    #[allow(clippy::unused_async)]
    pub(crate) async fn send_msg(&mut self, msg: &IpcClientMsg) -> Result<()> {
        self.tx
            .send(serde_json::to_string(msg).context("Couldn't encode IPC message as JSON")?.into())
            .await
            .context("Couldn't send IPC message")?;
        Ok(())
    }

    pub(crate) async fn connect(
        api_url: &str,
        token: SecretString,
        callback_handler: super::CallbackHandler,
        tokio_handle: tokio::runtime::Handle,
    ) -> Result<Self> {
        tracing::info!(pid = std::process::id(), "Connecting to IPC service...");
        let stream = IpcStream::connect().await?;
        let (rx, tx) = tokio::io::split(stream.0);
        let mut rx = FramedRead::new(rx, LengthDelimitedCodec::new());
        let tx = FramedWrite::new(tx, LengthDelimitedCodec::new());

        let task = tokio_handle.spawn(async move {
            while let Some(msg) = rx.next().await.transpose()? {
                match serde_json::from_slice::<IpcServerMsg>(&msg)? {
                    IpcServerMsg::Ok => {}
                    IpcServerMsg::OnDisconnect => callback_handler.on_disconnect(
                        &connlib_client_shared::Error::Other("errors can't be serialized"),
                    ),
                    IpcServerMsg::OnUpdateResources(v) => callback_handler.on_update_resources(v),
                    IpcServerMsg::OnSetInterfaceConfig { ipv4, ipv6, dns } => {
                        callback_handler.on_set_interface_config(ipv4, ipv6, dns);
                    }
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
            .context("Couldn't send Connect message")?;
        Ok(client)
    }
}
